import 'dart:async';
// ignore: depend_on_referenced_packages
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PhotoCamera extends CameraPlatform {
  PhotoCamera(this.photo);
  final XFile photo;
  int captures = 0, creates = 0, disposals = 0;
  int captureFailures = 0;
  Completer<XFile>? pendingCapture;
  @override
  Future<List<CameraDescription>> availableCameras() async => [
        const CameraDescription(
            name: 'back',
            lensDirection: CameraLensDirection.back,
            sensorOrientation: 90),
      ];
  @override
  Future<int> createCameraWithSettings(
          CameraDescription description, MediaSettings settings) async =>
      ++creates;
  @override
  Future<void> initializeCamera(int cameraId,
      {ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown}) async {}
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
  Future<XFile> takePicture(int cameraId) async {
    captures++;
    if (captureFailures-- > 0) throw PlatformException(code: 'captureFailed');
    if (pendingCapture != null) return await pendingCapture!.future;
    return photo;
  }

  @override
  Future<void> dispose(int cameraId) async {
    disposals++;
  }
}
