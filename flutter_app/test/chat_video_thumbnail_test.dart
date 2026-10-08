@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show SemanticsAction, Tristate;

import 'package:betshuva/compatible_video_player.dart';
import 'package:betshuva/filter_history.dart';
import 'package:betshuva/main.dart' show ChatScreen, GroupChatScreen;
import 'package:betshuva/video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:video_player/video_player.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as platform;

const _channel = MethodChannel('com.betshuva.app/media');
const _allowed = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true,
};
const _group = {
  'id': 'group',
  'name': 'Group',
  'status': 'member',
  'role': 'member',
  'send_permission': 'all',
};
final _jpeg = base64Decode(
    '/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzU4LjQyLjEwMAD/2wBDAAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABMAAEBAAAAAAAAAAAAAAAAAAAABgEBAQAAAAAAAAAAAAAAAAAABgcQAQAAAAAAAAAAAAAAAAAAAAARAQAAAAAAAAAAAAAAAAAAAAD/wAARCAACAAIDASIAAhEAAxEA/9oADAMBAAIRAxEAPwCLAFF/f//Z');
int _nextUrl = 0;
String _url() => 'https://example.test/chat-thumbnail-${_nextUrl++}.mp4';

class _NoMediaCachePath extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      throw UnsupportedError('Disk cache is disabled for this widget test');
}

class _DecoderFailurePlatform extends platform.VideoPlayerPlatform {
  _DecoderFailurePlatform(
      {this.decoderFails = true, this.delayInitialization = false});
  final bool decoderFails;
  final bool delayInitialization;
  final creations = <platform.VideoCreationOptions>[];
  final events = <int, StreamController<platform.VideoEvent>>{};
  final disposals = <int>[];
  final playbacks = <int>[];
  Completer<void>? disposalGate;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(platform.VideoCreationOptions options) async {
    final id = creations.length;
    creations.add(options);
    events[id] = StreamController<platform.VideoEvent>(onCancel: () async {});
    if (!delayInitialization) completeInitialization(id);
    return id;
  }

  void completeInitialization(int id) {
    if (decoderFails) {
      events[id]!.addError(PlatformException(
        code: 'VideoError',
        message: 'MediaCodecVideoRenderer error, format_supported=YES',
      ));
    } else {
      events[id]!.add(platform.VideoEvent(
        eventType: platform.VideoEventType.initialized,
        duration: const Duration(seconds: 10),
        size: const Size(160, 90),
      ));
    }
  }

  @override
  Stream<platform.VideoEvent> videoEventsFor(int playerId) =>
      events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    disposals.add(playerId);
    await disposalGate?.future;
  }

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
      int playerId, bool preventsDisplaySleepDuringVideoPlayback) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> play(int playerId) async => playbacks.add(playerId);

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildView(int playerId) => const SizedBox.expand();
}

class _NativeMedia {
  final thumbnails = <String>[];
  final playbacks = <String>[];
  final playbackClosed = Completer<bool>();
  Completer<Uint8List>? thumbnailResult;

  Future<Object?> respond(MethodCall call) async {
    final url = (call.arguments as Map)['url'] as String;
    switch (call.method) {
      case 'videoThumbnail':
        thumbnails.add(url);
        return thumbnailResult == null ? _jpeg : thumbnailResult!.future;
      case 'playVideo':
        playbacks.add(url);
        return playbackClosed.future;
      default:
        throw StateError('Unexpected media method: ${call.method}');
    }
  }
}

(_DecoderFailurePlatform, _NativeMedia) _installMedia({
  bool decoderFails = true,
  bool delayInitialization = false,
}) {
  final inline = _DecoderFailurePlatform(
      decoderFails: decoderFails, delayInitialization: delayInitialization);
  final previous = platform.VideoPlayerPlatform.instance;
  platform.VideoPlayerPlatform.instance = inline;
  final native = _NativeMedia();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_channel, native.respond);
  addTearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    platform.VideoPlayerPlatform.instance = previous;
    for (final events in inline.events.values) {
      events.close();
    }
  });
  return (inline, native);
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

bool _isHistory(http.Request request, bool group) =>
    request.method == 'GET' &&
    request.url.path
        .endsWith(group ? '/groups/group/messages' : '/messages/friend');

http.Response _defaultResponse(http.Request request) {
  final path = request.url.path;
  if (path.endsWith('/groups')) return _json([_group]);
  if (path.endsWith('/groups/group')) {
    return _json({
      'members': [
        {'id': 'viewer', 'name': 'Viewer', 'role': 'member'},
      ],
    });
  }
  if (path.endsWith('/filter-settings')) {
    return _json({
      'filter': _allowed,
      'personalFilter': _allowed,
      'requiresChoice': false,
    });
  }
  if (path.endsWith('/receiving-filter')) {
    return _json({'filter': _allowed});
  }
  return _json({});
}

Map<String, dynamic> _message(String url,
        {String state = 'approved', bool own = true}) =>
    {
      'id': 'video-message',
      'sender_id': own ? 'viewer' : 'friend',
      'sender_name': own ? 'Viewer' : 'Friend',
      'type': 'video',
      'file_url': url,
      'file_name': 'recording.mp4',
      'file_deleted': state == 'deleted',
      'filter_hidden': state == 'filter_hidden',
      'hidden_reason': state == 'filter_hidden' ? 'content_filter' : null,
      'moderation_status': state == 'pending_scan'
          ? 'pending'
          : state == 'rejected_scan'
              ? 'rejected'
              : 'approved',
      'message_status':
          const {'approved', 'filter_hidden', 'deleted'}.contains(state)
              ? 'sent'
              : state,
      'created_at': '2026-09-24T10:00:00Z',
    };

Widget _chat(bool group, {io.Socket? socket}) => MaterialApp(
      home: group
          ? GroupChatScreen(
              token: 'test-token',
              me: {'id': 'viewer', 'name': 'Viewer'},
              group: {..._group},
              socket: socket,
              embedded: true,
            )
          : ChatScreen(
              token: 'test-token',
              me: {'id': 'viewer', 'name': 'Viewer'},
              recipient: {'id': 'friend', 'name': 'Friend'},
              socket: socket,
              embedded: true,
            ),
    );

Future<void> _mount(WidgetTester tester, bool group,
    {io.Socket? socket}) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_chat(group, socket: socket));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  expect(tester.takeException(), isNull);
}

void _expectNoMedia(_DecoderFailurePlatform inline, _NativeMedia native) {
  expect(find.byType(VideoThumbnail), findsNothing);
  expect(inline.creations, isEmpty);
  expect(native.thumbnails, isEmpty);
  expect(native.playbacks, isEmpty);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _NoMediaCachePath();
    addTearDown(() => PathProviderPlatform.instance = previous);
  });

  for (final group in [false, true]) {
    final scope = group ? 'group' : 'private';

    testWidgets('$scope first play initializes once and starts inline playback',
        (tester) async {
      final (inline, native) =
          _installMedia(decoderFails: false, delayInitialization: true);
      final url = _url();
      await http.runWithClient(() async {
        await _mount(tester, group);
        await tester.pumpAndSettle();
        expect(find.byType(VideoThumbnail), findsOneWidget);
        expect(native.thumbnails, [url]);
        expect(inline.creations, isEmpty);
        expect(inline.playbacks, isEmpty);
        await tester.tap(find.byTooltip('הפעל וידאו'));
        await tester.pump();
        expect(inline.creations, hasLength(1));
        expect(inline.playbacks, isEmpty);
        expect(find.byType(VideoThumbnail), findsOneWidget);
        await tester.tap(find.byTooltip('הפעל וידאו'));
        await tester.pump();
        expect(inline.creations, hasLength(1));
        inline.completeInitialization(0);
        await tester.pump();
        await tester.pump();
        expect(inline.playbacks, [0]);
        expect(find.byType(VideoPlayer), findsOneWidget);
        expect(native.playbacks, isEmpty);
        await tester.tap(find.byType(VideoPlayer));
        await tester.pump();
        await _unmount(tester);
        expect(inline.disposals, [0]);
      },
          () => MockClient((request) async => _isHistory(request, group)
              ? _json([_message(url)])
              : _defaultResponse(request)));
    });

    testWidgets('$scope JPEG preview waits for whole-tile play before decoding',
        (tester) async {
      final semantics = tester.ensureSemantics();
      final (inline, native) = _installMedia();
      final sourceUrl = group
          ? _url()
          : '/betshuva-app/uploads/chat-thumbnail-${_nextUrl++}.mp4';
      final url = group ? sourceUrl : 'https://betshuva.com$sourceUrl';
      try {
        await http.runWithClient(() async {
          await _mount(tester, group);
          await tester.pumpAndSettle();
          final thumbnail = find.byType(VideoThumbnail);
          expect(thumbnail, findsOneWidget);
          expect(tester.getSize(thumbnail), const Size(280, 150));
          expect(tester.widget<VideoThumbnail>(thumbnail).url, url);
          expect(native.thumbnails, [url]);
          expect(native.playbacks, isEmpty);
          expect(inline.creations, isEmpty);
          final image =
              find.descendant(of: thumbnail, matching: find.byType(Image));
          final provider = tester.widget<Image>(image).image as MemoryImage;
          expect(provider.bytes, _jpeg);
          await tester.runAsync(
              () => precacheImage(provider, tester.element(thumbnail)));
          await tester.pump();
          final pixels = tester.widget<RawImage>(
              find.descendant(of: thumbnail, matching: find.byType(RawImage)));
          expect(pixels.image?.width, 2);
          expect(pixels.image?.height, 2);
          expect(find.byTooltip('הפעל וידאו'), findsOneWidget);
          expect(find.text('הפעל וידאו'), findsNothing);
          final playButton = find.bySemanticsLabel(RegExp(r'^הפעל וידאו$'));
          expect(playButton, findsOneWidget,
              reason: tester
                  .getSemantics(find.byTooltip('הפעל וידאו'))
                  .getSemanticsData()
                  .toString());
          final available = tester.getSemantics(playButton).getSemanticsData();
          expect(available.label, 'הפעל וידאו');
          expect(available.flagsCollection.isButton, isTrue);
          expect(available.flagsCollection.isEnabled, Tristate.isTrue);
          expect(available.hasAction(SemanticsAction.tap), isTrue);
          expect(find.bySemanticsLabel('נגן סרטון'), findsNothing);

          inline.disposalGate = Completer<void>();
          await tester
              .tapAt(tester.getTopLeft(thumbnail) + const Offset(20, 20));
          await tester.pump();
          expect(inline.creations, hasLength(1));
          expect(inline.creations.single.dataSource.uri, url);
          final opening = tester.getSemantics(playButton).getSemanticsData();
          expect(opening.flagsCollection.isButton, isTrue);
          expect(opening.flagsCollection.isEnabled, Tristate.isFalse);
          expect(opening.hasAction(SemanticsAction.tap), isFalse);
          expect(native.playbacks, isEmpty);
          inline.disposalGate!.complete();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(native.playbacks, [url]);
          expect(inline.disposals, [0]);
          expect(find.byType(CompatibleVideoPlayer), findsOneWidget);
          native.playbackClosed.complete(true);
          await tester.pumpAndSettle();
          expect(find.byType(CompatibleVideoPlayer), findsNothing);
          expect(thumbnail, findsOneWidget);
          expect(native.thumbnails, [url]);
          await _unmount(tester);
        },
            () => MockClient((request) async => _isHistory(request, group)
                ? _json([_message(sourceUrl)])
                : _defaultResponse(request)));
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('$scope filter change cancels a pending compatible opening',
        (tester) async {
      final (inline, native) = _installMedia();
      final url = _url();
      var hidden = false;
      inline.disposalGate = Completer<void>();
      await http.runWithClient(() async {
        await _mount(tester, group);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('הפעל וידאו'));
        await tester.pump();
        expect(inline.creations, hasLength(1));
        expect(native.playbacks, isEmpty);
        hidden = true;
        receivingFilterChanges.add('test-token');
        await tester.pump();
        expect(find.byType(VideoThumbnail), findsNothing);
        inline.disposalGate!.complete();
        await tester.pumpAndSettle();
        expect(find.byType(FilterHiddenImage), findsOneWidget);
        expect(find.byType(CompatibleVideoPlayer), findsNothing);
        expect(native.playbacks, isEmpty);
        expect(inline.disposals, [0]);
        await _unmount(tester);
      },
          () => MockClient((request) async => _isHistory(request, group)
              ? _json(
                  [_message(url, state: hidden ? 'filter_hidden' : 'approved')])
              : _defaultResponse(request)));
    });

    for (final state in [
      'pending_scan',
      'rejected_scan',
      'filter_hidden',
      'deleted',
      // Group history preserves these states; private history normalizes them.
      if (group) ...['blocked_content', 'failed', 'uploading'],
    ]) {
      for (final own in [true, false]) {
        testWidgets(
            '$scope ${own ? 'own' : 'received'} $state never loads video',
            (tester) async {
          final (inline, native) = _installMedia();
          final url = _url();
          await http.runWithClient(() async {
            await _mount(tester, group);
            _expectNoMedia(inline, native);
            await tester.pump(const Duration(seconds: 1));
            _expectNoMedia(inline, native);
            await _unmount(tester);
          },
              () => MockClient((request) async => _isHistory(request, group)
                  ? _json([_message(url, state: state, own: own)])
                  : _defaultResponse(request)));
        });
      }
    }

    for (final cachedType in ['video', 'text', null]) {
      testWidgets(
          '$scope cached video with ${cachedType ?? 'missing'} type waits for fresh visibility',
          (tester) async {
        final (inline, native) = _installMedia();
        final url = _url();
        SharedPreferences.setMockInitialValues({
          group ? 'cache_group_msgs_viewer_group' : 'cache_msgs_viewer_friend':
              jsonEncode([
            {
              'id': 'video-message',
              'from': 'viewer',
              'senderId': 'viewer',
              'isMe': true,
              'isFile': true,
              if (cachedType != null) 'fileType': cachedType,
              'fileUrl': url,
              'fileName': 'recording.mp4',
              'text': '',
              'status': 'sent',
            },
          ]),
        });
        final freshHistory = Completer<void>();
        await http.runWithClient(() async {
          await _mount(tester, group);
          _expectNoMedia(inline, native);
          freshHistory.complete();
          await tester.pumpAndSettle();
          _expectNoMedia(inline, native);
          expect(find.byType(FilterHiddenImage), findsOneWidget);
          await _unmount(tester);
        },
            () => MockClient((request) async {
                  if (_isHistory(request, group)) {
                    await freshHistory.future;
                    return _json([_message(url, state: 'filter_hidden')]);
                  }
                  return _defaultResponse(request);
                }));
      });
    }

    for (final lateFrame in [false, true]) {
      testWidgets(
          '$scope filter change hides ${lateFrame ? 'pending' : 'loaded'} thumbnail before reload',
          (tester) async {
        final (inline, native) = _installMedia();
        if (lateFrame) native.thumbnailResult = Completer<Uint8List>();
        final url = _url();
        var changed = false;
        final freshHistory = Completer<void>();
        await http.runWithClient(() async {
          await _mount(tester, group);
          await tester.pumpAndSettle();
          expect(find.byType(VideoThumbnail), findsOneWidget);
          expect(native.thumbnails, [url]);
          changed = true;
          receivingFilterChanges.add('test-token');
          await tester.pump();
          expect(find.byType(VideoThumbnail), findsNothing);
          await tester.pump();
          expect(inline.disposals, isEmpty);
          if (lateFrame) {
            native.thumbnailResult!.complete(_jpeg);
            await tester.pump();
            expect(find.byType(VideoThumbnail), findsNothing);
          }
          freshHistory.complete();
          await tester.pumpAndSettle();
          expect(find.byType(FilterHiddenImage), findsOneWidget);
          expect(find.byType(VideoThumbnail), findsNothing);
          expect(inline.creations, isEmpty);
          expect(native.thumbnails, [url]);
          expect(native.playbacks, isEmpty);
          await _unmount(tester);
        },
            () => MockClient((request) async {
                  if (_isHistory(request, group)) {
                    if (changed) await freshHistory.future;
                    return _json([
                      _message(url,
                          state: changed ? 'filter_hidden' : 'approved'),
                    ]);
                  }
                  return _defaultResponse(request);
                }));
      });
    }
  }

  for (final replaceUrl in [false, true]) {
    testWidgets(
        'late decoder fallback after ${replaceUrl ? 'URL change' : 'disposal'} never opens stale media',
        (tester) async {
      final (inline, native) = _installMedia();
      final oldUrl = _url();
      final newUrl = _url();
      late List<Widget> players;
      await http.runWithClient(() async {
        await _mount(tester, true);
        await tester.pumpAndSettle();
        players = tester
            .widgetList<Widget>(find.byWidgetPredicate((widget) =>
                widget.runtimeType.toString() == '_ChatVideoPlayer'))
            .toList();
        expect(players, hasLength(2));
        await _unmount(tester);
      },
          () => MockClient((request) async => _isHistory(request, true)
              ? _json([
                  {..._message(oldUrl), 'id': 'old-video'},
                  {..._message(newUrl), 'id': 'new-video'},
                ])
              : _defaultResponse(request)));
      final previousPlayer =
          players.singleWhere((widget) => (widget as dynamic).url == oldUrl);
      final nextPlayer =
          players.singleWhere((widget) => (widget as dynamic).url == newUrl);
      await tester.pumpWidget(MaterialApp(home: Center(child: previousPlayer)));
      await tester.pumpAndSettle();
      inline.disposalGate = Completer<void>();
      await tester.tap(find.byTooltip('הפעל וידאו'));
      await tester.pump();
      expect(inline.creations, hasLength(1));
      expect(native.playbacks, isEmpty);
      if (replaceUrl) {
        await tester.pumpWidget(MaterialApp(home: Center(child: nextPlayer)));
        await tester.pump();
        expect(tester.widget<VideoThumbnail>(find.byType(VideoThumbnail)).url,
            newUrl);
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      inline.disposalGate!.complete();
      await tester.pumpAndSettle();
      expect(inline.creations, hasLength(1));
      expect(native.playbacks, isEmpty);
      expect(find.byType(CompatibleVideoPlayer), findsNothing);
      await _unmount(tester);
    });
  }

  testWidgets('incoming group video waits for policy-projected history',
      (tester) async {
    final (inline, native) = _installMedia();
    final url = _url();
    final socket = io.io('http://localhost:1',
        io.OptionBuilder().disableAutoConnect().enableForceNew().build());
    addTearDown(() {
      socket.connected = false;
      socket.dispose();
    });
    var incoming = false;
    var historyRequests = 0;
    final freshHistory = Completer<void>();
    await http.runWithClient(() async {
      await _mount(tester, true, socket: socket);
      _expectNoMedia(inline, native);
      final initialRequests = historyRequests;
      incoming = true;
      socket.connected = true;
      socket.onevent({
        'data': [
          'group:message',
          {
            'id': 'video-message',
            'groupId': 'group',
            'fromUserId': 'friend',
            'fromName': 'Friend',
            'fileType': 'video',
            'fileUrl': url,
            'fileName': 'recording.mp4',
            'createdAt': '2026-09-24T10:00:00Z',
          },
        ],
      });
      socket.connected = false;
      await tester.pump(const Duration(milliseconds: 100));
      expect(historyRequests, greaterThan(initialRequests));
      _expectNoMedia(inline, native);
      freshHistory.complete();
      await tester.pumpAndSettle();
      _expectNoMedia(inline, native);
      expect(find.byType(FilterHiddenImage), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (_isHistory(request, true)) {
                historyRequests++;
                if (!incoming) return _json([]);
                await freshHistory.future;
                return _json(
                    [_message(url, state: 'filter_hidden', own: false)]);
              }
              return _defaultResponse(request);
            }));
  });
}
