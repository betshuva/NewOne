import 'dart:async';

import 'package:betshuva/native_video_capture.dart';
// ignore: depend_on_referenced_packages
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recording extends XFile {
  _Recording(super.path);
  String? savedPath;
  int saves = 0, saveFailures = 0;

  @override
  Future<void> saveTo(String path) async {
    saves++;
    if (saveFailures > 0) {
      saveFailures--;
      throw StateError('Temporary copy failure');
    }
    savedPath = path;
  }
}

class _Camera extends CameraPlatform {
  _Camera(this.recording);
  final _Recording recording;
  int starts = 0, stops = 0, creates = 0, disposals = 0;
  int stopFailures = 0, initializationFailures = 0;
  Completer<void>? pendingStart;
  Completer<XFile>? pendingStop;
  Completer<void>? pendingDisposal;
  @override
  Future<List<CameraDescription>> availableCameras() async => [
        const CameraDescription(
            name: 'back',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90),
      ];
  @override
  Future<int> createCameraWithSettings(CameraDescription cameraDescription,
          MediaSettings mediaSettings) async =>
      ++creates;
  @override
  Future<void> initializeCamera(int cameraId,
      {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {
    if (initializationFailures > 0) {
      initializationFailures--;
      throw PlatformException(code: 'cameraInitializationFailed');
    }
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(CameraInitializedEvent(
          cameraId, 640, 480, ExposureMode.auto, false, FocusMode.auto, false));
  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      Stream<CameraErrorEvent>.multi((_) {});
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();
  @override
  Widget buildPreview(int cameraId) => const SizedBox();
  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    starts++;
    await pendingStart?.future;
  }

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    stops++;
    if (stopFailures > 0) {
      stopFailures--;
      throw PlatformException(code: 'videoRecordingFailed');
    }
    if (pendingStop != null) return pendingStop!.future;
    return recording;
  }

  @override
  Future<void> dispose(int cameraId) async {
    disposals++;
    await pendingDisposal?.future;
  }
}

Future<void> _openCapture(WidgetTester tester,
    {void Function(XFile?)? onResult}) async {
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async {
                    final result = await captureNativeVideo(context,
                        maxDuration: const Duration(seconds: 30));
                    onResult?.call(result);
                  },
                  child: const Text('open'))))));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void _installCamera(_Camera camera) {
  final previous = CameraPlatform.instance;
  CameraPlatform.instance = camera;
  addTearDown(() => CameraPlatform.instance = previous);
}

void main() {
  for (final extension in ['mp4', 'mov', 'temp']) {
    for (final stopEarly in [false, true]) {
      testWidgets(
          'native camera $extension ${stopEarly ? 'manual stop' : '30 second stop'} returns one video',
          (tester) async {
        final previous = CameraPlatform.instance;
        final recording = _Recording('/tmp/capture.$extension');
        final camera = _Camera(recording);
        CameraPlatform.instance = camera;
        addTearDown(() => CameraPlatform.instance = previous);
        XFile? result;
        await tester.pumpWidget(MaterialApp(
            home: Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () async {
                          result = await captureNativeVideo(context,
                              maxDuration: const Duration(seconds: 30));
                        },
                        child: const Text('open'))))));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('התחל צילום'));
        await tester.pump();
        expect(camera.starts, 1);
        await tester.pump(const Duration(seconds: 29));
        expect(camera.stops, 0);
        if (stopEarly) {
          await tester.tap(find.text('עצור ושלח'));
          await tester.pump();
        } else {
          await tester.pump(const Duration(seconds: 1));
        }
        await tester.pumpAndSettle();
        expect(camera.stops, 1);
        if (extension == 'temp') {
          expect(recording.savedPath, '/tmp/capture.mp4');
          expect(result?.path, '/tmp/capture.mp4');
          expect(result?.name, 'capture.mp4');
          expect(result?.mimeType, 'video/mp4');
        } else {
          expect(recording.savedPath, isNull);
          expect(result, same(recording));
        }
        await tester.pump(const Duration(seconds: 40));
        expect(camera.stops, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('failed stop resets recording and retry opens a fresh camera',
      (tester) async {
    final recording = _Recording('/tmp/capture.mp4');
    final camera = _Camera(recording)..stopFailures = 1;
    _installCamera(camera);
    XFile? result;
    await _openCapture(tester, onResult: (file) => result = file);
    await tester.tap(find.text('התחל צילום'));
    await tester.pump();
    await tester.tap(find.text('עצור ושלח'));
    await tester.pumpAndSettle();

    expect(camera.stops, 1);
    expect(camera.disposals, 1);
    expect(result, isNull);
    expect(find.text('עצור ושלח'), findsNothing);
    expect(find.text('נסה שוב'), findsOneWidget);
    await tester.pump(const Duration(seconds: 40));
    expect(camera.stops, 1);

    await tester.tap(find.text('נסה שוב'));
    await tester.pumpAndSettle();
    expect(camera.creates, 2);
    expect(camera.starts, 1);
    expect(find.text('התחל צילום'), findsOneWidget);
    expect(find.text('לא ניתן לשמור את הסרטון. נסה שוב.'), findsNothing);

    await tester.tap(find.text('התחל צילום'));
    await tester.pump();
    await tester.tap(find.text('עצור ושלח'));
    await tester.pumpAndSettle();
    expect(camera.starts, 2);
    expect(camera.stops, 2);
    expect(result, same(recording));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed file copy retries the stopped recording without recapture',
      (tester) async {
    final recording = _Recording('/tmp/capture.temp')..saveFailures = 1;
    final camera = _Camera(recording);
    _installCamera(camera);
    XFile? result;
    await _openCapture(tester, onResult: (file) => result = file);
    await tester.tap(find.text('התחל צילום'));
    await tester.pump();
    await tester.tap(find.text('עצור ושלח'));
    await tester.pumpAndSettle();

    expect(camera.stops, 1);
    expect(recording.saves, 1);
    expect(result, isNull);
    expect(find.text('נסה שוב'), findsOneWidget);
    expect(find.text('עצור ושלח'), findsNothing);
    expect(find.text('התחל צילום'), findsNothing);
    await tester.pump(const Duration(seconds: 40));
    expect(camera.stops, 1);

    await tester.tap(find.text('נסה שוב'));
    await tester.pumpAndSettle();
    expect(recording.saves, 2);
    expect(recording.savedPath, '/tmp/capture.mp4');
    expect(result?.path, '/tmp/capture.mp4');
    expect(result?.mimeType, 'video/mp4');
    expect(camera.starts, 1);
    expect(camera.stops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lifecycle changes do not dispose or repeat a pending stop',
      (tester) async {
    final recording = _Recording('/tmp/capture.mp4');
    final stop = Completer<XFile>();
    final camera = _Camera(recording)..pendingStop = stop;
    _installCamera(camera);
    XFile? result;
    await _openCapture(tester, onResult: (file) => result = file);
    await tester.tap(find.text('התחל צילום'));
    await tester.pump();
    await tester.tap(find.text('עצור ושלח'));
    await tester.pump();

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    expect(camera.stops, 1);
    expect(camera.creates, 1);
    expect(camera.disposals, 0);
    expect(result, isNull);

    stop.complete(recording);
    await tester.pumpAndSettle();
    expect(result, same(recording));
    expect(camera.stops, 1);
    expect(camera.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('camera initialization failure can be retried without leaving',
      (tester) async {
    final camera = _Camera(_Recording('/tmp/capture.mp4'))
      ..initializationFailures = 1;
    _installCamera(camera);
    await _openCapture(tester);
    expect(camera.creates, 1);
    expect(camera.disposals, 1);
    expect(find.text('נסה שוב'), findsOneWidget);

    await tester.tap(find.text('נסה שוב'));
    await tester.pumpAndSettle();
    expect(camera.creates, 2);
    expect(camera.starts, 0);
    expect(find.text('התחל צילום'), findsOneWidget);
    expect(find.text('נסה שוב'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry is enabled after a background stop fails and app resumes',
      (tester) async {
    final camera = _Camera(_Recording('/tmp/capture.mp4'))..stopFailures = 1;
    _installCamera(camera);
    await _openCapture(tester);
    await tester.tap(find.text('התחל צילום'));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(camera.stops, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    await tester.tap(find.text('נסה שוב'));
    await tester.pumpAndSettle();
    expect(camera.creates, 2);
    expect(find.text('התחל צילום'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resuming waits for the old camera disposal before reopening',
      (tester) async {
    final disposal = Completer<void>();
    final camera = _Camera(_Recording('/tmp/capture.mp4'))
      ..pendingDisposal = disposal;
    _installCamera(camera);
    await _openCapture(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(camera.disposals, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(camera.creates, 1);

    disposal.complete();
    await tester.pumpAndSettle();
    expect(camera.creates, 2);
    expect(camera.disposals, 1);
    expect(find.text('התחל צילום'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing capture while stopping defers disposal until stop ends',
      (tester) async {
    final recording = _Recording('/tmp/capture.mp4');
    final stop = Completer<XFile>();
    final camera = _Camera(recording)..pendingStop = stop;
    _installCamera(camera);
    XFile? result;
    await _openCapture(tester, onResult: (file) => result = file);
    await tester.tap(find.text('התחל צילום'));
    await tester.pump();
    await tester.tap(find.text('עצור ושלח'));
    await tester.pump();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(camera.stops, 1);
    expect(camera.disposals, 0);
    expect(find.text('open'), findsOneWidget);

    stop.complete(recording);
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(camera.stops, 1);
    expect(camera.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing capture while starting defers disposal until start ends',
      (tester) async {
    final start = Completer<void>();
    final camera = _Camera(_Recording('/tmp/capture.mp4'))
      ..pendingStart = start;
    _installCamera(camera);
    await _openCapture(tester);
    await tester.tap(find.text('התחל צילום'));
    await tester.pump();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(camera.starts, 1);
    expect(camera.disposals, 0);
    expect(find.text('open'), findsOneWidget);

    start.complete();
    await tester.pumpAndSettle();
    expect(camera.starts, 1);
    expect(camera.disposals, 1);
    await tester.pump(const Duration(seconds: 40));
    expect(tester.takeException(), isNull);
  });
}
