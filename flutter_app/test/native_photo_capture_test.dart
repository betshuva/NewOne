import 'dart:async';
import 'package:betshuva/native_photo_capture.dart';
// ignore: depend_on_referenced_packages
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers/photo_camera.dart';
import 'own_media_filter_test.dart' show TestImageFile;

void main() {
  late PhotoCamera camera;
  late CameraPlatform previous;
  setUp(() {
    previous = CameraPlatform.instance;
    camera = PhotoCamera(TestImageFile());
    CameraPlatform.instance = camera;
  });
  tearDown(() => CameraPlatform.instance = previous);
  Future<void> open(WidgetTester tester, void Function(XFile?) result) async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async =>
                    result(await captureNativePhoto(context)),
                child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'photo is returned only after confirmation; retake and cancel work',
      (tester) async {
    XFile? result;
    await open(tester, (file) => result = file);
    await tester.tap(find.text('צלם'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(camera.disposals, 1);
    await tester.tap(find.text('צלם שוב'));
    await tester.pumpAndSettle();
    expect(camera.creates, 2);
    await tester.tap(find.text('צלם'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('השתמש בתמונה'));
    await tester.pumpAndSettle();
    expect(result, same(camera.photo));
    expect(camera.captures, 2);
    result = null;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
  testWidgets(
      'capture failure can retry and backgrounding releases idle camera',
      (tester) async {
    camera.captureFailures = 1;
    await open(tester, (_) {});
    await tester.tap(find.text('צלם'));
    await tester.pumpAndSettle();
    expect(find.text('לא ניתן לצלם. נסה שוב.'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(camera.disposals, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.tap(find.text('צלם'));
    await tester.pumpAndSettle();
    expect(find.text('השתמש בתמונה'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('leaving during capture waits for the camera before disposal',
      (tester) async {
    camera.pendingCapture = Completer<XFile>();
    await open(tester, (_) {});
    await tester.tap(find.text('צלם'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(camera.disposals, 0);
    camera.pendingCapture!.complete(camera.photo);
    await tester.pumpAndSettle();
    expect(camera.disposals, 1);
    expect(tester.takeException(), isNull);
  });
}
