@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_web/video_player_web.dart';
import 'own_media_filter_test.dart' as fixtures;

Future<void> _waitUntil(WidgetTester tester, bool Function() done,
    {String stage = 'camera ready'}) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
    if (done()) return;
  }
  fail('$stage did not finish: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).toList()}');
}

void main() {
  for (final group in [false, true]) {
    for (final video in [false, true]) {
      testWidgets('${group ? 'group' : 'private'} direct camera uploads ${video ? 'video' : 'photo'}',
          (tester) async {
        final previousErrorHandler = FlutterError.onError;
        FlutterError.onError = (details) {
          // Surface browser framework failures in the test runner output.
          // ignore: avoid_print
          print('${details.exceptionAsString()}\n${details.stack}');
          previousErrorHandler?.call(details);
        };
        addTearDown(() => FlutterError.onError = previousErrorHandler);
        fixtures.size(tester);
        final previousVideoPlayer = VideoPlayerPlatform.instance;
        VideoPlayerPlatform.instance = VideoPlayerPlugin();
        addTearDown(() => VideoPlayerPlatform.instance = previousVideoPlayer);
        SharedPreferences.setMockInitialValues({});
        final streams = <html.MediaStream>[];
        final devices = html.window.navigator.mediaDevices! as JSObject;
        final original = devices.getProperty<JSFunction>('getUserMedia'.toJS);
        Timer? frames;
        await tester.runAsync(() async {
          final canvas = html.CanvasElement(width: 640, height: 360);
          var frame = 0;
          frames = Timer.periodic(const Duration(milliseconds: 60), (_) {
            canvas.context2D
              ..fillStyle = (frame++).isEven ? '#126ab3' : '#33aaff'
              ..fillRect(0, 0, 640, 360);
          });
          devices.setProperty('getUserMedia'.toJS, ((JSAny? _) {
            final stream = canvas.captureStream(15);
            streams.add(stream);
            return Future.value(stream as JSObject).toJS;
          }).toJS);
        });
        addTearDown(() {
          frames?.cancel();
          for (final stream in streams) {
            for (final track in stream.getTracks()) {
              track.stop();
            }
          }
          devices.setProperty('getUserMedia'.toJS, original);
        });
        // Browser uploads use XMLHttpRequest and resumable upload sessions,
        // separate from the http client used for the chat API.
        js.context.callMethod('eval', [r'''
          (() => {
            const proto = XMLHttpRequest.prototype;
            const original = {open: proto.open, send: proto.send, header: proto.setRequestHeader};
            const sessions = new Map(), uploads = [];
            proto.open = function(method, url, ...args) {
              if (url.includes('/api/upload')) this.cameraTest = {method, url, headers: {}};
              else return original.open.call(this, method, url, ...args);
            };
            proto.setRequestHeader = function(name, value) {
              if (this.cameraTest) this.cameraTest.headers[name] = value;
              else original.header.call(this, name, value);
            };
            proto.send = function(data) {
              if (!this.cameraTest) return original.send.call(this, data);
              const {method, url, headers} = this.cameraTest;
              let status = 200, body = {};
              if (method === 'GET') status = 404;
              else if (method === 'POST' && url.endsWith('/upload-sessions')) {
                const meta = JSON.parse(data); sessions.set(meta.id, meta);
                body = {offset: 0, chunkBytes: 1024 * 1024};
              } else if (method === 'PUT') {
                body = {offset: Number(headers['Upload-Offset']) + data.size};
              } else if (method === 'POST' && url.endsWith('/upload')) {
                const meta = sessions.get(JSON.parse(data).uploadSessionId);
                uploads.push(meta);
                body = {status: 'pending', fileName: meta.name, url: 'https://example.test/capture'};
              } else throw new Error('Unexpected upload request');
              Object.defineProperty(this, 'status', {configurable: true, value: status});
              Object.defineProperty(this, 'responseText', {configurable: true, value: JSON.stringify(body)});
              queueMicrotask(() => this.dispatchEvent(new ProgressEvent('load')));
            };
            window.cameraUploadTest = {
              json: () => JSON.stringify(uploads),
              restore: () => {proto.open = original.open; proto.send = original.send;
                proto.setRequestHeader = original.header; delete window.cameraUploadTest;}
            };
          })();
        ''']);
        final uploadServer = js.context['cameraUploadTest'] as js.JsObject;
        List<dynamic> uploads() => jsonDecode(uploadServer.callMethod('json') as String) as List<dynamic>;
        addTearDown(() => uploadServer.callMethod('restore'));
        await http.runWithClient(() async {
          await tester.pumpWidget(fixtures.chat(group));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          expect(find.text('צילום והקלטה'), findsNothing);
          expect(find.text('הקלטת קול'), findsNothing);
          await tester.tap(find.text('צילום'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await _waitUntil(tester, () => find.byType(FilledButton).evaluate().isNotEmpty &&
              tester.widget<FilledButton>(find.byType(FilledButton)).onPressed != null);
          expect(find.byKey(const ValueKey('chat-attachment-menu')), findsNothing);
          expect(find.byKey(const ValueKey('camera-fullscreen')), findsOneWidget);
          if (video) {
            await tester.tap(find.byKey(const ValueKey('camera-mode-video')));
            await _waitUntil(tester, () => tester.widget<FilledButton>(find.byType(FilledButton)).onPressed != null);
            await tester.tap(find.text('התחל צילום'));
            await tester.pump();
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 450)));
            await tester.tap(find.text('עצור ושמור'));
          } else {
            await tester.tap(find.text('צלם תמונה'));
          }
          await tester.pump();
          await _waitUntil(tester, () => uploads().isNotEmpty, stage: 'upload');
          expect(uploads(), hasLength(1));
          final uploaded = uploads().single as Map;
          expect(uploaded['fields']['captureKind'], video ? 'camera_video' : 'camera_image');
          expect(uploaded['mime'], video ? 'video/webm' : 'image/jpeg');
          expect(uploaded['size'], greaterThan(0));
          expect(uploaded['fields'][group ? 'groupId' : 'toUserId'], group ? 'group' : 'friend');
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }, () => MockClient((request) async {
          if (fixtures.isHistory(request, group)) return fixtures.json([]);
          return fixtures.defaultResponse(request);
        }));
      });
    }
  }
}
