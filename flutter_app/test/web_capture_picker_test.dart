@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:betshuva/web_capture_picker_web.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

class _CanvasCamera {
  _CanvasCamera(this.stream);

  final html.MediaStream stream;
  html.VideoElement? preview;
}

Future<_CanvasCamera> _installCanvasCamera(WidgetTester tester,
    {Future<html.MediaStream>? permissionResponse}) async {
  return (await tester.runAsync(() async {
    final canvas = html.CanvasElement(width: 640, height: 360);
    final stream = canvas.captureStream(15);
    final camera = _CanvasCamera(stream);
    var frame = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      canvas.context2D
        ..fillStyle = (frame++).isEven ? '#126ab3' : '#33aaff'
        ..fillRect(0, 0, 640, 360);
    });
    final devices = html.window.navigator.mediaDevices! as JSObject;
    final original = devices.getProperty<JSFunction>('getUserMedia'.toJS);
    final videoPrototype = js.JsObject.fromBrowserObject(
        (html.window as JSObject)
            .getProperty<JSFunction>('HTMLVideoElement'.toJS)
            .getProperty<JSObject>('prototype'.toJS));
    final originalPlay = videoPrototype['play'] as js.JsFunction;
    // Widget tests do not attach platform views; observe the real preview
    // without replacing browser playback, decoding, or recording.
    videoPrototype['play'] = js.JsFunction.withThis((Object element) {
      final video = element as html.VideoElement;
      if (identical(video.srcObject, stream)) camera.preview = video;
      return originalPlay.apply(const [], thisArg: element);
    });
    devices.setProperty(
        'getUserMedia'.toJS,
        ((JSAny? _) => (permissionResponse ?? Future.value(stream))
            .then((value) => value as JSObject)
            .toJS).toJS);
    addTearDown(() {
      timer.cancel();
      for (final track in stream.getTracks()) {
        track.stop();
      }
      devices.setProperty('getUserMedia'.toJS, original);
      videoPrototype['play'] = originalPlay;
    });
    return camera;
  }))!;
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

Future<_CanvasCamera> _openCamera(WidgetTester tester,
    {required bool video,
    required void Function(XFile?) onResult,
    Future<html.MediaStream>? permissionResponse,
    bool waitUntilReady = true}) async {
  final camera = await _installCanvasCamera(tester,
      permissionResponse: permissionResponse);
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
  await tester.pump(const Duration(milliseconds: 300));
  if (waitUntilReady) {
    await _waitUntil(
        tester,
        () =>
            find.byType(FilledButton).evaluate().isNotEmpty &&
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
                null);
  }
  return camera;
}

void _expectPlayingPreview(html.VideoElement preview) {
  expect(preview.videoWidth, greaterThan(0));
  expect(preview.videoHeight, greaterThan(0));
  expect(preview.readyState, greaterThanOrEqualTo(2));
  expect(preview.paused, isFalse);
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
      expect(find.text('התחל צילום'), findsNothing);
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

  testWidgets('cancelling pending camera permission stops the late stream',
      (tester) async {
    final permission = Completer<html.MediaStream>();
    final results = <XFile?>[];
    final browserErrors = <html.Event>[];
    final errorEvents = html.window.onError.listen(browserErrors.add);
    addTearDown(errorEvents.cancel);
    final camera = await _openCamera(tester,
        video: true,
        permissionResponse: permission.future,
        waitUntilReady: false,
        onResult: results.add);
    final stream = camera.stream;
    expect(stream.getTracks(), isNotEmpty);
    expect(stream.getTracks().every((track) => track.readyState == 'live'),
        isTrue);

    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(find.byType(AlertDialog), findsNothing);

    permission.complete(stream);
    await _waitUntil(tester,
        () => stream.getTracks().every((track) => track.readyState == 'ended'));
    expect(results, [null]);
    expect(find.text('open'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(browserErrors, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recording keeps the same playing preview and advances time',
      (tester) async {
    XFile? result;
    final camera = await _openCamera(tester,
        video: true, onResult: (file) => result = file);
    final preview = camera.preview!;
    expect(preview.srcObject, same(camera.stream));
    final previewBounds = tester.getSize(find.byType(HtmlElementView));
    expect(previewBounds.width, greaterThan(0));
    expect(previewBounds.height, greaterThan(0));
    _expectPlayingPreview(preview);
    final initialTime = preview.currentTime;
    final initialFrames = preview.getVideoPlaybackQuality().totalVideoFrames!;
    await _waitUntil(
        tester,
        () =>
            preview.currentTime > initialTime &&
            preview.getVideoPlaybackQuality().totalVideoFrames! >
                initialFrames);

    await tester.tap(find.text('התחל צילום'));
    await tester.pump();
    expect(find.textContaining('02:00'), findsOneWidget);
    expect(find.text('עצור ושמור'), findsOneWidget);
    final recordingTime = preview.currentTime;
    final recordingFrames = preview.getVideoPlaybackQuality().totalVideoFrames!;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2300)));
    await tester.pump(const Duration(milliseconds: 2300));

    expect(camera.preview, same(preview));
    expect(preview.srcObject, same(camera.stream));
    expect(tester.getSize(find.byType(HtmlElementView)), previewBounds);
    _expectPlayingPreview(preview);
    expect(preview.currentTime, greaterThan(recordingTime));
    expect(preview.getVideoPlaybackQuality().totalVideoFrames!,
        greaterThan(recordingFrames));
    expect(find.textContaining('02:00'), findsNothing);
    final countdown =
        tester.widget<Text>(find.textContaining('זמן שנותר')).data!;
    final seconds = RegExp(r'01:(\d{2})').firstMatch(countdown)!.group(1)!;
    expect(int.parse(seconds), inInclusiveRange(50, 59));
    expect(find.text('עצור ושמור'), findsOneWidget);

    await tester.tap(find.text('עצור ושמור'));
    await tester.pump();
    await _waitUntil(tester, () => result != null);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
