import 'dart:async';
import 'dart:convert';

import 'package:betshuva/compatible_video_player.dart';
import 'package:betshuva/main.dart' show ChatScreen;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart'
    as launcher;
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as platform;

const _channel = MethodChannel('com.betshuva.app/media');
final _videoUrl = Uri.parse('https://example.test/recording.mp4');
final _decoderError = PlatformException(
  code: 'VideoError',
  message:
      'Video player had error androidx.media3.exoplayer.ExoPlaybackException: '
      'MediaCodecVideoRenderer error, index=0, format_supported=YES',
);

class _NativePlayback {
  final calls = <MethodCall>[];
  final replies = <Future<bool> Function()>[];

  Future<bool> respond(MethodCall call) async {
    calls.add(call);
    expect(call.method, 'playVideo');
    if (replies.isEmpty) return false;
    return replies.removeAt(0)();
  }
}

class _Launcher extends launcher.UrlLauncherPlatform {
  String? url;
  launcher.LaunchOptions? options;

  @override
  Null get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, launcher.LaunchOptions options) async {
    this.url = url;
    this.options = options;
    return true;
  }
}

class _InlineVideoPlatform extends platform.VideoPlayerPlatform {
  _InlineVideoPlatform(this.error);
  final PlatformException error;
  final creations = <platform.VideoCreationOptions>[];
  final events = <int, StreamController<platform.VideoEvent>>{};
  final disposals = <int>[];

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(platform.VideoCreationOptions options) async {
    final id = creations.length;
    creations.add(options);
    events[id] = StreamController<platform.VideoEvent>(onCancel: () async {})
      ..addError(error);
    return id;
  }

  @override
  Stream<platform.VideoEvent> videoEventsFor(int playerId) =>
      events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    disposals.add(playerId);
  }

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
      int playerId, bool preventsDisplaySleepDuringVideoPlayback) async {}
}

void _installNative(_NativePlayback native) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_channel, native.respond);
  addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
}

void _installInlinePlatform(_InlineVideoPlatform fake) {
  final previous = platform.VideoPlayerPlatform.instance;
  platform.VideoPlayerPlatform.instance = fake;
  addTearDown(() {
    platform.VideoPlayerPlatform.instance = previous;
    for (final events in fake.events.values) {
      events.close();
    }
  });
}

Future<void> _mount(WidgetTester tester,
    {Uri? url, ValueNotifier<Uri>? currentUrl}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => currentUrl == null
                ? CompatibleVideoPlayer(url: url ?? _videoUrl)
                : ValueListenableBuilder<Uri>(
                    valueListenable: currentUrl,
                    builder: (_, value, __) =>
                        CompatibleVideoPlayer(url: value),
                  ),
          )),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  expect(tester.takeException(), isNull);
}

Future<http.Response> _chatResponse(http.Request request) async {
  const allowed = {
    'text': true,
    'video': true,
    'nonHumanImages': true,
    'men': true,
    'women': true,
    'children': true,
  };
  Object body = {};
  if (request.url.path.endsWith('/messages/friend')) {
    body = [
      {
        'id': 'recording-message',
        'sender_id': 'viewer',
        'type': 'video',
        'file_url': _videoUrl.toString(),
        'file_name': 'recording.mp4',
        'moderation_status': 'approved',
        'message_status': 'sent',
        'created_at': '2026-09-22T00:00:00Z',
      },
    ];
  } else if (request.url.path.endsWith('/filter-settings')) {
    body = {
      'filter': allowed,
      'personalFilter': allowed,
      'requiresChoice': false,
    };
  } else if (request.url.path.endsWith('/receiving-filter')) {
    body = {'filter': allowed};
  }
  return http.Response(jsonEncode(body), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});
}

Future<void> _mountChat(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(const MaterialApp(
    home: ChatScreen(
      token: 'test-token',
      me: {'id': 'viewer', 'name': 'viewer'},
      recipient: {'id': 'friend', 'name': 'friend'},
      socket: null,
      embedded: true,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('compatible playback is restricted to native Android decoder failures',
      () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(supportsCompatibleVideoPlayback(_decoderError), !kIsWeb);
    expect(
        supportsCompatibleVideoPlayback(PlatformException(
          code: 'VideoError',
          message: 'DecoderInitializationException: Decoder init failed: '
              'OMX.MTK.VIDEO.DECODER.AVC',
        )),
        !kIsWeb);
    for (final error in [
      null,
      StateError('MediaCodecVideoRenderer error'),
      PlatformException(code: 'CameraError', message: 'Decoder init failed'),
      PlatformException(code: 'VideoError', message: 'Source error: HTTP 404'),
      PlatformException(
          code: 'VideoError', message: 'java.net.SocketTimeoutException'),
    ]) {
      expect(supportsCompatibleVideoPlayback(error), isFalse);
    }
  });

  for (final target in [TargetPlatform.iOS, TargetPlatform.linux]) {
    test('compatible playback is not offered on $target', () {
      debugDefaultTargetPlatformOverride = target;
      expect(supportsCompatibleVideoPlayback(_decoderError), isFalse);
    });
  }

  testWidgets('native playback receives the URL once and closes on success',
      (tester) async {
    final closed = Completer<bool>();
    final native = _NativePlayback()..replies.add(() => closed.future);
    _installNative(native);
    await _mount(tester);
    expect(native.calls, hasLength(1));
    expect(native.calls.single.arguments, {'url': _videoUrl.toString()});
    expect(find.byType(CompatibleVideoPlayer), findsOneWidget);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.paused,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump();
    }
    expect(native.calls, hasLength(1));

    closed.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(CompatibleVideoPlayer), findsNothing);
    expect(find.text('open'), findsOneWidget);
    await _unmount(tester);
  });

  for (final failure in ['false', 'platform', 'missing-plugin']) {
    testWidgets('native $failure failure supports explicit retry',
        (tester) async {
      final native = _NativePlayback()
        ..replies.add(() async {
          if (failure == 'platform') {
            throw PlatformException(code: 'videoPlaybackFailed');
          }
          if (failure == 'missing-plugin') throw MissingPluginException();
          return false;
        })
        ..replies.add(() async => true);
      _installNative(native);
      await _mount(tester);
      await tester.pumpAndSettle();
      expect(native.calls, hasLength(1));
      expect(find.text('נסה שוב'), findsOneWidget);
      expect(find.text('הפעל בדפדפן'), findsOneWidget);
      await tester.tap(find.text('נסה שוב'));
      await tester.pumpAndSettle();
      expect(native.calls, hasLength(2));
      expect(find.byType(CompatibleVideoPlayer), findsNothing);
      expect(find.text('open'), findsOneWidget);
      await _unmount(tester);
    });
  }

  testWidgets('rapid retry taps launch only one native playback request',
      (tester) async {
    final closed = Completer<bool>();
    final native = _NativePlayback()
      ..replies.add(() async => false)
      ..replies.add(() => closed.future);
    _installNative(native);
    await _mount(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('נסה שוב'));
    await tester.tap(find.text('נסה שוב'));
    await tester.pump();
    expect(native.calls, hasLength(2));

    closed.complete(true);
    await tester.pumpAndSettle();
    expect(native.calls, hasLength(2));
    expect(find.byType(CompatibleVideoPlayer), findsNothing);
    expect(find.text('open'), findsOneWidget);
    await _unmount(tester);
  });

  for (final url in [
    'file:///tmp/recording.mp4',
    'content://media/videos/1',
    'https:recording.mp4',
  ]) {
    testWidgets('invalid native video URL is rejected: $url', (tester) async {
      final native = _NativePlayback();
      _installNative(native);
      await _mount(tester, url: Uri.parse(url));
      await tester.pumpAndSettle();
      expect(native.calls, isEmpty);
      expect(find.text('נסה שוב'), findsOneWidget);
      await _unmount(tester);
    });
  }

  testWidgets('playback failure can explicitly open the same URL externally',
      (tester) async {
    _installNative(_NativePlayback());
    final external = _Launcher();
    final previous = launcher.UrlLauncherPlatform.instance;
    launcher.UrlLauncherPlatform.instance = external;
    addTearDown(() => launcher.UrlLauncherPlatform.instance = previous);
    await _mount(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('הפעל בדפדפן'));
    await tester.pump();
    expect(external.url, _videoUrl.toString());
    expect(external.options?.mode,
        launcher.PreferredLaunchMode.externalApplication);
    await _unmount(tester);
  });

  testWidgets('late native completion cannot close an unrelated route',
      (tester) async {
    final closed = Completer<bool>();
    final native = _NativePlayback()..replies.add(() => closed.future);
    _installNative(native);
    await _mount(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('another-screen')),
    ));
    await tester.pumpAndSettle();
    closed.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('another-screen'), findsOneWidget);
    expect(native.calls, hasLength(1));
    await _unmount(tester);
  });

  testWidgets('native completion removes its covered route, not the top route',
      (tester) async {
    final closed = Completer<bool>();
    final native = _NativePlayback()..replies.add(() => closed.future);
    _installNative(native);
    await _mount(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('another-screen')),
    ));
    await tester.pumpAndSettle();
    closed.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('another-screen'), findsOneWidget);
    expect(
        find.byType(CompatibleVideoPlayer, skipOffstage: false), findsNothing);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    await _unmount(tester);
  });

  for (final oldResult in [true, false]) {
    testWidgets(
        'URL changes wait for native playback and ignore old $oldResult',
        (tester) async {
      final first = Completer<bool>();
      final latest = Completer<bool>();
      final native = _NativePlayback()
        ..replies.add(() => first.future)
        ..replies.add(() => latest.future);
      _installNative(native);
      final currentUrl = ValueNotifier(_videoUrl);
      addTearDown(currentUrl.dispose);
      await _mount(tester, currentUrl: currentUrl);
      currentUrl.value = Uri.parse('https://example.test/skipped.mp4');
      await tester.pump();
      currentUrl.value = Uri.parse('https://example.test/latest.mp4');
      await tester.pump();
      expect(native.calls, hasLength(1));

      first.complete(oldResult);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(native.calls, hasLength(2));
      expect(native.calls.last.arguments,
          {'url': 'https://example.test/latest.mp4'});
      expect(find.byType(CompatibleVideoPlayer), findsOneWidget);
      expect(find.text('נסה שוב'), findsNothing);
      latest.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(CompatibleVideoPlayer), findsNothing);
      expect(find.text('open'), findsOneWidget);
      await _unmount(tester);
    });
  }

  testWidgets('chat opens native playback only after tapping its video tile',
      (tester) async {
    final inline = _InlineVideoPlatform(_decoderError);
    _installInlinePlatform(inline);
    final closed = Completer<bool>();
    final native = _NativePlayback()..replies.add(() => closed.future);
    _installNative(native);
    await http.runWithClient(() async {
      await _mountChat(tester);
      expect(inline.creations, hasLength(1));
      expect(
          inline.creations.single.viewType, platform.VideoViewType.textureView);
      expect(native.calls, isEmpty);
      expect(find.text('הפעל וידאו'), findsOneWidget);

      await tester.tap(find.text('הפעל וידאו'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CompatibleVideoPlayer), findsOneWidget);
      expect(inline.creations, hasLength(1));
      expect(inline.disposals, [0]);
      expect(native.calls.single.arguments, {'url': _videoUrl.toString()});
      closed.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(CompatibleVideoPlayer), findsNothing);
      expect(find.text('הפעל וידאו'), findsOneWidget);
      await _unmount(tester);
    }, () => MockClient(_chatResponse));
  }, skip: kIsWeb);

  testWidgets('chat source errors keep retry and never open native playback',
      (tester) async {
    final inline = _InlineVideoPlatform(PlatformException(
        code: 'VideoError', message: 'Source error: HTTP 404'));
    _installInlinePlatform(inline);
    final native = _NativePlayback();
    _installNative(native);
    await http.runWithClient(() async {
      await _mountChat(tester);
      expect(inline.creations, hasLength(1));
      expect(
          inline.creations.single.viewType, platform.VideoViewType.textureView);
      expect(find.text('נסה שוב'), findsOneWidget);
      expect(find.text('הפעל וידאו'), findsNothing);
      expect(find.byType(CompatibleVideoPlayer), findsNothing);
      expect(native.calls, isEmpty);
      await _unmount(tester);
    }, () => MockClient(_chatResponse));
  }, skip: kIsWeb);
}
