@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:betshuva/web_capture_picker_web.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

Future<void> _installCanvasCamera(WidgetTester tester) async {
  await tester.runAsync(() async {
    final canvas = html.CanvasElement(width: 640, height: 360);
    final stream = canvas.captureStream(15);
    var frame = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      canvas.context2D
        ..fillStyle = (frame++).isEven ? '#126ab3' : '#33aaff'
        ..fillRect(0, 0, 640, 360);
    });
    final devices = html.window.navigator.mediaDevices! as JSObject;
    final original = devices.getProperty<JSFunction>('getUserMedia'.toJS);
    devices.setProperty('getUserMedia'.toJS,
        ((JSAny? _) => Future<JSObject>.value(stream as JSObject).toJS).toJS);
    addTearDown(() {
      timer.cancel();
      for (final track in stream.getTracks()) {
        track.stop();
      }
      devices.setProperty('getUserMedia'.toJS, original);
    });
  });
}

Future<void> _waitUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    if (condition()) return;
  }
  fail('Camera operation did not complete');
}

Future<void> _openCamera(WidgetTester tester,
    {required bool video, required void Function(XFile?) onResult}) async {
  await _installCanvasCamera(tester);
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async => onResult(video
                      ? await captureWebVideo(context,
                          creatorId: 'browser-video')
                      : await captureWebPhoto(context,
                          creatorId: 'browser-photo')),
                  child: const Text('open'))))));
  await tester.tap(find.text('open'));
  await tester.pump();
  await _waitUntil(
      tester,
      () =>
          find.byType(FilledButton).evaluate().isNotEmpty &&
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
              null);
}

void main() {
  testWidgets('web photo uses snapshot time and creator ID in a genuine JPEG',
      (tester) async {
    XFile? result;
    await _openCamera(tester, video: false, onResult: (file) => result = file);
    await withClock(Clock.fixed(DateTime(2026, 9, 23, 14, 7, 36, 429)),
        () async {
      await tester.tap(find.text('צלם תמונה'));
      await tester.pump();
    });
    await _waitUntil(tester, () => result != null);
    expect(result!.name,
        'betshuva-photo-2026-09-23_14-07-36-42-ID-browser-photo.jpg');
    expect(result!.mimeType, 'image/jpeg');
    final bytes = await tester.runAsync(() => result!.readAsBytes());
    expect(bytes!.take(2), [0xff, 0xd8]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('web video retains start time in a genuine WebM recording',
      (tester) async {
    XFile? result;
    await _openCamera(tester, video: true, onResult: (file) => result = file);
    await withClock(Clock.fixed(DateTime(2026, 9, 23, 14, 7, 36, 429)),
        () async {
      await tester.tap(find.text('התחל צילום'));
      await tester.pump();
    });
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)));
    await withClock(Clock.fixed(DateTime(2026, 9, 23, 14, 8, 20, 999)),
        () async {
      await tester.tap(find.text('עצור ושמור'));
      await tester.pump();
    });
    await _waitUntil(tester, () => result != null);
    expect(result!.name,
        'betshuva-video-2026-09-23_14-07-36-42-ID-browser-video.webm');
    expect(result!.mimeType, 'video/webm');
    final bytes = await tester.runAsync(() => result!.readAsBytes());
    expect(bytes!.take(4), [0x1a, 0x45, 0xdf, 0xa3]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
