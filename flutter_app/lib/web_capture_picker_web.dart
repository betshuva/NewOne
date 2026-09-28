// Legacy MediaRecorder bridge required by the current Flutter web integration.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'media_pointer_barrier.dart';
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'capture_file_name.dart';

Future<Uint8List> _blobBytes(html.Blob blob) async {
  final reader = html.FileReader();
  final loaded = Completer<void>();
  void fail() {
    if (!loaded.isCompleted) {
      loaded.completeError(StateError('Could not read camera capture'));
    }
  }

  final subscriptions = [
    reader.onLoad.listen((_) {
      if (!loaded.isCompleted) loaded.complete();
    }),
    reader.onError.listen((_) => fail()),
    reader.onAbort.listen((_) => fail()),
  ];
  try {
    reader.readAsArrayBuffer(blob);
    await loaded.future.timeout(const Duration(seconds: 10));
    final result = reader.result;
    return result is ByteBuffer ? Uint8List.view(result) : result as Uint8List;
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    if (reader.readyState == html.FileReader.LOADING) reader.abort();
  }
}

Future<XFile?> captureWebPhoto(BuildContext context,
        {required String creatorId}) =>
    showDialog<XFile>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            MediaPointerBarrier(child: _WebCameraDialog(videoMode: false, creatorId: creatorId)));

Future<XFile?> captureWebVideo(BuildContext context,
        {required String creatorId}) =>
    showDialog<XFile>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            MediaPointerBarrier(child: _WebCameraDialog(videoMode: true, creatorId: creatorId)));

class _WebCameraDialog extends StatefulWidget {
  final bool videoMode;
  final String creatorId;
  const _WebCameraDialog({required this.videoMode, required this.creatorId});
  @override
  State<_WebCameraDialog> createState() => _WebCameraDialogState();
}

class _WebCameraDialogState extends State<_WebCameraDialog> {
  static int _nextId = 0;
  late final String _viewType;
  late final html.VideoElement _preview;
  html.MediaStream? _stream;
  html.MediaRecorder? _recorder;
  final List<html.Blob> _chunks = [];
  bool _ready = false, _recording = false, _startingRecording = false;
  bool _savingRecording = false, _closing = false;
  bool _capturingPhoto = false;
  int _cameraAttempt = 0;
  int _seconds = 0;
  String? _error;
  Timer? _timer;
  final Stopwatch _recordingClock = Stopwatch();

  String _recordingTime() {
    final remaining = (30 - _recordingClock.elapsed.inSeconds).clamp(0, 30);
    return '00:${remaining.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    _viewType = 'betshuva-camera-${_nextId++}';
    _preview = html.VideoElement()
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.display = 'block'
      ..style.objectFit = 'cover'
      ..style.backgroundColor = 'black';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (_) => _preview);
    _openCamera();
  }

  Future<void> _openCamera() async {
    final attempt = ++_cameraAttempt;
    html.MediaStream? openedStream;
    if (mounted) {
      setState(() {
        _ready = false;
        _error = null;
      });
    }
    try {
      for (final track in _stream?.getTracks() ?? <html.MediaStreamTrack>[]) {
        track.stop();
      }
      _stream = null;
      _preview.srcObject = null;
      final stream = await html.window.navigator.mediaDevices?.getUserMedia({
        'video': {'facingMode': 'environment'},
        'audio': widget.videoMode,
      });
      if (stream == null) throw Exception('camera unavailable');
      openedStream = stream;
      if (!mounted || _closing || attempt != _cameraAttempt) {
        for (final track in stream.getTracks()) {
          track.stop();
        }
        return;
      }
      _stream = stream;
      _preview.srcObject = stream;
      if (_preview.readyState < 1) {
        await _preview.onLoadedMetadata.first
            .timeout(const Duration(seconds: 8));
      }
      await _preview.play().timeout(const Duration(seconds: 8));
      if (_preview.videoWidth <= 0 || _preview.videoHeight <= 0) {
        await _preview.onCanPlay.first.timeout(const Duration(seconds: 8));
      }
      if (_preview.paused) {
        await _preview.play().timeout(const Duration(seconds: 8));
      }
      if (mounted && !_closing && attempt == _cameraAttempt) {
        setState(() => _ready = true);
      }
    } catch (error) {
      for (final track
          in openedStream?.getTracks() ?? <html.MediaStreamTrack>[]) {
        track.stop();
      }
      if (mounted && !_closing && attempt == _cameraAttempt) {
        _stream = null;
        _preview.srcObject = null;
        setState(() {
          _ready = false;
          _error =
              'לא ניתן להפעיל את המצלמה. יש לאשר הרשאת מצלמה ומיקרופון בדפדפן ולנסות שוב.';
        });
      }
    }
  }

  Future<void> _takePhoto() async {
    if (_capturingPhoto ||
        _preview.videoWidth <= 0 ||
        _preview.videoHeight <= 0) {
      return;
    }
    setState(() => _capturingPhoto = true);
    try {
      final canvas = html.CanvasElement(
          width: _preview.videoWidth, height: _preview.videoHeight);
      final name = captureFileNames.create(
          kind: 'photo', extension: 'jpg', creatorId: widget.creatorId);
      canvas.context2D.drawImage(_preview, 0, 0);
      final bytes = await _blobBytes(await canvas.toBlob('image/jpeg', 0.9));
      if (!mounted || _closing) return;
      if (bytes.isEmpty) throw Exception('empty camera image');
      _closing = true;
      Navigator.pop(
        context,
        XFile.fromData(bytes, name: name, mimeType: 'image/jpeg'),
      );
    } catch (_) {
      if (mounted && !_closing) {
        setState(() {
          _capturingPhoto = false;
          _error = 'לא ניתן לעבד את התמונה. יש לנסות לצלם שוב.';
        });
      }
    }
  }

  String? _supportedMime() {
    for (final value in const [
      'video/webm;codecs=vp9,opus',
      'video/webm;codecs=vp8,opus',
      'video/webm'
    ]) {
      if (html.MediaRecorder.isTypeSupported(value)) return value;
    }
    return null;
  }

  Future<void> _startRecording() async {
    if (_stream == null ||
        !_ready ||
        _startingRecording ||
        _recording ||
        _savingRecording ||
        _closing) {
      return;
    }
    setState(() {
      _startingRecording = true;
      _error = null;
    });
    try {
      if (_preview.paused) {
        await _preview.play().timeout(const Duration(seconds: 8));
      }
      if (!mounted || _closing) return;
      _chunks.clear();
      final mime = _supportedMime();
      final recorder = mime == null
          ? html.MediaRecorder(_stream!)
          : html.MediaRecorder(_stream!, {'mimeType': mime});
      final name = captureFileNames.create(
          kind: 'video', extension: 'webm', creatorId: widget.creatorId);
      _recorder = recorder;
      recorder.addEventListener('dataavailable', (event) {
        if (_closing || _recorder != recorder) return;
        final data = (event as dynamic).data as html.Blob?;
        if (data != null && data.size > 0) _chunks.add(data);
      });
      recorder.addEventListener('error', (_) {
        if (_closing || _recorder != recorder) return;
        _recorder = null;
        _timer?.cancel();
        _recordingClock.stop();
        if (mounted) {
          setState(() {
            _recording = false;
            _startingRecording = false;
            _savingRecording = false;
            _error = 'הדפדפן הפסיק את ההקלטה. נסה שוב או בחר סרטון מהמכשיר.';
          });
        }
      });
      recorder.addEventListener('stop', (_) async {
        if (!mounted || _closing || _recorder != recorder) return;
        _timer?.cancel();
        _recordingClock.stop();
        setState(() {
          _recording = false;
          _savingRecording = true;
        });
        try {
          if (_chunks.isEmpty) throw StateError('No camera recording data');
          final outputMime = mime ?? 'video/webm';
          final bytes = await _blobBytes(html.Blob(_chunks, outputMime));
          if (!mounted || _closing || _recorder != recorder) return;
          if (bytes.isEmpty) throw StateError('Empty camera recording');
          final isWebM = bytes.length >= 4 &&
              bytes[0] == 0x1A &&
              bytes[1] == 0x45 &&
              bytes[2] == 0xDF &&
              bytes[3] == 0xA3;
          if (!isWebM) throw StateError('Invalid WebM camera recording');
          _closing = true;
          Navigator.pop(
              context,
              XFile.fromData(bytes,
                  name: name, mimeType: outputMime.split(';').first));
        } catch (_) {
          if (mounted && !_closing && _recorder == recorder) {
            _recorder = null;
            setState(() {
              _savingRecording = false;
              _error = 'לא ניתן לשמור את הסרטון. נסה שוב או בחר סרטון מהמכשיר.';
            });
          }
        }
      });
      // A single final MediaRecorder blob is the most interoperable WebM.
      // Concatenating timed chunks can produce an invalid container in some
      // Chromium versions even though each dataavailable event is non-empty.
      recorder.start();
      _recordingClock
        ..reset()
        ..start();
      setState(() {
        _recording = true;
        _startingRecording = false;
        _seconds = 0;
      });
      _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        final elapsedSeconds = _recordingClock.elapsed.inSeconds.clamp(0, 30);
        if (elapsedSeconds != _seconds) {
          setState(() => _seconds = elapsedSeconds);
        }
        if (_recordingClock.elapsed >= const Duration(seconds: 30)) {
          _stopRecording();
        }
      });
    } catch (_) {
      _timer?.cancel();
      _recordingClock.stop();
      if (mounted) {
        setState(() {
          _recording = false;
          _startingRecording = false;
          _savingRecording = false;
          _error = 'לא ניתן להתחיל הקלטה בדפדפן. נסה שוב או בחר סרטון מהמכשיר.';
        });
      }
    }
  }

  void _stopRecording() {
    if (_savingRecording || _closing || _recorder?.state != 'recording') return;
    _timer?.cancel();
    _recordingClock.stop();
    if (mounted) {
      setState(() {
        _recording = false;
        _savingRecording = true;
      });
    }
    _recorder?.stop();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    if (_recorder?.state == 'recording') _recorder?.stop();
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _closing = true;
    _cameraAttempt++;
    _timer?.cancel();
    _recordingClock.stop();
    if (_recorder?.state == 'recording') _recorder?.stop();
    for (final track in _stream?.getTracks() ?? <html.MediaStreamTrack>[]) {
      track.stop();
    }
    _preview
      ..pause()
      ..srcObject = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.videoMode ? 'צילום וידאו' : 'צילום תמונה'),
          content: SizedBox(
              width: 560,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                            onPressed: _openCamera,
                            icon: const Icon(Icons.refresh),
                            label: const Text('נסה שוב')),
                      ]))
                else if (_capturingPhoto)
                  const SizedBox(
                    height: 315,
                    child: Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 14),
                        Text('מעבד את התמונה...'),
                      ]),
                    ),
                  )
                else
                  AspectRatio(
                      aspectRatio: 16 / 9,
                      child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(fit: StackFit.expand, children: [
                            HtmlElementView(viewType: _viewType),
                            if (!_ready)
                              const ColoredBox(
                                color: Colors.black,
                                child:
                                    Center(child: CircularProgressIndicator()),
                              ),
                          ]))),
                if (_recording) ...[
                  const SizedBox(height: 10),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text('● זמן שנותר  ${_recordingTime()}',
                        style: const TextStyle(
                            color: Colors.red, fontWeight: FontWeight.bold)),
                  ),
                ],
              ])),
          actions: [
            TextButton(onPressed: _close, child: const Text('ביטול')),
            if (_error == null && !widget.videoMode)
              FilledButton.icon(
                  onPressed: _ready && !_capturingPhoto ? _takePhoto : null,
                  icon: const Icon(Icons.camera_alt),
                  label: Text(_capturingPhoto ? 'מעבד...' : 'צלם תמונה')),
            if (_error == null && widget.videoMode)
              FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: _recording ? Colors.red : null),
                  onPressed: !_ready || _startingRecording || _savingRecording
                      ? null
                      : _recording
                          ? _stopRecording
                          : _startRecording,
                  icon: _savingRecording
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(
                          _recording ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(_savingRecording
                      ? 'שומר...'
                      : _startingRecording
                          ? 'מתחיל...'
                          : _recording
                              ? 'עצור ושמור'
                              : 'התחל צילום')),
          ]);
}
