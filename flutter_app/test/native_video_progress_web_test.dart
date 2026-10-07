@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:betshuva/native_video_player_web.dart';
import 'package:betshuva/chat_attachment_menu.dart';
import 'package:betshuva/media_pointer_barrier.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/progress_video_fixture.dart';

// Widget tests replace the engine channel; keep real DOM media elements while
// supplying the platform-view creation/disposal handshake.
class _ViewRegistry extends ui_web.PlatformViewRegistry {
  final factories = <String, Function>{};
  final views = <int, Object>{};
  @override
  bool registerViewFactory(String viewType, Function viewFactory, {bool isVisible = true}) {
    factories[viewType] = viewFactory;
    return true;
  }
  @override
  Object getViewById(int viewId) => views[viewId]!;
  Future<dynamic> handle(MethodCall call) async {
    if (call.method == 'create') {
      final args = call.arguments as Map;
      final id = args['id'] as int;
      final factory = factories[args['viewType']];
      views[id] = factory == null ? html.DivElement() : Function.apply(factory, [id]);
      html.document.body!.append(views[id]! as html.Element);
    } else if (call.method == 'dispose') {
      (views.remove(call.arguments) as html.Element?)?.remove();
    }
    return null;
  }
}

html.VideoElement _videoIn(WidgetTester tester) {
  final surface = tester.widget<PlatformViewSurface>(find.byType(PlatformViewSurface));
  final container = ui_web.platformViewRegistry.getViewById(surface.controller.viewId) as html.Element;
  return container.querySelector('video')! as html.VideoElement;
}

void main() {
  testWidgets('root attachment menu shields video inside a nested navigator until dismissed', (tester) async {
    final registry = _ViewRegistry();
    ui_web.debugOverridePlatformViewRegistry(registry);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, registry.handle);
    addTearDown(() {
      ui_web.debugOverridePlatformViewRegistry(null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    });
    final anchor = GlobalKey();
    ChatAttachmentAction? selected;
    await tester.pumpWidget(MaterialApp(home: Navigator(
      pages: [MaterialPage(child: Builder(builder: (context) => Scaffold(body: Column(children: [
        const NativeWebVideoPlayer(url: ''),
        IconButton(key: anchor, icon: const Icon(Icons.attach_file), onPressed: () async {
          selected = await showChatAttachmentMenu(context: context,
              anchorKey: anchor, imagesAllowed: true, videoAllowed: true,
              textAllowed: true, blockedLabel: 'blocked');
        }),
      ]))))], onDidRemovePage: (_) {},
    )));
    await tester.pumpAndSettle();
    final container = _videoIn(tester).parent!;
    expect(container.style.pointerEvents, 'auto');
    await tester.tap(find.byIcon(Icons.attach_file)); await tester.pumpAndSettle();
    expect(container.style.pointerEvents, 'none');
    expect(find.text('צילום והקלטה'), findsNothing);
    expect(find.text('הקלטת קול'), findsNothing);
    await tester.tap(find.text('צילום')); await tester.pumpAndSettle();
    expect(selected, ChatAttachmentAction.capture);
    expect(container.style.pointerEvents, 'auto');
    expect(mediaPointerBarriers.value, 0);
    await tester.tap(find.byIcon(Icons.attach_file)); await tester.pumpAndSettle();
    expect(container.style.pointerEvents, 'none');
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pump();
    expect(mediaPointerBarriers.value, 0);
  });

  testWidgets('real web video restores, seeks and saves per authenticated user', (tester) async {
    final registry = _ViewRegistry();
    ui_web.debugOverridePlatformViewRegistry(registry);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, registry.handle);
    addTearDown(() {
      ui_web.debugOverridePlatformViewRegistry(null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    });
    final url = html.Url.createObjectUrlFromBlob(html.Blob(
      [base64Decode(progressVideoBase64)], 'video/webm'));
    final saved = <String, Map<String, int>>{
      'Bearer alice': {'positionMs': 2000, 'version': 1},
      'Bearer bob': {'positionMs': 0, 'version': 0},
    };
    var step = 'initial restore';
    final client = MockClient((request) async {
      expect(request.url.path, '/api/video-progress');
      final current = saved[request.headers['authorization']]!;
      if (request.method == 'PUT') {
        final body = jsonDecode(request.body);
        expect(body['version'], current['version']);
        current['positionMs'] = body['positionMs'];
        current['version'] = current['version']! + 1;
      }
      return http.Response(jsonEncode(current), 200);
    });
    Future<void> settleUntil(bool Function() done) async {
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
        if (done()) return;
      }
      fail('Video did not reach the expected state');
    }
    Future<void> mount(String token) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: NativeWebVideoPlayer(
        url: url, token: token, progressApi: 'https://example.test/api'))));
      await settleUntil(() {
        final video = _videoIn(tester);
        final expected = saved['Bearer $token']!['positionMs']! / 1000;
        return video.readyState >= 2 && !video.seeking &&
            (video.currentTime - expected).abs() < .1;
      });
      expect(find.text('מעבר לזמן'), findsNothing);
    }
    await http.runWithClient(() async {
      try {
        await mount('alice');
        var video = _videoIn(tester);
        video.muted = true;
        expect(video.currentTime, closeTo(2, .1));
        expect(video.paused, isTrue);
        step = 'native seek';
        video.currentTime = 3;
        await settleUntil(() => saved['Bearer alice']!['positionMs'] == 3000);
        step = 'second native seek';
        video.currentTime = 4;
        await settleUntil(() => saved['Bearer alice']!['positionMs'] == 4000);
        expect(video.currentTime, closeTo(4, .1));

        // Use the browser's real playback controls/events, then save the pause.
        step = 'play';
        await tester.runAsync(() async {
          try { await video.play(); }
          catch (error) { debugPrint('Browser start interrupted while refreshing progress: $error'); }
        });
        await settleUntil(() => !video.paused && video.currentTime > 4.1);
        step = 'pause';
        video.pause();
        await settleUntil(() => saved['Bearer alice']!['positionMs']! > 4100);
        final stoppedAt = saved['Bearer alice']!['positionMs']!;
        step = 'remount';
        await tester.pumpWidget(const SizedBox.shrink()); await tester.pump();
        await mount('alice');
        video = _videoIn(tester);
        expect(video.currentTime * 1000, closeTo(stoppedAt, 100));
        expect(video.paused, isTrue);
        step = 'switch account';
        await mount('bob');
        expect(video.currentTime, closeTo(0, .1));
        expect(saved['Bearer alice']!['positionMs'], stoppedAt);
        await mount('alice');
        expect(video.currentTime * 1000, closeTo(stoppedAt, 100));
        video.dispatchEvent(html.Event('ended'));
        await settleUntil(() => saved['Bearer alice']!['positionMs'] == 0);
      } catch (error, stack) {
        // Browser console exceptions are otherwise collapsed by flutter test.
        debugPrint('Video progress regression at $step: $error; saved=$saved\n$stack');
        final video = _videoIn(tester);
        debugPrint('Video state: time=${video.currentTime}, paused=${video.paused}, duration=${video.duration}, ready=${video.readyState}, error=${video.error}');
        rethrow;
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
        html.Url.revokeObjectUrl(url);
      }
    }, () => client);
  });
}
