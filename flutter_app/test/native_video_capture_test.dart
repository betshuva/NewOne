import 'package:betshuva/native_video_capture.dart';
// ignore: depend_on_referenced_packages
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recording extends XFile {
  _Recording(super.path);
  String? savedPath;

  @override
  Future<void> saveTo(String path) async {
    savedPath = path;
  }
}

class _Camera extends CameraPlatform {
  _Camera(this.recording);
  final _Recording recording;
  int starts = 0, stops = 0;
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
      1;
  @override
  Future<void> initializeCamera(int cameraId,
      {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {}
  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(const CameraInitializedEvent(
          1, 640, 480, ExposureMode.auto, false, FocusMode.auto, false));
  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();
  @override
  Widget buildPreview(int cameraId) => const SizedBox();
  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    starts++;
  }

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    stops++;
    return recording;
  }

  @override
  Future<void> dispose(int cameraId) async {}
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
}
