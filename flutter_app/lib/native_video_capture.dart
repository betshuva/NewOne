import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'video_recording_limit.dart';

Future<XFile?> captureNativeVideo(BuildContext context,
        {required Duration maxDuration}) =>
    Navigator.of(context).push<XFile>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _VideoCapture(maxDuration: maxDuration)));

class _VideoCapture extends StatefulWidget {
  final Duration maxDuration;
  const _VideoCapture({required this.maxDuration});
  @override
  State<_VideoCapture> createState() => _VideoCaptureState();
}

class _VideoCaptureState extends State<_VideoCapture>
    with WidgetsBindingObserver {
  CameraController? _camera;
  Future<void>? _closingCamera;
  XFile? _pendingVideo;
  late final VideoRecordingLimit _limit;
  Timer? _ticker;
  final _clock = Stopwatch();
  bool _opening = false, _starting = false, _finishing = false;
  bool _foreground = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _limit =
        VideoRecordingLimit(duration: widget.maxDuration, onLimit: _finish);
    _open();
  }

  Future<void> _open() async {
    if (!mounted ||
        _opening ||
        _finishing ||
        _camera != null ||
        _pendingVideo != null ||
        !_foreground) {
      return;
    }
    setState(() {
      _opening = true;
      _error = null;
    });
    if (kDebugMode) debugPrint('[video-capture] Opening camera');
    CameraController? controller;
    try {
      await _closingCamera;
      if (!mounted || !_foreground) return;
      final cameras = await availableCameras();
      if (!mounted || !_foreground) return;
      final camera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first);
      controller =
          CameraController(camera, ResolutionPreset.medium, enableAudio: true);
      await controller.initialize();
      if (kDebugMode) debugPrint('[video-capture] Camera initialized');
      if (!mounted || !_foreground) {
        await _disposeController(controller);
        return;
      }
      setState(() {
        _camera = controller;
        _error = null;
      });
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('[video-capture] Camera initialization failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      if (controller != null) await _disposeController(controller);
      if (mounted) {
        setState(() => _error =
            'לא ניתן להפעיל את המצלמה. יש לאפשר גישה למצלמה ולמיקרופון.');
      }
    } finally {
      _opening = false;
      if (mounted) setState(() {});
      if (mounted && _foreground && _camera == null && _error == null) {
        scheduleMicrotask(_open);
      }
    }
  }

  Future<void> _disposeController(CameraController camera) async {
    try {
      await camera.dispose();
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('[video-capture] Camera disposal failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
  }

  Future<void> _closeCamera() async {
    final camera = _camera;
    _camera = null;
    if (camera == null) {
      await _closingCamera;
      return;
    }
    final closing = _disposeController(camera);
    _closingCamera = closing;
    try {
      await closing;
    } finally {
      if (identical(_closingCamera, closing)) _closingCamera = null;
    }
  }

  Future<void> _retry() => _pendingVideo != null ? _finish() : _open();

  Future<void> _start() async {
    final camera = _camera;
    if (camera == null ||
        _starting ||
        _finishing ||
        camera.value.isRecordingVideo) {
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    if (kDebugMode) debugPrint('[video-capture] Starting recording');
    try {
      await camera.startVideoRecording();
      if (kDebugMode) debugPrint('[video-capture] Recording started');
      if (!mounted) return;
      _clock
        ..reset()
        ..start();
      _limit.start();
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() {});
      });
      if (!_foreground) await _finish();
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('[video-capture] Recording start failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      await _closeCamera();
      if (mounted) setState(() => _error = 'לא ניתן להתחיל צילום. נסה שוב.');
    } finally {
      _starting = false;
      if (mounted) {
        setState(() {});
      } else {
        await _closeCamera();
      }
    }
  }

  Future<void> _finish() async {
    final camera = _camera;
    if (!mounted ||
        _finishing ||
        (_pendingVideo == null && camera?.value.isRecordingVideo != true)) {
      return;
    }
    setState(() => _finishing = true);
    _limit.cancel();
    _ticker?.cancel();
    _clock.stop();
    if (kDebugMode) {
      debugPrint(
          '[video-capture] Stopping after ${_clock.elapsedMilliseconds} ms');
    }
    try {
      // Retain a completed recording if copying it fails, so retry never records
      // or stops the native camera a second time.
      _pendingVideo ??= await camera!.stopVideoRecording();
      var file = _pendingVideo!;
      // Older CameraX versions write MP4 with a .temp suffix and no MIME type.
      // XFile ignores `name` on native platforms, so save with the real suffix
      // before passing the recording to playback and upload.
      if (file.path.toLowerCase().endsWith('.temp')) {
        final path = '${file.path.substring(0, file.path.length - 5)}.mp4';
        await file.saveTo(path);
        file = XFile(path, mimeType: 'video/mp4');
      }
      if (kDebugMode) debugPrint('[video-capture] Recording saved');
      if (mounted) Navigator.of(context).pop(file);
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('[video-capture] Recording save failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      // A failed native stop can leave isRecordingVideo stuck true. Never reuse
      // that controller, or dispose it concurrently with a pending stop.
      await _closeCamera();
      if (_pendingVideo == null) _clock.reset();
      if (mounted) {
        setState(() {
          _finishing = false;
          _error = 'לא ניתן לשמור את הסרטון. נסה שוב.';
        });
      }
    } finally {
      _finishing = false;
      if (!mounted) await _closeCamera();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (mounted) setState(() {});
    if (_starting || _finishing) return;
    if (_foreground) {
      if (_error == null) _open();
    } else if (_camera?.value.isRecordingVideo == true) {
      _finish();
    } else {
      _closeCamera();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _limit.cancel();
    _ticker?.cancel();
    _clock.stop();
    if (!_starting && !_finishing) _closeCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final recording = camera?.value.isRecordingVideo == true;
    final busy = _opening || _starting || _finishing;
    final remaining = (widget.maxDuration.inSeconds - _clock.elapsed.inSeconds)
        .clamp(0, widget.maxDuration.inSeconds);
    return Scaffold(
      appBar: AppBar(title: const Text('צילום וידאו')),
      body: SafeArea(
          child: Column(children: [
        Expanded(
            child: Center(
                child: _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(24), child: Text(_error!))
                    : camera == null
                        ? const CircularProgressIndicator()
                        : AspectRatio(
                            aspectRatio: camera.value.aspectRatio,
                            child: CameraPreview(camera)))),
        Text('זמן שנותר: 00:${remaining.toString().padLeft(2, '0')}',
            textDirection: TextDirection.rtl),
        Padding(
            padding: const EdgeInsets.all(20),
            child: FilledButton.icon(
              onPressed: busy || !_foreground
                  ? null
                  : _error != null
                      ? _retry
                      : camera == null
                          ? null
                          : recording
                              ? _finish
                              : _start,
              icon: Icon(_error != null
                  ? Icons.refresh
                  : recording
                      ? Icons.stop
                      : Icons.videocam),
              label: Text(_finishing
                  ? 'שומר...'
                  : _error != null
                      ? 'נסה שוב'
                      : recording
                          ? 'עצור ושלח'
                          : 'התחל צילום'),
            )),
      ])),
    );
  }
}
