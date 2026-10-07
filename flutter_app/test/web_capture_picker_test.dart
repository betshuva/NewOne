@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:betshuva/recording_upload.dart';
import 'package:betshuva/listing_capture.dart';
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
  _CanvasCamera(this.stream) : streams = [stream];

  final html.MediaStream stream;
  final List<html.MediaStream> streams;
  final List<bool> audioRequests = [];
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
      if (camera.streams.contains(video.srcObject)) camera.preview = video;
      return originalPlay.apply(const [], thisArg: element);
    });
    devices.setProperty(
        'getUserMedia'.toJS,
        ((JSAny? constraints) {
          camera.audioRequests.add((constraints as JSObject)
              .getProperty<JSBoolean>('audio'.toJS)
              .toDart);
          final next = camera.audioRequests.length == 1
              ? stream
              : canvas.captureStream(15);
          if (!camera.streams.contains(next)) camera.streams.add(next);
          return (permissionResponse ?? Future.value(next))
              .then((value) => value as JSObject)
              .toJS;
        }).toJS);
    addTearDown(() {
      timer.cancel();
      for (final opened in camera.streams) {
        for (final track in opened.getTracks()) {
          track.stop();
        }
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
    bool unified = false,
    bool imagesAllowed = true,
    bool videoAllowed = true,
    bool waitUntilReady = true}) async {
  final camera = await _installCanvasCamera(tester,
      permissionResponse: permissionResponse);
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async => onResult(unified
                      ? await captureWebCamera(context,
                          creatorId: 'browser-camera',
                          imagesAllowed: imagesAllowed,
                          videoAllowed: videoAllowed)
                      : video
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
  testWidgets(
      'listing photo sequence keeps drafts when next capture is cancelled',
      (tester) async {
    final camera = await _installCanvasCamera(tester);
    List<XFile>? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await captureListingPhotos(context,
                          maxPhotos: 2, creatorId: 'tester');
                    },
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await _waitUntil(
        tester,
        () =>
            find.byType(FilledButton).evaluate().isNotEmpty &&
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
                null);
    await tester.tap(find.text('צלם תמונה'));
    await _waitUntil(
        tester, () => find.text('צולמו 1 מתוך 2 תמונות').evaluate().isNotEmpty);
    expect(
        camera.stream.getTracks().every((track) => track.readyState == 'ended'),
        isTrue);
    await tester.tap(find.text('צילום נוסף'));
    await _waitUntil(
        tester,
        () =>
            camera.streams.length == 2 &&
            find.text('ביטול').evaluate().isNotEmpty);
    await tester.tap(find.text('ביטול'));
    await _waitUntil(tester, () => result != null);
    expect(result, hasLength(1));
    expect(
        camera.streams.every((stream) =>
            stream.getTracks().every((track) => track.readyState == 'ended')),
        isTrue);
    await tester.runAsync(
        () async => expect(await result!.single.readAsBytes(), isNotEmpty));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'listing video deadline leaves an encoder margin and releases camera',
      (tester) async {
    final previousErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      // Surface browser framework failures in the headless test runner.
      // ignore: avoid_print
      print('${details.exceptionAsString()}\n${details.stack}');
      previousErrorHandler?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousErrorHandler);
    final camera = await _installCanvasCamera(tester);
    XFile? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await captureListingVideo(context,
                          creatorId: 'tester');
                    },
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await _waitUntil(
        tester,
        () =>
            find.byType(FilledButton).evaluate().isNotEmpty &&
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
                null);
    await tester.tap(find.text('התחל צילום'));
    await tester.pump();
    expect(find.textContaining('00:10'), findsOneWidget);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pump(const Duration(seconds: 9));
    expect(result, isNull);
    expect(find.text('עצור ושמור'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await _waitUntil(tester, () => result != null);
    // The returned file precedes the dialog exit animation and track cleanup.
    await tester.pumpAndSettle();
    expect(result?.mimeType, 'video/webm');
    expect(result?.name, contains('-ID-tester'));
    expect(
        camera.stream.getTracks().every((track) => track.readyState == 'ended'),
        isTrue);
    await tester
        .runAsync(() async => expect(await result!.readAsBytes(), isNotEmpty));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'real timed camera blobs upload during recording and decode after sealing',
      (tester) async {
    final remote = <int>[];
    var sends = 0;
    final client = MockClient((request) async {
      if (request.method == 'PUT') {
        expect(int.parse(request.headers['Upload-Offset']!), remote.length);
        remote.addAll(request.bodyBytes);
        return http.Response(jsonEncode({'offset': remote.length}), 200);
      }
      if (request.url.path.endsWith('/seal')) {
        expect(jsonDecode(request.body)['sha256'],
            sha256.convert(remote).toString());
      }
      if (request.url.path == '/api/upload') sends++;
      return http.Response('{}', 200);
    });
    await _installCanvasCamera(tester);
    XFile? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await http.runWithClient(
                          () => captureWebVideo(context,
                              creatorId: 'synthetic-camera',
                              api: 'https://example.test/api',
                              token: 'fixture'),
                          () => client);
                    },
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await _waitUntil(
        tester,
        () =>
            find.text('התחל צילום').evaluate().isNotEmpty &&
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
                null);
    await http.runWithClient(() async {
      await tester.tap(find.text('התחל צילום'));
      await tester.pump();
    }, () => client);
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(seconds: 6)));
    await tester.pump(const Duration(seconds: 2));
    await _waitUntil(tester, () => remote.isNotEmpty);
    expect(sends, 0);
    await tester.tap(find.text('עצור ושמור'));
    await tester.pump();
    await _waitUntil(tester, () => result != null);
    expect(sends, 0);
    await tester.runAsync(() async {
      final response = await RecordingUpload.upload(
          file: result!,
          token: 'fixture',
          name: result!.name,
          fields: {'toUserId': 'self'});
      expect(response?.statusCode, 200);
      expect(remote, await result!.readAsBytes());
      final player = html.VideoElement()..muted = true;
      final loaded =
          player.onLoadedData.first.timeout(const Duration(seconds: 10));
      player.src = result!.path;
      await loaded;
      await player.play();
      expect(player.videoWidth, greaterThan(0));
      player.pause();
      player.removeAttribute('src');
      player.load();
    });
    expect(sends, 1);
    await tester.pumpAndSettle();
  });

  testWidgets(
      'fullscreen camera switches photo and video and records the chosen type',
      (tester) async {
    XFile? result;
    final camera = await _openCamera(tester,
        video: false, unified: true, onResult: (file) => result = file);
    final size =
        tester.getSize(find.byKey(const ValueKey('camera-fullscreen')));
    expect(size, tester.view.physicalSize / tester.view.devicePixelRatio);
    expect(find.text('צילום'), findsOneWidget);
    expect(find.text('הקלטת קול'), findsNothing);
    expect(camera.audioRequests, [false]);
    expect(tester.getSize(find.byType(HtmlElementView)).height,
        greaterThan(size.height * .65));
    await tester.tap(find.byKey(const ValueKey('camera-mode-video')));
    await _waitUntil(
        tester,
        () =>
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
            null);
    expect(camera.audioRequests, [false, true]);
    expect(
        camera.stream.getTracks().every((track) => track.readyState == 'ended'),
        isTrue);
    await tester.tap(find.text('התחל צילום'));
    await tester.pump();
    expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('camera-mode-photo')))
            .onSelected,
        isNull);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)));
    await tester.tap(find.text('עצור ושמור'));
    await tester.pump();
    await _waitUntil(tester, () => result != null);
    expect(result!.mimeType, 'video/webm');
    expect(result!.name, startsWith('betshuva-video-'));
    await tester.pumpAndSettle();
    expect(
        camera.streams.every((stream) =>
            stream.getTracks().every((track) => track.readyState == 'ended')),
        isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'fullscreen camera can switch back to a genuine photo without audio',
      (tester) async {
    XFile? result;
    final camera = await _openCamera(tester,
        video: false, unified: true, onResult: (file) => result = file);
    for (final mode in ['video', 'photo']) {
      await tester.tap(find.byKey(ValueKey('camera-mode-$mode')));
      await _waitUntil(
          tester,
          () =>
              tester
                  .widget<FilledButton>(find.byType(FilledButton))
                  .onPressed !=
              null);
    }
    expect(camera.audioRequests, [false, true, false]);
    await tester.tap(find.text('צלם תמונה'));
    await tester.pump();
    await _waitUntil(tester, () => result != null);
    expect(result!.mimeType, 'image/jpeg');
    final bytes = await tester.runAsync(() => result!.readAsBytes());
    expect(bytes!.take(2), [0xff, 0xd8]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final imagesAllowed in [true, false]) {
    testWidgets(
        'fullscreen camera honors allowed mode (images: $imagesAllowed)',
        (tester) async {
      final camera = await _openCamera(tester,
          video: false,
          unified: true,
          imagesAllowed: imagesAllowed,
          videoAllowed: !imagesAllowed,
          onResult: (_) {});
      final disabled = imagesAllowed ? 'video' : 'photo';
      expect(
          tester
              .widget<ChoiceChip>(find.byKey(ValueKey('camera-mode-$disabled')))
              .onSelected,
          isNull);
      expect(camera.audioRequests, [!imagesAllowed]);
      await tester.tap(find.text('ביטול'));
      await tester.pumpAndSettle();
      expect(
          camera.stream
              .getTracks()
              .every((track) => track.readyState == 'ended'),
          isTrue);
      expect(tester.takeException(), isNull);
    });
  }

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
