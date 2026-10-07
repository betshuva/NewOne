import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'recording_upload.dart';
import 'recording_audio_web_types.dart';
import 'recording_audio_web_stub.dart'
    if (dart.library.html) 'recording_audio_web.dart';

class ProgressiveAudioRecorder {
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
  }

  Future<String?> stop() async {
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
  }
}
