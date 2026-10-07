import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:betshuva/message_hover.dart';
import 'package:betshuva/message_reactions.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/reaction_test_artifact_stub.dart'
    if (dart.library.io) 'helpers/reaction_test_artifact_io.dart';

const _api = 'https://example.test/api';
const _token = 'account-token';
const _id = 'reaction-message';

class _ReactionAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == 'assets/stickers/user-catalog.json') {
      return rootBundle.load(key);
    }
    return ByteData.sublistView(Uint8List.fromList(utf8
        .encode('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36">'
            '<circle cx="18" cy="18" r="16" fill="#ffcc4d"/>'
            '<circle cx="13" cy="14" r="2" fill="#222"/>'
            '<circle cx="23" cy="14" r="2" fill="#222"/></svg>')));
  }
}

Map<String, dynamic> _item(String emoji, {int count = 1, bool mine = false}) =>
    {'emoji': emoji, 'count': count, 'mine': mine};

http.Response _response(List<Map<String, dynamic>> items,
        {http.Request? request}) =>
    http.Response(
        jsonEncode(request?.url.path.endsWith('/reactions/details') == true
            ? {'reactions': items, 'users': <dynamic>[]}
            : items),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});

Widget _reactions(http.Client client, MessageReactionsCache cache,
        {String api = _api, String token = _token, String messageId = _id}) =>
    MessageReactions(
      key: ValueKey('$api/$token/$messageId'),
      api: api,
      token: token,
      messageId: messageId,
      client: client,
      cache: cache,
      compact: true,
      showAddButton: false,
    );

Widget _view(http.Client client, MessageReactionsCache cache,
        {Widget? body, String token = _token, String messageId = _id}) =>
    DefaultAssetBundle(
      bundle: _ReactionAssets(),
      child: MaterialApp(
        home: Scaffold(
          body: body ??
              _reactions(client, cache, token: token, messageId: messageId),
        ),
      ),
    );

Finder _button(String emoji) => find.byKey(ValueKey('compact-reaction-$emoji'));
Finder _choice(String emoji) => find.byKey(ValueKey('change-reaction-$emoji'));
Finder get _details => find.byKey(const ValueKey('reaction-details-dialog'));
Finder get _addOwn => find.byKey(const ValueKey('reaction-details-add-own'));

Future<void> _openChooser(WidgetTester tester, String emoji) async {
  await tester.tap(_button(emoji));
  await tester.pumpAndSettle();
  expect(_details, findsOneWidget);
  expect(_choice('❤️'), findsNothing);
  await tester.tap(_addOwn);
  await tester.pumpAndSettle();
}

Future<void> _closeDetails(WidgetTester tester) async {
  expect(_details, findsOneWidget);
  Navigator.of(tester.element(_details)).pop();
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester, http.Client client,
    MessageReactionsCache cache) async {
  await tester.pumpWidget(const SizedBox());
  client.close();
  cache.dispose();
}

void main() {
  for (final id in [1, 150]) {
    testWidgets('custom reaction $id stays 20px and overlaps the media corner',
        (tester) async {
      final emoji = '[[bt-emoji:${id.toString().padLeft(3, '0')}]]';
      final cache = MessageReactionsCache();
      final client = MockClient(
          (request) async => _response([_item(emoji)], request: request));
      await tester.pumpWidget(_view(client, cache,
          body: Align(
            alignment: Alignment.topRight,
            child: MessageHover(
              reactionsOnChild: true,
              sideReactions: _reactions(client, cache),
              child: const MessageObjectReactions(
                  child: SizedBox(
                      key: ValueKey('custom-media'), width: 220, height: 100)),
            ),
          )));
      await tester.pumpAndSettle();
      final media = tester.getRect(find.byKey(const ValueKey('custom-media')));
      final hit = tester.getRect(_button(emoji));
      final glyph = tester.getRect(find.descendant(
          of: _button(emoji),
          matching: find.byKey(ValueKey('inline-custom-emoji-$id'))));
      expect(hit.right, closeTo(media.right, .001));
      expect(hit.size, const Size(32, 32));
      expect(glyph.width, closeTo(20, .001));
      expect(glyph.height, closeTo(20, .001));
      expect(glyph.top, closeTo(media.bottom - 8, .001));
      expect(find.byType(ActionChip), findsNothing);
      expect(find.textContaining('[[bt-emoji:'), findsNothing);
      final button = tester.widget<TextButton>(_button(emoji));
      expect(button.style!.backgroundColor!.resolve({}), Colors.transparent);
      expect(tester.takeException(), isNull);
      await _dispose(tester, client, cache);
    });
  }

  testWidgets('compact glyphs are 20px, transparent and count only two or more',
      (tester) async {
    final cache = MessageReactionsCache();
    final client = MockClient((_) async => _response([
          _item('👍', mine: true),
          _item('❤️', count: 2),
          _item('😂', count: 12),
        ]));
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    expect(find.byType(ActionChip), findsNothing);
    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    for (final emoji in ['👍', '❤️', '😂']) {
      final button = tester.widget<TextButton>(_button(emoji));
      for (final states in <Set<WidgetState>>[
        {},
        {WidgetState.hovered},
        {WidgetState.pressed},
        {WidgetState.selected},
        {WidgetState.selected, WidgetState.hovered},
      ]) {
        expect(
            button.style!.backgroundColor!.resolve(states), Colors.transparent);
        expect(button.style!.overlayColor!.resolve(states), Colors.transparent);
      }
      final glyph = find.descendant(
          of: _button(emoji), matching: find.byType(SvgPicture));
      expect(tester.getSize(glyph), const Size(20, 20));
      expect(tester.getSize(_button(emoji)).height, 32);
      expect(tester.getSize(_button(emoji)).width, greaterThanOrEqualTo(32));
    }
    expect(tester.takeException(), isNull);
    await _dispose(tester, client, cache);
  });

  testWidgets(
      'tap opens details before chooser; same choice and dismissal preserve mine',
      (tester) async {
    final writes = <dynamic>[];
    final cache = MessageReactionsCache();
    final client = MockClient((request) async {
      if (request.method == 'PUT')
        writes.add(jsonDecode(request.body)['emoji']);
      return _response([_item('👍', mine: true)], request: request);
    });
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    await _openChooser(tester, '👍');
    expect(_choice('❤️'), findsOneWidget);
    expect(find.byKey(const ValueKey('remove-own-reaction')), findsOneWidget);
    expect(writes, isEmpty);
    await tester.tap(_choice('👍'));
    await tester.pumpAndSettle();
    await _closeDetails(tester);
    expect(writes, isEmpty);
    expect(_button('👍'), findsOneWidget);
    await _openChooser(tester, '👍');
    Navigator.of(tester.element(_choice('❤️'))).pop();
    await tester.pumpAndSettle();
    await _closeDetails(tester);
    expect(writes, isEmpty);
    expect(_button('👍'), findsOneWidget);
    await _dispose(tester, client, cache);
  });

  testWidgets(
      'choosing another emoji replaces once; explicit removal sends null',
      (tester) async {
    final writes = <dynamic>[];
    final cache = MessageReactionsCache();
    var items = [_item('👍', mine: true)];
    final client = MockClient((request) async {
      if (request.method == 'PUT') {
        final emoji = jsonDecode(request.body)['emoji'];
        writes.add(emoji);
        items = emoji == null ? [] : [_item(emoji as String, mine: true)];
      }
      return _response(items, request: request);
    });
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    await _openChooser(tester, '👍');
    await tester.tap(_choice('❤️'));
    await tester.pumpAndSettle();
    await _closeDetails(tester);
    expect(writes, ['❤️']);
    expect(_button('👍'), findsNothing);
    expect(_button('❤️'), findsOneWidget);
    await _openChooser(tester, '❤️');
    await tester.tap(find.byKey(const ValueKey('remove-own-reaction')));
    await tester.pumpAndSettle();
    await _closeDetails(tester);
    expect(writes, ['❤️', null]);
    expect(find.byType(TextButton), findsNothing);
    await _dispose(tester, client, cache);
  });

  testWidgets('others reaction opens add choices without a remove-mine action',
      (tester) async {
    final writes = <dynamic>[];
    final cache = MessageReactionsCache();
    final client = MockClient((request) async {
      if (request.method == 'PUT') {
        final emoji = jsonDecode(request.body)['emoji'];
        writes.add(emoji);
        return _response([_item(emoji as String, mine: true)]);
      }
      return _response([_item('❤️', count: 2)], request: request);
    });
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    await _openChooser(tester, '❤️');
    expect(find.byKey(const ValueKey('remove-own-reaction')), findsNothing);
    await tester.tap(_choice('👍'));
    await tester.pumpAndSettle();
    await _closeDetails(tester);
    expect(writes, ['👍']);
    await _dispose(tester, client, cache);
  });

  testWidgets('socket change while chooser is open preserves the chosen emoji',
      (tester) async {
    final cache = MessageReactionsCache();
    var ownEmoji = '👍';
    final writes = <dynamic>[];
    final client = MockClient((request) async {
      if (request.method == 'PUT') {
        final selected = jsonDecode(request.body)['emoji'];
        writes.add(selected);
        ownEmoji = selected as String;
      }
      return _response([_item(ownEmoji, mine: true)], request: request);
    });
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    await _openChooser(tester, '👍');
    ownEmoji = '❤️';
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'new-heart');
    await tester.pumpAndSettle();
    await tester.tap(_choice('❤️'));
    await tester.pumpAndSettle();
    await _closeDetails(tester);
    expect(writes, isEmpty);
    expect(_button('❤️'), findsOneWidget);

    await _openChooser(tester, '❤️');
    ownEmoji = '👍';
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'new-thumb');
    await tester.pumpAndSettle();
    await tester.tap(_choice('❤️'));
    await tester.pumpAndSettle();
    await _closeDetails(tester);
    expect(writes, ['❤️']);
    expect(_button('❤️'), findsOneWidget);
    expect(_button('👍'), findsNothing);
    await _dispose(tester, client, cache);
  });

  testWidgets(
      'choice during a dirty pending refresh sets emoji and never toggles',
      (tester) async {
    final cache = MessageReactionsCache();
    final pendingRefresh = Completer<http.Response>();
    var refreshPending = false;
    final writes = <dynamic>[];
    final client = MockClient((request) async {
      if (request.method == 'GET' &&
          !request.url.path.endsWith('/reactions/details') &&
          refreshPending) return pendingRefresh.future;
      if (request.method == 'PUT')
        writes.add(jsonDecode(request.body)['emoji']);
      return _response([_item('❤️', mine: true)], request: request);
    });
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    await _openChooser(tester, '❤️');
    refreshPending = true;
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'unknown-new-own');
    await tester.pump();
    await tester.tap(_choice('❤️'));
    await tester.pumpAndSettle();
    expect(writes, ['❤️']);
    pendingRefresh.complete(_response([_item('👍', mine: true)]));
    await tester.pumpAndSettle();
    await _closeDetails(tester);
    expect(_button('❤️'), findsOneWidget);
    expect(_button('👍'), findsNothing);
    await _dispose(tester, client, cache);
  });

  for (final direction in [TextDirection.rtl, TextDirection.ltr]) {
    testWidgets(
        'real glyph corner and lower hit area work without hover in $direction',
        (tester) async {
      final cache = MessageReactionsCache();
      var mediaTaps = 0;
      var count = 1;
      final writes = <String>[];
      final client = MockClient((request) async {
        if (request.method != 'GET') writes.add(request.method);
        return _response([_item('👍', count: count)], request: request);
      });
      await tester.pumpWidget(_view(client, cache,
          body: Directionality(
              textDirection: direction,
              child: Align(
                  alignment: Alignment.topRight,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    MessageHover(
                      key: const ValueKey('media-hover'),
                      actions: const SizedBox(width: 30, height: 30),
                      sideReactions: _reactions(client, cache),
                      reactionsOnChild: true,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        MessageObjectReactions(
                          child: GestureDetector(
                            onTap: () => mediaTaps++,
                            child: Container(
                                key: const ValueKey('media'),
                                width: 220,
                                height: 150,
                                color: Colors.blue),
                          ),
                        ),
                        const SizedBox(
                            key: ValueKey('caption'),
                            width: 220,
                            height: 40,
                            child: Text('שם קובץ')),
                      ]),
                    ),
                    const SizedBox(
                        key: ValueKey('next'), width: 220, height: 60),
                  ])))));
      await tester.pumpAndSettle();
      final media = tester.getRect(find.byKey(const ValueKey('media')));
      final next = tester.getRect(find.byKey(const ValueKey('next')));
      final hit = tester.getRect(_button('👍'));
      final glyph = tester.getRect(find.descendant(
          of: _button('👍'), matching: find.byType(SvgPicture)));
      expect(hit.right, closeTo(media.right, 0.001));
      expect(hit.size, const Size(32, 32));
      expect(glyph.top, closeTo(media.bottom - 8, 0.001));
      expect(hit.bottom, closeTo(media.bottom + 18, 0.001));
      expect(tester.getRect(find.byKey(const ValueKey('caption'))).top,
          closeTo(hit.bottom, 0.001));
      count = 2;
      cache.invalidate(
          api: _api, token: _token, messageId: _id, eventId: 'count-two');
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      expect(tester.getRect(find.byKey(const ValueKey('media'))), media);
      expect(tester.getRect(find.byKey(const ValueKey('next'))), next);
      expect(tester.getRect(_button('👍')).right, closeTo(media.right, 0.001));
      await tester.tapAt(Offset(hit.center.dx, media.bottom + 15));
      await tester.pumpAndSettle();
      expect(_details, findsOneWidget);
      expect(_choice('👍'), findsNothing);
      expect(mediaTaps, 0);
      expect(writes, isEmpty);
      await tester.tap(_addOwn);
      await tester.pumpAndSettle();
      expect(_choice('👍'), findsOneWidget);
      expect(mediaTaps, 0);
      expect(writes, isEmpty);
      expect(tester.getRect(find.byKey(const ValueKey('media'))), media);
      expect(tester.getRect(find.byKey(const ValueKey('next'))), next);
      Navigator.of(tester.element(_choice('👍'))).pop();
      await tester.pumpAndSettle();
      await _closeDetails(tester);
      expect(tester.takeException(), isNull);
      await _dispose(tester, client, cache);
    });
  }

  testWidgets('six narrow reactions wrap below the media and stay tappable',
      (tester) async {
    final cache = MessageReactionsCache();
    final client = MockClient((request) async => _response([
          for (final emoji in messageReactionEmoji) _item(emoji),
        ], request: request));
    await tester.pumpWidget(_view(client, cache,
        body: Align(
            alignment: Alignment.topRight,
            child: MessageHover(
              key: const ValueKey('narrow'),
              reactionsOnChild: true,
              sideReactions: _reactions(client, cache),
              child: const MessageObjectReactions(
                  child:
                      SizedBox(key: ValueKey('media'), width: 70, height: 100)),
            ))));
    await tester.pumpAndSettle();
    final media = tester.getRect(find.byKey(const ValueKey('media')));
    final bounds = tester.getRect(find.byKey(const ValueKey('narrow')));
    final first = tester.getRect(_button('👍'));
    final third = tester.getRect(_button('😂'));
    expect(bounds.width, media.width);
    expect(first.top, closeTo(media.bottom - 14, 0.001));
    expect(third.top, greaterThan(media.bottom));
    for (final emoji in messageReactionEmoji) {
      final rect = tester.getRect(_button(emoji));
      final glyph = find.descendant(
          of: _button(emoji), matching: find.byType(SvgPicture));
      expect(tester.getSize(glyph), const Size(20, 20));
      expect(rect.left, greaterThanOrEqualTo(bounds.left));
      expect(rect.right, lessThanOrEqualTo(bounds.right));
      expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
    }
    await tester.tapAt(tester.getRect(_button('😢')).center);
    await tester.pumpAndSettle();
    expect(_details, findsOneWidget);
    expect(_choice('❤️'), findsNothing);
    await tester.tap(_addOwn);
    await tester.pumpAndSettle();
    expect(_choice('❤️'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _dispose(tester, client, cache);
  });

  testWidgets('socket invalidation refetches only its account and message once',
      (tester) async {
    final cache = MessageReactionsCache();
    final reads = <String>[];
    final client = MockClient((request) async {
      reads.add('${request.url}|${request.headers['Authorization']}');
      return _response([_item(reads.length > 4 ? '❤️' : '👍')]);
    });
    await tester.pumpWidget(_view(client, cache,
        body: Column(children: [
          _reactions(client, cache),
          _reactions(client, cache, token: 'other-token'),
          _reactions(client, cache, messageId: 'other-message'),
          _reactions(client, cache, api: 'https://other.test/api'),
        ])));
    await tester.pumpAndSettle();
    expect(reads.length, 4);
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'event-1');
    await tester.pumpAndSettle();
    expect(reads.length, 5);
    expect(reads.last, '$_api/messages/$_id/reactions|Bearer $_token');
    expect(_button('❤️'), findsOneWidget);
    expect(_button('👍'), findsNWidgets(3));
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'event-1');
    cache.invalidate(
        api: _api, token: _token, messageId: 'unseen', eventId: 'event-2');
    await tester.pumpAndSettle();
    expect(reads.length, 5);
    await _dispose(tester, client, cache);
  });

  testWidgets(
      'concurrent visible copies share an event refresh and remount cache',
      (tester) async {
    final cache = MessageReactionsCache();
    final fresh = Completer<http.Response>();
    var reads = 0;
    final client = MockClient((_) {
      reads++;
      return reads == 1 ? Future.value(_response([_item('👍')])) : fresh.future;
    });
    Widget body() => Column(children: [
          for (var i = 0; i < 2; i++)
            KeyedSubtree(key: ValueKey(i), child: _reactions(client, cache)),
        ]);
    await tester.pumpWidget(_view(client, cache, body: body()));
    await tester.pumpAndSettle();
    expect(reads, 1);
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'event');
    await tester.pump();
    expect(reads, 2);
    fresh.complete(_response([_item('❤️')]));
    await tester.pumpAndSettle();
    expect(_button('❤️'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_view(client, cache, body: body()));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(_button('❤️'), findsNWidgets(2));
    await _dispose(tester, client, cache);
  });

  testWidgets(
      'event during a pending read discards stale payload and reads again',
      (tester) async {
    final cache = MessageReactionsCache();
    final stale = Completer<http.Response>();
    final fresh = Completer<http.Response>();
    var reads = 0;
    final client = MockClient((_) {
      reads++;
      return reads == 1 ? stale.future : fresh.future;
    });
    await tester.pumpWidget(_view(client, cache));
    expect(reads, 1);
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'event-a');
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'event-b');
    await tester.pump();
    expect(reads, 1);
    stale.complete(_response([_item('😂')]));
    await tester.pumpAndSettle();
    expect(_button('😂'), findsNothing);
    expect(reads, 2);
    fresh.complete(_response([_item('❤️')]));
    await tester.pumpAndSettle();
    expect(_button('❤️'), findsOneWidget);
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'event-b');
    await tester.pumpAndSettle();
    expect(reads, 2);
    await _dispose(tester, client, cache);
  });

  testWidgets(
      'a socket event during a write cannot be undone by its old response',
      (tester) async {
    final cache = MessageReactionsCache();
    final write = Completer<http.Response>();
    var reads = 0;
    var detailsReads = 0;
    var writes = 0;
    final client = MockClient((request) {
      if (request.method == 'PUT') {
        writes++;
        return write.future;
      }
      if (request.url.path.endsWith('/reactions/details')) {
        detailsReads++;
        return Future.value(_response([_item('👍')], request: request));
      }
      reads++;
      return Future.value(_response([_item(reads == 1 ? '👍' : '❤️')]));
    });
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    await _openChooser(tester, '👍');
    expect(detailsReads, 1);
    await tester.tap(_choice('😂'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'updated');
    await tester.pump();
    expect(reads, 1);
    write.complete(_response([_item('😂', mine: true)]));
    await tester.pumpAndSettle();
    await _closeDetails(tester);
    expect(reads, 2);
    expect(_button('😂'), findsNothing);
    expect(_button('❤️'), findsOneWidget);
    await _dispose(tester, client, cache);
  });

  testWidgets(
      'socket invalidation honors cooldown, then refreshes the latest state',
      (tester) async {
    var now = DateTime.utc(2026, 10, 7);
    final cache = MessageReactionsCache(now: () => now);
    var reads = 0;
    var detailsReads = 0;
    var writes = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/reactions/details')) {
        detailsReads++;
        return _response([_item('👍')], request: request);
      }
      if (request.method == 'PUT') writes++;
      reads++;
      if (reads == 1) return _response([_item('👍')]);
      if (reads == 2)
        return http.Response('{}', 429, headers: {'retry-after': '120'});
      return _response([_item('❤️')]);
    });
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'limited');
    await tester.pumpAndSettle();
    expect(reads, 2);
    for (var i = 0; i < 3; i++) {
      cache.invalidate(
          api: _api, token: _token, messageId: _id, eventId: 'event-$i');
    }
    await tester.pumpAndSettle();
    expect(reads, 2);
    await tester.tap(_button('👍'));
    await tester.pumpAndSettle();
    expect(_details, findsOneWidget);
    expect(_addOwn, findsNothing);
    expect(_choice('😂'), findsNothing);
    expect(find.byKey(const ValueKey('remove-own-reaction')), findsNothing);
    expect(detailsReads, 0);
    expect(reads, 2);
    expect(writes, 0);
    await _closeDetails(tester);
    now = now.add(const Duration(seconds: 121));
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'after-cooldown');
    await tester.pumpAndSettle();
    expect(reads, 3);
    expect(_button('❤️'), findsOneWidget);
    await _dispose(tester, client, cache);
  });

  testWidgets('account switch discards an invalidated account pending response',
      (tester) async {
    final cache = MessageReactionsCache();
    final oldRefresh = Completer<http.Response>();
    final tokens = <String>[];
    final client = MockClient((request) {
      final token = request.headers['Authorization']!;
      tokens.add(token);
      if (tokens.length == 2) return oldRefresh.future;
      return Future.value(
          _response([_item(token == 'Bearer new-account' ? '❤️' : '👍')]));
    });
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    cache.invalidate(
        api: _api, token: _token, messageId: _id, eventId: 'old-event');
    await tester.pump();
    await tester.pumpWidget(_view(client, cache, token: 'new-account'));
    await tester.pumpAndSettle();
    oldRefresh.complete(_response([_item('😂')]));
    await tester.pumpAndSettle();
    expect(tokens, ['Bearer $_token', 'Bearer $_token', 'Bearer new-account']);
    expect(_button('❤️'), findsOneWidget);
    expect(_button('😂'), findsNothing);
    expect(tester.takeException(), isNull);
    await _dispose(tester, client, cache);
  });

  testWidgets(
      'representative count and wrap geometry renders without backgrounds',
      (tester) async {
    final boundary = GlobalKey();
    final cache = MessageReactionsCache();
    final client = MockClient((request) async => _response(
        request.url.path.contains('narrow')
            ? [for (final emoji in messageReactionEmoji) _item(emoji)]
            : [_item('👍', count: request.url.path.contains('two') ? 2 : 1)]));
    await tester.pumpWidget(_view(client, cache,
        body: RepaintBoundary(
            key: boundary,
            child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final id in ['single', 'two', 'narrow']) ...[
                        MessageHover(
                          reactionsOnChild: true,
                          sideReactions:
                              _reactions(client, cache, messageId: id),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            MessageObjectReactions(
                                child: Container(
                                    width: id == 'narrow' ? 70 : 220,
                                    height: 80,
                                    decoration: const BoxDecoration(
                                        gradient: LinearGradient(colors: [
                                      Color(0xff318cc2),
                                      Color(0xff12496d)
                                    ])),
                                    child: const Center(
                                        child: Icon(Icons.photo_outlined,
                                            color: Colors.white, size: 32)))),
                            const Text('תמונה מהשיחה'),
                          ]),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ])))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (!kIsWeb) {
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes != null) {
          await saveReactionTestArtifact(bytes.buffer.asUint8List());
        }
        image.dispose();
      });
    }
    await _dispose(tester, client, cache);
  });
}
