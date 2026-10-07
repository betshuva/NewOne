import 'dart:convert';

import 'package:betshuva/listing_capture.dart';
// ignore: depend_on_referenced_packages
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/photo_camera.dart';

class _VideoFile extends XFile {
  _VideoFile() : super('/tmp/listing-capture.temp');
  String? savedPath;
  @override
  Future<void> saveTo(String path) async => savedPath = path;
}

class _ListingCamera extends PhotoCamera {
  _ListingCamera()
      : super(XFile.fromData(
            base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1sAAAAASUVORK5CYII='),
            path: '/tmp/listing-photo.png',
            mimeType: 'image/png'));
  final recording = _VideoFile();
  int starts = 0, stops = 0;
  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async =>
      starts++;
  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    stops++;
    return recording;
  }
}

Future<void> _openPhotos(WidgetTester tester, int maxPhotos,
    void Function(List<XFile>) onResult) async {
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async => onResult(await captureListingPhotos(
                      context,
                      maxPhotos: maxPhotos,
                      creatorId: 'tester')),
                  child: const Text('open'))))));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _confirmPhoto(WidgetTester tester) async {
  await tester.tap(find.text('צלם'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('השתמש בתמונה'));
  await tester.pumpAndSettle();
}

void main() {
  late CameraPlatform previous;
  late _ListingCamera camera;
  setUp(() {
    previous = CameraPlatform.instance;
    CameraPlatform.instance = camera = _ListingCamera();
  });
  tearDown(() => CameraPlatform.instance = previous);

  for (final requestedLimit in [2, 99]) {
    final limit = requestedLimit == 99 ? 8 : requestedLimit;
    testWidgets('photo capture respects remaining slots and hard cap $limit',
        (tester) async {
      List<XFile>? result;
      await _openPhotos(tester, requestedLimit, (photos) => result = photos);
      for (var i = 1; i <= limit; i++) {
        await _confirmPhoto(tester);
        if (i < limit) {
          expect(result, isNull);
          expect(find.text('צולמו $i מתוך $limit תמונות'), findsOneWidget);
          await tester.tap(find.text('צילום נוסף'));
          await tester.pumpAndSettle();
        }
      }
      expect(result, hasLength(limit));
      expect(camera.captures, limit);
      expect(camera.disposals, limit);
      expect(find.text('צילום נוסף'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('finishing a photo sequence retains its confirmed draft',
      (tester) async {
    List<XFile>? result;
    await _openPhotos(tester, 8, (photos) => result = photos);
    await _confirmPhoto(tester);
    await tester.tap(find.text('סיום'));
    await tester.pumpAndSettle();
    expect(result, [camera.photo]);
    expect(camera.captures, 1);
    expect(camera.disposals, 1);
  });

  testWidgets('cancelling another capture preserves earlier photos',
      (tester) async {
    List<XFile>? result;
    await _openPhotos(tester, 8, (photos) => result = photos);
    await _confirmPhoto(tester);
    await tester.tap(find.text('צילום נוסף'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(result, [camera.photo]);
    expect(camera.captures, 1);
    expect(camera.creates, 2);
    expect(camera.disposals, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no remaining slots opens no camera', (tester) async {
    List<XFile>? result;
    await _openPhotos(tester, 0, (photos) => result = photos);
    expect(result, isEmpty);
    expect(camera.creates, 0);
  });

  testWidgets('listing video leaves a half-second margin before ten seconds',
      (tester) async {
    XFile? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async => result =
                        await captureListingVideo(context, creatorId: 'tester'),
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('זמן שנותר: 00:10'), findsOneWidget);
    await tester.tap(find.text('התחל צילום'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(camera.stops, 0);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(camera.starts, 1);
    expect(camera.stops, 1);
    expect(result?.mimeType, 'video/mp4');
    expect(camera.recording.savedPath, endsWith('-ID-tester.mp4'));
    expect(camera.disposals, 1);
    expect(tester.takeException(), isNull);
  });
}
