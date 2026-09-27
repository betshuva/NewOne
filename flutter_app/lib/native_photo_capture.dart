import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

// Keep the camera in our activity: low-memory Android devices may kill the
// messenger while an external camera activity is open, losing its recipient.
Future<XFile?> captureNativePhoto(BuildContext context) =>
    Navigator.of(context).push<XFile>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const _PhotoCapture(),
    ));

class _PhotoCapture extends StatefulWidget {
  const _PhotoCapture();
  @override
  State<_PhotoCapture> createState() => _PhotoCaptureState();
}

class _PhotoCaptureState extends State<_PhotoCapture>
    with WidgetsBindingObserver {
  CameraController? _camera;
  Future<void>? _closing;
  XFile? _photo;
  Uint8List? _preview;
  bool _opening = false, _taking = false, _foreground = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  Future<void> _close() async {
    final camera = _camera;
    _camera = null;
    if (camera == null) {
      await _closing;
      return;
    }
    final closing = camera.dispose();
    _closing = closing;
    try {
      await closing;
    } finally {
      if (identical(_closing, closing)) _closing = null;
    }
  }

  Future<void> _open() async {
    if (!mounted ||
        !_foreground ||
        _opening ||
        _taking ||
        _camera != null ||
        _photo != null) {
      return;
    }
    setState(() {
      _opening = true;
      _error = null;
    });
    CameraController? camera;
    try {
      await _closing;
      if (!mounted || !_foreground) return;
      final cameras = await availableCameras();
      if (!mounted || !_foreground) return;
      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      camera = CameraController(description, ResolutionPreset.high,
          enableAudio: false);
      await camera.initialize();
      if (!mounted || !_foreground) {
        await camera.dispose();
        return;
      }
      setState(() => _camera = camera);
    } catch (_) {
      await camera?.dispose();
      if (mounted) {
        setState(() => _error =
            'לא ניתן להפעיל את המצלמה. יש לאפשר גישה למצלמה ולנסות שוב.');
      }
    } finally {
      _opening = false;
      if (mounted) {
        setState(() {});
        if (_foreground &&
            _camera == null &&
            _photo == null &&
            _error == null) {
          scheduleMicrotask(_open);
        }
      }
    }
  }

  Future<void> _take() async {
    final camera = _camera;
    if (camera == null || _taking || !_foreground) return;
    setState(() {
      _taking = true;
      _error = null;
    });
    try {
      final photo = await camera.takePicture();
      final preview = await photo.readAsBytes();
      await _close();
      if (mounted) {
        setState(() {
          _photo = photo;
          _preview = preview;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'לא ניתן לצלם. נסה שוב.');
    } finally {
      _taking = false;
      if (!mounted || !_foreground) await _close();
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_taking) return;
    if (_foreground) {
      _open();
    } else {
      _close();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!_taking) _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('צילום תמונה')),
        body: SafeArea(
            child: Column(children: [
          Expanded(
              child: Center(
                  child: _preview != null
                      ? Image.memory(_preview!, fit: BoxFit.contain)
                      : _camera != null && _foreground
                          ? CameraPreview(_camera!)
                          : _opening
                              ? const CircularProgressIndicator()
                              : const SizedBox())),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.white),
                    textDirection: TextDirection.rtl)),
          Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: _photo != null
                    ? [
                        TextButton(
                            onPressed: () {
                              setState(() {
                                _photo = null;
                                _preview = null;
                              });
                              _open();
                            },
                            child: const Text('צלם שוב')),
                        FilledButton.icon(
                            onPressed: () => Navigator.of(context).pop(_photo),
                            icon: const Icon(Icons.check),
                            label: const Text('השתמש בתמונה')),
                      ]
                    : [
                        FilledButton.icon(
                            onPressed: _taking || _opening || !_foreground
                                ? null
                                : _camera == null
                                    ? _open
                                    : _take,
                            icon: const Icon(Icons.camera_alt),
                            label: Text(_taking
                                ? 'מצלם…'
                                : _camera == null
                                    ? 'נסה שוב'
                                    : 'צלם')),
                      ],
              )),
        ])),
      );
}
