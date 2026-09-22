import 'dart:async';
import 'package:camera/camera.dart';
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
    if (_opening || _camera != null || !_foreground) return;
    _opening = true;
    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (!mounted || !_foreground) return;
      final camera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first);
      controller =
          CameraController(camera, ResolutionPreset.medium, enableAudio: true);
      await controller.initialize();
      if (!mounted || !_foreground) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _error = null;
      });
    } catch (_) {
      await controller?.dispose();
      if (mounted) {
        setState(() => _error =
            'לא ניתן להפעיל את המצלמה. יש לאפשר גישה למצלמה ולמיקרופון.');
      }
    } finally {
      _opening = false;
      if (mounted && _foreground && _camera == null && _error == null) {
        scheduleMicrotask(_open);
      }
    }
  }

  Future<void> _start() async {
    final camera = _camera;
    if (camera == null ||
        _starting ||
        _finishing ||
        camera.value.isRecordingVideo) {
      return;
    }
    setState(() => _starting = true);
    try {
      await camera.startVideoRecording();
      if (!mounted) return;
      _clock
        ..reset()
        ..start();
      _limit.start();
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() {});
      });
      if (!_foreground) await _finish();
    } catch (_) {
      if (mounted) setState(() => _error = 'לא ניתן להתחיל צילום. נסה שוב.');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _finish() async {
    final camera = _camera;
    if (camera == null || _finishing || !camera.value.isRecordingVideo) {
      return;
    }
    setState(() => _finishing = true);
    _limit.cancel();
    _ticker?.cancel();
    _clock.stop();
    try {
      var file = await camera.stopVideoRecording();
      // CameraX writes MP4 recordings with a .temp suffix and no MIME type.
      // XFile ignores `name` on native platforms, so save with the real suffix
      // before passing the recording to playback and upload.
      if (file.path.toLowerCase().endsWith('.temp')) {
        final path = '${file.path.substring(0, file.path.length - 5)}.mp4';
        await file.saveTo(path);
        file = XFile(path, mimeType: 'video/mp4');
      }
      if (mounted) Navigator.of(context).pop(file);
    } catch (_) {
      if (mounted) {
        setState(() {
          _finishing = false;
          _error = 'לא ניתן לשמור את הסרטון. נסה שוב.';
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _open();
    } else if (_camera?.value.isRecordingVideo == true) {
      _finish();
    } else if (!_starting) {
      final camera = _camera;
      _camera = null;
      camera?.dispose();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _limit.cancel();
    _ticker?.cancel();
    _clock.stop();
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final recording = camera?.value.isRecordingVideo == true;
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
              onPressed: camera == null || _starting || _finishing
                  ? null
                  : recording
                      ? _finish
                      : _start,
              icon: Icon(recording ? Icons.stop : Icons.videocam),
              label: Text(_finishing
                  ? 'שומר...'
                  : recording
                      ? 'עצור ושלח'
                      : 'התחל צילום'),
            )),
      ])),
    );
  }
}
