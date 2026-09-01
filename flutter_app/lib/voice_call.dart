import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart' hide AndroidAudioMode;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'remote_audio.dart';

class VoiceCallCoordinator {
  VoiceCallCoordinator({
    required this.socket,
    required this.contextProvider,
    required this.token,
    required this.apiBase,
  }) {
    _bindSocket();
  }

  final io.Socket socket;
  final BuildContext? Function() contextProvider;
  final String token;
  final String apiBase;
  final ValueNotifier<_CallUiState> _ui =
      ValueNotifier(const _CallUiState(status: 'מתחבר…'));
  final AudioPlayer _ringPlayer = AudioPlayer();

  RTCPeerConnection? _peer;
  MediaStream? _localStream;
  RTCVideoRenderer? _remoteAudioRenderer;
  MediaStream? _remoteAudioStream;
  String? _callId;
  String _otherName = 'משתמש';
  bool _outgoing = false;
  bool _ready = false;
  bool _muted = false;
  bool _speaker = true;
  bool _disposed = false;
  BuildContext? _activeDialogContext;
  final List<RTCIceCandidate> _remoteCandidates = [];
  final List<Map<String, dynamic>> _localCandidates = [];
  int _localCandidateCount = 0;
  int _remoteCandidateCount = 0;
  Timer? _durationTimer;
  int _seconds = 0;

  static const _fallbackIceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
  };

  void _bindSocket() {
    socket.on('connect', (_) {
      _ready = true;
      socket.emit('call:client-ready');
    });
    socket.on('call:ready', (_) => _ready = true);
    socket.on('call:ringing', _onRinging);
    socket.on('call:incoming', _onIncoming);
    socket.on('call:accepted', _onAccepted);
    socket.on('call:signal', _onSignal);
    socket.on('call:unavailable', _onUnavailable);
    socket.on('call:error', _onError);
    socket.on('call:end', _onRemoteEnd);
    if (socket.connected) {
      // Older/reconnecting servers may have emitted call:ready just before
      // these listeners were attached. The server still validates every call.
      _ready = true;
      socket.emit('call:client-ready');
    }
  }

  Future<void> startCall(String userId, String name) async {
    final context = contextProvider();
    if (context == null || _callId != null || _peer != null) return;
    if (!socket.connected || !_ready) {
      _snack(context, 'החיבור לשיחות עדיין אינו מוכן');
      return;
    }
    _outgoing = true;
    _otherName = name;
    _ui.value = const _CallUiState(status: 'מתחיל שיחה…');
    try {
      await _prepareMedia();
      if (_disposed) return;
      await _playTone(incoming: false);
      socket.emit('call:start', {'toUserId': userId});
      _showActiveDialog();
    } catch (error, stackTrace) {
      debugPrint('Voice call media preparation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      await _finish(localOnly: true);
      if (context.mounted) _showMediaError(context, error);
    }
  }

  Future<void> _prepareMedia() async {
    if (!kIsWeb) {
      final microphone = await Permission.microphone.request();
      if (!microphone.isGranted) {
        throw StateError('microphone_permission_denied');
      }
      // flutter_webrtc's Android audio switch inspects Bluetooth headsets on
      // Android 12+, which requires the Nearby devices permission.
      await Permission.bluetoothConnect.request();
    }
    await _configureNativeCallAudio();
    // Browsers need the renderer's hidden audio element. Native Android plays
    // remote audio directly through WebRTC and must not create a video
    // renderer just to play an audio-only stream.
    if (kIsWeb) {
      _remoteAudioRenderer = RTCVideoRenderer();
      await _remoteAudioRenderer!.initialize();
      _remoteAudioRenderer!.muted = false;
    }
    _localStream = await navigator.mediaDevices.getUserMedia({
      // The older native WebRTC bridge expects a boolean here; browsers can
      // consume the richer constraints object.
      'audio': kIsWeb
          ? {
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
            }
          : true,
      'video': false,
    });
    _peer = await createPeerConnection(await _loadIceServers());
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = true;
      if (!kIsWeb) {
        await Helper.setMicrophoneMute(false, track);
      }
      await _peer!.addTrack(track, _localStream!);
    }
    _peer!.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _localCandidateCount++;
      final candidateText = candidate.candidate ?? '';
      final candidateType = candidateText.contains(' typ relay ')
          ? 'relay'
          : candidateText.contains(' typ srflx ')
              ? 'srflx'
              : candidateText.contains(' typ host ')
                  ? 'host'
                  : 'unknown';
      _emitDiagnostic('local_candidate', {
        'candidateType': candidateType,
        'count': _localCandidateCount,
      });
      final data = {
        'type': 'candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      };
      if (_callId == null) {
        _localCandidates.add(data);
      } else {
        socket.emit('call:signal', {'callId': _callId, 'signal': data});
      }
    };
    _peer!.onTrack = (event) async {
      if (event.track.kind == 'audio') {
        event.track.enabled = true;
        if (event.streams.isNotEmpty) {
          _remoteAudioStream = event.streams.first;
        } else {
          _remoteAudioStream = await createLocalMediaStream(
              'remote-audio-${DateTime.now().millisecondsSinceEpoch}');
          await _remoteAudioStream!.addTrack(event.track);
        }
        if (kIsWeb && _remoteAudioRenderer != null) {
          _remoteAudioRenderer!.srcObject = _remoteAudioStream;
          _remoteAudioRenderer!.muted = false;
        }
        await _restoreNativeAudioRoute();
        resumeRemoteAudio();
        // onTrack fires as soon as the remote description is applied, even
        // before ICE has found a working network path. Connection state below
        // is the authoritative indication that media can actually flow.
        _ui.value = _ui.value.copyWith(status: 'מחבר שמע…');
      }
    };
    _peer!.onConnectionState = (state) {
      _emitDiagnostic('peer_state', {'state': state.toString()});
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _finish(reason: 'החיבור נותק');
      }
    };
    _peer!.onIceConnectionState = (state) {
      _emitDiagnostic('ice_state', {
        'state': state.toString(),
        'localCandidates': _localCandidateCount,
        'remoteCandidates': _remoteCandidateCount,
      });
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        if (_callId != null) {
          socket.emit('call:end', {
            'callId': _callId,
            'reason': 'connection_failed',
          });
        }
        _finish(
          localOnly: true,
          reason: 'חיבור השמע נכשל — לא נמצא נתיב תקשורת',
        );
      } else if (state ==
              RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _ui.value = _ui.value.copyWith(status: 'מחובר');
        _startDuration();
      }
    };
    // Browser audio routing is controlled by Chrome/the operating system.
    // Helper.setSpeakerphoneOn is a native mobile operation and throws on web.
    if (!kIsWeb) {
      await _restoreNativeAudioRoute();
    }
  }

  Future<void> _configureNativeCallAudio() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await Helper.setAndroidAudioConfiguration(AndroidAudioConfiguration(
        manageAudioFocus: true,
        androidAudioMode: AndroidAudioMode.inCommunication,
        androidAudioFocusMode: AndroidAudioFocusMode.gain,
        androidAudioStreamType: AndroidAudioStreamType.voiceCall,
        androidAudioAttributesUsageType:
            AndroidAudioAttributesUsageType.voiceCommunication,
        androidAudioAttributesContentType:
            AndroidAudioAttributesContentType.speech,
        forceHandleAudioRouting: true,
      ));
    } catch (error) {
      debugPrint('Android call audio configuration unavailable: $error');
    }
  }

  Future<void> _restoreNativeAudioRoute() async {
    if (kIsWeb) return;
    try {
      await _configureNativeCallAudio();
      await Helper.setSpeakerphoneOn(_speaker);
    } catch (error) {
      // Audio routing is optional; a denied Bluetooth/audio-routing
      // permission must not abort microphone capture or the whole call.
      debugPrint('Speaker routing unavailable: $error');
    }
  }

  Future<Map<String, dynamic>> _loadIceServers() async {
    try {
      final response = await http.get(
        Uri.parse('$apiBase/calls/ice-servers'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final servers = data['iceServers'];
        if (servers is List && servers.isNotEmpty) {
          // Let ICE select the fastest working host, STUN or TURN candidate.
          // TURN remains available as a fallback for restrictive networks.
          _emitDiagnostic('ice_config', {
            'serverCount': servers.length,
            'hasTurn':
                servers.any((server) => server.toString().contains('turn:')),
          });
          return {'iceServers': servers};
        }
      }
    } catch (error) {
      _emitDiagnostic('ice_config_error', {'error': error.toString()});
    }
    _emitDiagnostic('ice_config', {'serverCount': 1, 'hasTurn': false});
    return _fallbackIceServers;
  }

  void _emitDiagnostic(String event, [Map<String, dynamic>? details]) {
    socket.emit('call:diagnostic', {
      'callId': _callId,
      'event': event,
      if (details != null) ...details,
    });
  }

  void _onRinging(dynamic raw) {
    if (!_outgoing || raw is! Map) return;
    _callId = raw['callId']?.toString();
    _ui.value = _ui.value.copyWith(status: 'מצלצל…');
  }

  Future<void> _onIncoming(dynamic raw) async {
    if (_disposed || raw is! Map || _callId != null || _peer != null) return;
    final context = contextProvider();
    if (context == null) return;
    final callId = raw['callId']?.toString();
    final userId = raw['fromUserId']?.toString();
    final name = raw['fromName']?.toString() ?? 'משתמש';
    if (callId == null || userId == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _playTone(incoming: true);
        return AlertDialog(
          title: const Text('שיחת קול נכנסת'),
          content: Text('$name מתקשר/ת אליך'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('דחה'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.call),
              label: const Text('ענה'),
            ),
          ],
        );
      },
    );
    await _stopTone();
    if (accepted != true) {
      socket.emit('call:reject', {'callId': callId});
      return;
    }
    _callId = callId;
    _otherName = name;
    _outgoing = false;
    _ui.value = const _CallUiState(status: 'מתחבר…');
    try {
      await _prepareMedia();
      socket.emit('call:accept', {'callId': callId});
      _showActiveDialog();
      _flushLocalCandidates();
    } catch (error, stackTrace) {
      debugPrint('Incoming voice call media preparation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      socket.emit('call:end', {'callId': callId});
      await _finish(localOnly: true);
      if (context.mounted) _showMediaError(context, error);
    }
  }

  void _showMediaError(BuildContext context, Object error) {
    final message = error.toString();
    if (message.contains('microphone_permission_denied') ||
        message.contains('NotAllowedError') ||
        message.contains('PermissionDenied')) {
      _snack(context,
          'גישת המיקרופון נדחתה. יש לאשר אותה בהגדרות האתר או האפליקציה');
      return;
    }
    if (message.contains('NotFoundError') ||
        message.contains('DevicesNotFound')) {
      _snack(context, 'לא נמצא מיקרופון זמין במכשיר');
      return;
    }
    _snack(context, 'אתחול השיחה נכשל: $message');
  }

  Future<void> _onAccepted(dynamic raw) async {
    if (!_outgoing || raw is! Map || raw['callId']?.toString() != _callId) {
      return;
    }
    _ui.value = _ui.value.copyWith(status: 'מתחבר…');
    await _stopTone();
    await _restoreNativeAudioRoute();
    final offer = await _peer!.createOffer({'offerToReceiveAudio': true});
    await _peer!.setLocalDescription(offer);
    socket.emit('call:signal', {
      'callId': _callId,
      'signal': {'type': 'offer', 'sdp': offer.sdp},
    });
    // Candidates gathered while the remote user was still deciding whether
    // to answer must be sent only after the offer. Before acceptance the
    // callee has no peer connection yet and would discard those candidates.
    _flushLocalCandidates();
  }

  Future<void> _onSignal(dynamic raw) async {
    if (raw is! Map || raw['callId']?.toString() != _callId || _peer == null) {
      return;
    }
    final signalRaw = raw['signal'];
    if (signalRaw is! Map) return;
    final signal = Map<String, dynamic>.from(signalRaw);
    switch (signal['type']) {
      case 'offer':
        await _peer!.setRemoteDescription(
            RTCSessionDescription(signal['sdp']?.toString(), 'offer'));
        await _flushRemoteCandidates();
        final answer = await _peer!.createAnswer({'offerToReceiveAudio': true});
        await _peer!.setLocalDescription(answer);
        socket.emit('call:signal', {
          'callId': _callId,
          'signal': {'type': 'answer', 'sdp': answer.sdp},
        });
        break;
      case 'answer':
        await _peer!.setRemoteDescription(
            RTCSessionDescription(signal['sdp']?.toString(), 'answer'));
        await _flushRemoteCandidates();
        break;
      case 'candidate':
        _remoteCandidateCount++;
        _emitDiagnostic('remote_candidate', {'count': _remoteCandidateCount});
        final candidate = RTCIceCandidate(
          signal['candidate']?.toString(),
          signal['sdpMid']?.toString(),
          signal['sdpMLineIndex'] is int
              ? signal['sdpMLineIndex'] as int
              : int.tryParse('${signal['sdpMLineIndex']}'),
        );
        if (await _peer!.getRemoteDescription() == null) {
          _remoteCandidates.add(candidate);
        } else {
          await _peer!.addCandidate(candidate);
        }
    }
  }

  void _flushLocalCandidates() {
    if (_callId == null) return;
    for (final candidate in _localCandidates) {
      socket.emit('call:signal', {'callId': _callId, 'signal': candidate});
    }
    _localCandidates.clear();
  }

  Future<void> _flushRemoteCandidates() async {
    for (final candidate in _remoteCandidates) {
      await _peer?.addCandidate(candidate);
    }
    _remoteCandidates.clear();
  }

  void _onUnavailable(dynamic raw) {
    final reason = raw is Map ? raw['reason']?.toString() : null;
    final message = reason == 'busy'
        ? 'המשתמש נמצא בשיחה אחרת'
        : reason == 'not_allowed'
            ? 'שיחות מותרות בין אנשי קשר בלבד'
            : 'המשתמש אינו מחובר כרגע';
    _finish(localOnly: true, reason: message);
  }

  void _onError(dynamic raw) {
    final message = raw is Map ? raw['message']?.toString() : null;
    _finish(localOnly: true, reason: message ?? 'לא ניתן להתחיל את השיחה');
  }

  void _onRemoteEnd(dynamic raw) {
    if (raw is Map && raw['callId']?.toString() != _callId) return;
    final reason = raw is Map ? raw['reason']?.toString() : null;
    final message = switch (reason) {
      'rejected' => 'השיחה נדחתה',
      'no_answer' => 'לא התקבל מענה לשיחה',
      'disconnected' => 'חיבור הצד השני נותק',
      'connection_failed' => 'חיבור השמע של הצד השני נכשל',
      _ => 'השיחה הסתיימה',
    };
    _finish(localOnly: true, reason: message);
  }

  void _startDuration() {
    if (_durationTimer != null) return;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _seconds++;
      _ui.value = _ui.value.copyWith(seconds: _seconds);
    });
  }

  void _showActiveDialog() {
    final context = contextProvider();
    if (context == null || _activeDialogContext != null) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _activeDialogContext = dialogContext;
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text(_otherName, textAlign: TextAlign.center),
            content: ValueListenableBuilder<_CallUiState>(
              valueListenable: _ui,
              builder: (_, state, __) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircleAvatar(
                      radius: 36, child: Icon(Icons.person, size: 42)),
                  const SizedBox(height: 16),
                  Text(state.seconds > 0
                      ? _formatDuration(state.seconds)
                      : state.status),
                  if (kIsWeb && _remoteAudioRenderer != null)
                    SizedBox(
                      width: 1,
                      height: 1,
                      child: Opacity(
                        opacity: 0,
                        child: RTCVideoView(
                          _remoteAudioRenderer!,
                          objectFit: RTCVideoViewObjectFit
                              .RTCVideoViewObjectFitContain,
                        ),
                      ),
                    ),
                  if (kIsWeb && _remoteAudioStream != null) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final played = await resumeRemoteAudio();
                        final context = contextProvider();
                        if (!played && context != null && context.mounted) {
                          _snack(context,
                              'Chrome עדיין חוסם שמע; בדוק שעוצמת האתר אינה מושתקת');
                        }
                      },
                      icon: const Icon(Icons.volume_up),
                      label: const Text('הפעל שמע'),
                    ),
                  ],
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton.filledTonal(
                        tooltip: state.muted ? 'בטל השתקה' : 'השתק',
                        onPressed: _toggleMute,
                        icon: Icon(state.muted ? Icons.mic_off : Icons.mic),
                      ),
                      IconButton.filledTonal(
                        tooltip: state.speaker ? 'אוזנייה' : 'רמקול',
                        onPressed: _toggleSpeaker,
                        icon: Icon(
                            state.speaker ? Icons.volume_up : Icons.hearing),
                      ),
                      IconButton.filled(
                        style:
                            IconButton.styleFrom(backgroundColor: Colors.red),
                        tooltip: 'נתק',
                        onPressed: () => _finish(),
                        icon: const Icon(Icons.call_end, color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ).whenComplete(() => _activeDialogContext = null);
  }

  void _toggleMute() {
    _muted = !_muted;
    for (final track
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !_muted;
    }
    _ui.value = _ui.value.copyWith(muted: _muted);
  }

  Future<void> _toggleSpeaker() async {
    if (kIsWeb) {
      final context = contextProvider();
      if (context != null && context.mounted) {
        _snack(context, 'בחירת התקן השמע מתבצעת בהגדרות Chrome');
      }
      return;
    }
    _speaker = !_speaker;
    await Helper.setSpeakerphoneOn(_speaker);
    _ui.value = _ui.value.copyWith(speaker: _speaker);
  }

  Future<void> _finish({bool localOnly = false, String? reason}) async {
    final callId = _callId;
    if (!localOnly && callId != null) {
      socket.emit('call:end', {'callId': callId});
    }
    await _stopTone();
    _durationTimer?.cancel();
    _durationTimer = null;
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    await _localStream?.dispose();
    _remoteAudioRenderer?.srcObject = null;
    await _remoteAudioStream?.dispose();
    await _remoteAudioRenderer?.dispose();
    _remoteAudioStream = null;
    _remoteAudioRenderer = null;
    await _peer?.close();
    _localStream = null;
    _peer = null;
    _callId = null;
    _outgoing = false;
    _seconds = 0;
    _muted = false;
    _speaker = true;
    _remoteCandidates.clear();
    _localCandidates.clear();
    _localCandidateCount = 0;
    _remoteCandidateCount = 0;
    final dialogContext = _activeDialogContext;
    if (dialogContext != null && dialogContext.mounted) {
      Navigator.pop(dialogContext);
    }
    final context = contextProvider();
    if (reason != null && context != null && context.mounted) {
      _snack(context, reason);
    }
  }

  String _formatDuration(int value) =>
      '${(value ~/ 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';

  void _snack(BuildContext context, String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> dispose() async {
    _disposed = true;
    socket.off('call:ready');
    socket.off('connect');
    socket.off('call:ringing', _onRinging);
    socket.off('call:incoming', _onIncoming);
    socket.off('call:accepted', _onAccepted);
    socket.off('call:signal', _onSignal);
    socket.off('call:unavailable', _onUnavailable);
    socket.off('call:error', _onError);
    socket.off('call:end', _onRemoteEnd);
    await _finish();
    await _ringPlayer.dispose();
    _ui.dispose();
  }

  Future<void> _playTone({required bool incoming}) async {
    try {
      await _ringPlayer.stop();
      await _ringPlayer.setReleaseMode(ReleaseMode.loop);
      await _ringPlayer.play(BytesSource(_toneWav(incoming: incoming)));
    } catch (_) {
      // Browsers may block unsolicited audio until the user interacts.
    }
  }

  Future<void> _stopTone() async {
    try {
      await _ringPlayer.stop();
    } catch (_) {}
  }

  Uint8List _toneWav({required bool incoming}) {
    const sampleRate = 8000;
    final durationSeconds = incoming ? 4.0 : 3.0;
    final sampleCount = (sampleRate * durationSeconds).round();
    final pcm = Int16List(sampleCount);
    for (var i = 0; i < sampleCount; i++) {
      final time = i / sampleRate;
      final sounding = incoming ? time < 1.4 : (time % 1.5) < 0.75;
      if (!sounding) continue;
      final first = math.sin(2 * math.pi * (incoming ? 440 : 425) * time);
      final second = math.sin(2 * math.pi * (incoming ? 480 : 450) * time);
      pcm[i] = ((first + second) * 3500).round();
    }
    final bytes = ByteData(44 + pcm.lengthInBytes);
    void textAt(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    textAt(0, 'RIFF');
    bytes.setUint32(4, 36 + pcm.lengthInBytes, Endian.little);
    textAt(8, 'WAVE');
    textAt(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    textAt(36, 'data');
    bytes.setUint32(40, pcm.lengthInBytes, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      bytes.setInt16(44 + i * 2, pcm[i], Endian.little);
    }
    return bytes.buffer.asUint8List();
  }
}

class _CallUiState {
  const _CallUiState({
    required this.status,
    this.seconds = 0,
    this.muted = false,
    this.speaker = true,
  });

  final String status;
  final int seconds;
  final bool muted;
  final bool speaker;

  _CallUiState copyWith(
          {String? status, int? seconds, bool? muted, bool? speaker}) =>
      _CallUiState(
        status: status ?? this.status,
        seconds: seconds ?? this.seconds,
        muted: muted ?? this.muted,
        speaker: speaker ?? this.speaker,
      );
}
