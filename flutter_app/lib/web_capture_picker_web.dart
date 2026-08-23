// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

Future<Uint8List> _blobBytes(html.Blob blob) async {
  final reader = html.FileReader()..readAsArrayBuffer(blob);
  await reader.onLoad.first;
  final result = reader.result;
  return result is ByteBuffer ? Uint8List.view(result) : result as Uint8List;
}

Future<XFile?> captureWebPhoto(BuildContext context) => showDialog<XFile>(
    context: context, barrierDismissible: false,
    builder: (_) => const _WebCameraDialog(videoMode: false));

Future<XFile?> captureWebVideo(BuildContext context) => showDialog<XFile>(
    context: context, barrierDismissible: false,
    builder: (_) => const _WebCameraDialog(videoMode: true));

class _WebCameraDialog extends StatefulWidget {
  final bool videoMode;
  const _WebCameraDialog({required this.videoMode});
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
  bool _ready = false, _recording = false;
  int _seconds = 0;
  String? _error;
  Timer? _timer;

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
      ..style.objectFit = 'cover'
      ..style.backgroundColor = 'black';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (_) => _preview);
    _openCamera();
  }

  Future<void> _openCamera() async {
    try {
      final stream = await html.window.navigator.mediaDevices?.getUserMedia({
        'video': {'facingMode': 'environment'}, 'audio': widget.videoMode,
      });
      if (stream == null) throw Exception('camera unavailable');
      _stream = stream;
      _preview.srcObject = stream;
      await _preview.onLoadedMetadata.first;
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _error =
          'לא ניתן לפתוח את המצלמה. יש לאשר הרשאת מצלמה ומיקרופון בדפדפן.');
    }
  }

  Future<void> _takePhoto() async {
    if (_preview.videoWidth <= 0 || _preview.videoHeight <= 0) return;
    final canvas = html.CanvasElement(
        width: _preview.videoWidth, height: _preview.videoHeight);
    canvas.context2D.drawImage(_preview, 0, 0);
    final bytes = await _blobBytes(await canvas.toBlob('image/jpeg', 0.9));
    if (mounted) Navigator.pop(context, XFile.fromData(bytes,
        name: 'camera-${DateTime.now().millisecondsSinceEpoch}.jpg',
        mimeType: 'image/jpeg'));
  }

  String _mime() {
    for (final value in const ['video/webm;codecs=vp9,opus',
      'video/webm;codecs=vp8,opus', 'video/webm']) {
      if (html.MediaRecorder.isTypeSupported(value)) return value;
    }
    return 'video/webm';
  }

  Future<void> _startRecording() async {
    if (_stream == null) return;
    _chunks.clear();
    final recorder = html.MediaRecorder(_stream!, {'mimeType': _mime()});
    _recorder = recorder;
    recorder.addEventListener('dataavailable', (event) {
      final data = (event as dynamic).data as html.Blob?;
      if (data != null && data.size > 0) _chunks.add(data);
    });
    recorder.addEventListener('stop', (event) async {
      final bytes = await _blobBytes(html.Blob(_chunks, _mime()));
      if (mounted) Navigator.pop(context, XFile.fromData(bytes,
          name: 'camera-${DateTime.now().millisecondsSinceEpoch}.webm',
          mimeType: 'video/webm'));
    });
    recorder.start(1000);
    setState(() { _recording = true; _seconds = 0; });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds++);
      if (_seconds >= 30) _stopRecording();
    });
  }

  void _stopRecording() {
    _timer?.cancel();
    if (_recorder?.state == 'recording') _recorder?.stop();
    if (mounted) setState(() => _recording = false);
  }

  void _close() {
    if (_recording) _recorder?.stop();
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final track in _stream?.getTracks() ?? <html.MediaStreamTrack>[]) {
      track.stop();
    }
    _preview.srcObject = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.videoMode ? 'צילום וידאו' : 'צילום תמונה'),
    content: SizedBox(width: 560, child: Column(mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null)
          Padding(padding: const EdgeInsets.all(20),
            child: Text(_error!, textAlign: TextAlign.center))
        else
          AspectRatio(aspectRatio: 16 / 9, child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: HtmlElementView(viewType: _viewType))),
        if (_recording) ...[
          const SizedBox(height: 10),
          Text('● מקליט  0:${_seconds.toString().padLeft(2, '0')} / 0:30',
            style: const TextStyle(color: Colors.red,
              fontWeight: FontWeight.bold)),
        ],
      ])),
    actions: [
      TextButton(onPressed: _close, child: const Text('ביטול')),
      if (_error == null && !widget.videoMode)
        FilledButton.icon(onPressed: _ready ? _takePhoto : null,
          icon: const Icon(Icons.camera_alt), label: const Text('צלם תמונה')),
      if (_error == null && widget.videoMode)
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: _recording ? Colors.red : null),
          onPressed: !_ready ? null : _recording ? _stopRecording : _startRecording,
          icon: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
          label: Text(_recording ? 'עצור ושמור' : 'התחל צילום')),
    ]);
}
