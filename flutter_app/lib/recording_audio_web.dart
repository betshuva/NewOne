// MediaRecorder remains the recording bridge used by this Flutter web build.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:web_audio' as audio;
import 'package:image_picker/image_picker.dart';
import 'recording_audio_web_types.dart';
import 'recording_upload.dart';

Future<WebRecordingAudio?> startWebRecordingAudio(
    {required String api, required String token, required String name}) async {
  if (!html.MediaRecorder.isTypeSupported('audio/webm;codecs=opus')) {
    return null;
  }
  final stream =
      await html.window.navigator.mediaDevices!.getUserMedia({'audio': true});
  try {
    return _WebAudio(stream, api: api, token: token, name: name);
  } catch (_) {
    for (final track in stream.getTracks()) {
      track.stop();
    }
    rethrow;
  }
}

class _WebAudio implements WebRecordingAudio {
  _WebAudio(this.stream,
      {required String api, required String token, required this.name}) {
    recorder = html.MediaRecorder(stream,
        {'mimeType': 'audio/webm;codecs=opus', 'audioBitsPerSecond': 32000});
    stage = RecordingUpload(
        api: api,
        token: token,
        name: name,
        mime: 'audio/webm',
        length: () async => chunks.fold<int>(0, (sum, b) => sum + b.size),
        read: (start, end) => _readBlob(html.Blob(chunks).slice(start, end)));
    recorder.addEventListener('dataavailable', (event) {
      final blob = (event as dynamic).data as html.Blob?;
      if (blob != null && blob.size > 0) chunks.add(blob);
    });
    recorder.addEventListener('error', (_) {
      failed = true;
      unawaited(stage.cancel());
      if (!stopped.isCompleted) stopped.complete();
      _stopTracks();
    });
    recorder.addEventListener('stop', (_) {
      if (!stopped.isCompleted) stopped.complete();
    });
    recorder.start(1000);
    try {
      final context = _audioContext = audio.AudioContext();
      final analyser = _analyser = context.createAnalyser()..fftSize = 256;
      _samples = Float32List(analyser.fftSize!);
      _source = context.createMediaStreamSource(stream)..connectNode(analyser);
      unawaited(context.resume().catchError((_) {}));
    } catch (_) {
      // Meter availability must not interrupt the recording itself.
    }
  }
  final html.MediaStream stream;
  final String name;
  final chunks = <html.Blob>[];
  final stopped = Completer<void>();
  late final html.MediaRecorder recorder;
  late final RecordingUpload stage;
  bool failed = false;
  audio.AudioContext? _audioContext;
  audio.AnalyserNode? _analyser;
  audio.MediaStreamAudioSourceNode? _source;
  Float32List? _samples;
  @override
  double get level {
    final analyser = _analyser;
    final samples = _samples;
    if (!recording || analyser == null || samples == null) return 0;
    analyser.getFloatTimeDomainData(samples);
    final energy = samples.fold<double>(0, (sum, value) => sum + value * value);
    return (math.sqrt(energy / samples.length) * 4).clamp(0.0, 1.0);
  }

  @override
  bool get recording => recorder.state == 'recording';
  void _stopTracks() {
    _source?.disconnect();
    _source = null;
    _analyser = null;
    _samples = null;
    final context = _audioContext;
    _audioContext = null;
    if (context != null) unawaited(context.close().catchError((_) {}));
    for (final track in stream.getTracks()) {
      track.stop();
    }
  }

  @override
  Future<String?> stop() async {
    try {
      if (recording) recorder.stop();
      await stopped.future.timeout(const Duration(seconds: 10));
      if (failed || chunks.isEmpty) throw StateError('ההקלטה לא הושלמה');
      // Include the final dataavailable event, emitted before stop.
      final blob = html.Blob(chunks, 'audio/webm');
      if (blob.size < 256) throw StateError('ההקלטה קצרה מדי');
      final path = html.Url.createObjectUrlFromBlob(blob);
      stage.attach(XFile(path, name: name, mimeType: 'audio/webm'));
      return path;
    } catch (_) {
      await stage.cancel();
      rethrow;
    } finally {
      _stopTracks();
    }
  }

  @override
  Future<void> cancel() async {
    failed = true;
    if (recording) recorder.stop();
    _stopTracks();
    await stage.cancel();
  }
}

Future<Uint8List> _readBlob(html.Blob blob) async {
  final reader = html.FileReader();
  final complete = Completer<Uint8List>();
  final load = reader.onLoad.listen((_) {
    final data = reader.result;
    complete.complete(
        data is ByteBuffer ? Uint8List.view(data) : data as Uint8List);
  });
  final error = reader.onError.listen(
      (_) => complete.completeError(StateError('Recording read failed')));
  try {
    reader.readAsArrayBuffer(blob);
    return await complete.future.timeout(const Duration(seconds: 10));
  } finally {
    await load.cancel();
    await error.cancel();
  }
}
