import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'recording_upload.dart';
import 'recording_audio_web_types.dart';
import 'recording_audio_web_stub.dart'
    if (dart.library.html) 'recording_audio_web.dart';

class ProgressiveAudioRecorder {
  final level = ValueNotifier<double>(0);
  Timer? _levelTimer;
  bool _readingLevel = false;
  final _native = AudioRecorder();
  WebRecordingAudio? _web;
  RecordingUpload? _stage;
  String? _lastPath;
  bool _disposed = false, _nativeActive = false;
  Future<bool> hasPermission() => _native.hasPermission();
  Future<bool> isEncoderSupported(AudioEncoder encoder) =>
      _native.isEncoderSupported(encoder);
  Future<bool> isRecording() async =>
      _web?.recording ?? await _native.isRecording();

  Future<void> start(RecordConfig config,
      {required String path,
      required String api,
      required String token,
      required String name}) async {
    await cancel();
    if (_disposed) return;
    if (kIsWeb && config.encoder == AudioEncoder.opus) {
      _web = await startWebRecordingAudio(api: api, token: token, name: name);
      if (_web != null) {
        if (_disposed) await cancel();
        if (!_disposed) _startLevelMeter();
        return;
      }
    }
    await _native.start(config, path: path);
    _nativeActive = true;
    if (_disposed) {
      await _native.cancel();
      return;
    }
    if (!kIsWeb) {
      _stage = RecordingUpload.file(
          api: api, token: token, name: name, mime: 'audio/wav', path: path);
    }
    _startLevelMeter();
  }

  void _startLevelMeter() {
    _levelTimer?.cancel();
    _levelTimer = Timer.periodic(const Duration(milliseconds: 80), (_) async {
      if (_disposed || _readingLevel) return;
      _readingLevel = true;
      try {
        final value = _web?.level ??
            (math.pow(10, (await _native.getAmplitude()).current / 20) * 4)
                .clamp(0.0, 1.0)
                .toDouble();
        if (!_disposed && _levelTimer != null) level.value = value;
      } catch (_) {
        // Unsupported meters leave the recording controls usable.
      } finally {
        _readingLevel = false;
      }
    });
  }

  void _stopLevelMeter() {
    _levelTimer?.cancel();
    _levelTimer = null;
    if (!_disposed) level.value = 0;
  }

  Future<String?> stop() async {
    _stopLevelMeter();
    final web = _web;
    _web = null;
    final path = web != null ? await web.stop() : await _native.stop();
    _nativeActive = false;
    _lastPath = path;
    if (path != null) {
      _stage?.attach(XFile(path, mimeType: 'audio/wav'));
    } else {
      await _stage?.cancel();
    }
    _stage = null;
    return path;
  }

  Future<void> cancel() async {
    _stopLevelMeter();
    final web = _web;
    _web = null;
    await web?.cancel();
    if (_nativeActive) {
      _nativeActive = false;
      await _native.cancel();
    }
    await _stage?.cancel();
    _stage = null;
    if (_lastPath != null) await RecordingUpload.discard(XFile(_lastPath!));
    _lastPath = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancel();
    await _native.dispose();
    level.dispose();
  }
}
