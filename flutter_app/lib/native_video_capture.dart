import 'recording_upload.dart';
import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'capture_file_name.dart';
import 'video_recording_limit.dart';

Future<XFile?> captureNativeVideo(BuildContext context,
        {required Duration maxDuration,
        required String creatorId,
        String? api,
        String? token}) =>
    Navigator.of(context).push<XFile>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _VideoCapture(
            maxDuration: maxDuration,
            creatorId: creatorId,
            api: api,
            token: token)));

Future<XFile?> captureNativeCamera(BuildContext context,
    {required Duration maxDuration,
    required String creatorId,
    required bool imagesAllowed,
    required bool videoAllowed,
    String? api,
    String? token}) {
  if (!imagesAllowed && !videoAllowed) return Future.value(null);
  return Navigator.of(context).push<XFile>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _VideoCapture(
          maxDuration: maxDuration,
          api: api,
          token: token,
          creatorId: creatorId,
          imagesAllowed: imagesAllowed,
          videoAllowed: videoAllowed,
          unified: true)));
}

class _VideoCapture extends StatefulWidget {
  final Duration maxDuration;
  final String creatorId;
  final String? api, token;
  final bool imagesAllowed, videoAllowed, unified;
  const _VideoCapture(
      {required this.maxDuration,
      required this.creatorId,
      this.api,
      this.token,
      this.imagesAllowed = false,
      this.videoAllowed = true,
      this.unified = false});
  @override
  State<_VideoCapture> createState() => _VideoCaptureState();
}

class _VideoCaptureState extends State<_VideoCapture>
    with WidgetsBindingObserver {
  CameraController? _camera;
  Future<void>? _closingCamera;
  XFile? _pendingVideo;
  RecordingUpload? _upload;
  String? _recordingFileName;
  late final VideoRecordingLimit _limit;
  Timer? _ticker;
  final _clock = Stopwatch();
  bool _opening = false, _starting = false, _finishing = false;
  bool _takingPhoto = false, _switching = false;
  late bool _video;
  XFile? _photo;
  Uint8List? _photoPreview;
  bool _foreground = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _video = !widget.imagesAllowed;
    _limit =
        VideoRecordingLimit(duration: widget.maxDuration, onLimit: _finish);
    _open();
  }

  Future<void> _open() async {
    if (!mounted ||
        _opening ||
        _finishing ||
        _takingPhoto ||
        _switching ||
        _photo != null ||
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
      controller = CameraController(
          camera, _video ? ResolutionPreset.medium : ResolutionPreset.high,
          enableAudio: _video);
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
        setState(() => _error = _video
            ? 'לא ניתן להפעיל את המצלמה. יש לאפשר גישה למצלמה ולמיקרופון.'
            : 'לא ניתן להפעיל את המצלמה. יש לאפשר גישה למצלמה ולנסות שוב.');
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

  Future<void> _changeMode(bool video) async {
    if (_video == video ||
        _opening ||
        _switching ||
        _takingPhoto ||
        _starting ||
        _finishing ||
        !_foreground ||
        _photo != null ||
        _pendingVideo != null ||
        _camera?.value.isRecordingVideo == true ||
        (video ? !widget.videoAllowed : !widget.imagesAllowed)) {
      return;
    }
    setState(() {
      _switching = true;
      _video = video;
      _error = null;
    });
    await _closeCamera();
    _switching = false;
    if (mounted) await _open();
  }

  Future<void> _takePhoto() async {
    final camera = _camera;
    if (camera == null || _video || _takingPhoto || !_foreground) return;
    setState(() {
      _takingPhoto = true;
      _error = null;
    });
    try {
      final photo = await camera.takePicture();
      final preview = await photo.readAsBytes();
      await _closeCamera();
      if (mounted) {
        setState(() {
          _photo = photo;
          _photoPreview = preview;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'לא ניתן לצלם. נסה שוב.');
    } finally {
      _takingPhoto = false;
      if (!mounted || !_foreground) await _closeCamera();
      if (mounted) setState(() {});
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
    setState(() {
      _starting = true;
      _error = null;
    });
    if (kDebugMode) debugPrint('[video-capture] Starting recording');
    try {
      unawaited(_upload?.cancel());
      _upload = null;
      _recordingFileName = captureFileNames.create(
          kind: 'video', extension: 'mp4', creatorId: widget.creatorId);
      await camera.startVideoRecording();
      if (mounted &&
          widget.api != null &&
          widget.token != null &&
          defaultTargetPlatform == TargetPlatform.android &&
          CameraPlatform.instance is AndroidCameraCameraX) {
        // CameraX 0.7.4+8 is pinned. Other backends retain the standard upload.
        final backend = CameraPlatform.instance as AndroidCameraCameraX;
        // ignore: invalid_use_of_visible_for_testing_member
        final path = backend.videoOutputPath;
        if (path != null) {
          _upload = RecordingUpload.file(
              api: widget.api!,
              token: widget.token!,
              name: _recordingFileName!,
              mime: 'video/mp4',
              path: path);
        }
      }
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
      final recording = _pendingVideo!;
      // Older CameraX versions write MP4 with a .temp suffix and no MIME type.
      // XFile ignores `name` on native platforms, so the actual saved path must
      // carry the descriptive name and real container suffix.
      final originalExtension = recording.name.split('.').last.toLowerCase();
      final extension = originalExtension == 'temp' ? 'mp4' : originalExtension;
      final reservedName = _recordingFileName!;
      final name =
          '${reservedName.substring(0, reservedName.length - 3)}$extension';
      final path = Uri.file(recording.path).resolve(name).toFilePath();
      await recording.saveTo(path);
      final mimeType = extension == 'mp4'
          ? 'video/mp4'
          : extension == 'mov'
              ? 'video/quicktime'
              : recording.mimeType;
      final file = XFile(path, mimeType: mimeType);
      if (kDebugMode) debugPrint('[video-capture] Recording saved');
      if (mounted) {
        _upload?.attach(file);
        _upload = null; // ownership passes to the final chat send flow
        Navigator.of(context).pop(file);
      }
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
    if (_starting || _finishing || _takingPhoto || _switching) return;
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
    unawaited(_upload?.cancel());
    _upload = null;
    WidgetsBinding.instance.removeObserver(this);
    _limit.cancel();
    _ticker?.cancel();
    _clock.stop();
    if (!_starting && !_finishing && !_takingPhoto) _closeCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    final recording = camera?.value.isRecordingVideo == true;
    final busy =
        _opening || _starting || _finishing || _takingPhoto || _switching;
    final remaining = ((widget.maxDuration.inMilliseconds -
                _clock.elapsedMilliseconds +
                999) ~/
            1000)
        .clamp(0, (widget.maxDuration.inMilliseconds + 999) ~/ 1000);
    final remainingTime = '${(remaining ~/ 60).toString().padLeft(2, '0')}:'
        '${(remaining % 60).toString().padLeft(2, '0')}';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.unified ? 'צילום' : 'צילום וידאו')),
      body: SafeArea(
          child: Column(children: [
        Expanded(
            child: Center(
                child: _photoPreview != null
                    ? Image.memory(_photoPreview!, fit: BoxFit.contain)
                    : _error != null
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(_error!,
                                style: const TextStyle(color: Colors.white)))
                        : camera == null
                            ? const CircularProgressIndicator()
                            : CameraPreview(camera))),
        if (widget.unified && _photo == null)
          Wrap(spacing: 12, children: [
            if (widget.imagesAllowed)
              ChoiceChip(
                  label: const Text('תמונה'),
                  selected: !_video,
                  onSelected:
                      busy || recording || !_foreground || _pendingVideo != null
                          ? null
                          : (_) => _changeMode(false)),
            if (widget.videoAllowed)
              ChoiceChip(
                  label: const Text('וידאו'),
                  selected: _video,
                  onSelected:
                      busy || recording || !_foreground || _pendingVideo != null
                          ? null
                          : (_) => _changeMode(true)),
          ]),
        if (_video)
          Text('זמן שנותר: $remainingTime',
              style: const TextStyle(color: Colors.white),
              textDirection: TextDirection.rtl),
        if (!_video)
          Padding(
              padding: const EdgeInsets.all(20),
              child: Wrap(
                spacing: 16,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: _photo != null
                    ? [
                        TextButton(
                            onPressed: () {
                              setState(() {
                                _photo = null;
                                _photoPreview = null;
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
                            onPressed: busy || !_foreground
                                ? null
                                : camera == null
                                    ? _open
                                    : _takePhoto,
                            icon: const Icon(Icons.camera_alt),
                            label: Text(_takingPhoto
                                ? 'מצלם…'
                                : camera == null
                                    ? 'נסה שוב'
                                    : 'צלם'))
                      ],
              )),
        if (_video)
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
