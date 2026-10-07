import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:betshuva/message_reactions.dart';
import 'package:betshuva/inline_custom_emoji.dart';

late String _reactionLibraryCatalog;

class _LibraryAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) => rootBundle.load(key);

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    if (key == 'assets/stickers/user-catalog.json') {
      return Future.value(_reactionLibraryCatalog);
    }
    return rootBundle.loadString(key, cache: cache);
  }
}

Widget _testApp({required Widget home}) => DefaultAssetBundle(
      bundle: _LibraryAssets(),
      child: MaterialApp(home: home),
    );

void main() {
  setUpAll(() async {
    // Native widget tests use a fake clock. Complete asset transport before
    // entering it, so a loading spinner cannot outrun the real file read.
    _reactionLibraryCatalog =
        await rootBundle.loadString('assets/stickers/user-catalog.json');
  });

  testWidgets('a single reaction has no count; counts start at two',
      (tester) async {
    final client = MockClient((_) async => http.Response(
        jsonEncode([
          {'emoji': '👍', 'count': 1, 'mine': false},
          {'emoji': '❤️', 'count': 2, 'mine': false},
          {'emoji': '😂', 'count': 12, 'mine': false},
        ]),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pumpWidget(_testApp(
        home: Scaffold(
            body: MessageReactions(
      api: 'https://test/api',
      token: 'token',
      messageId: 'counts',
      client: client,
      cache: MessageReactionsCache(),
      showAddButton: false,
    ))));
    await tester.pumpAndSettle();
    expect(find.text('👍'), findsOneWidget);
    expect(find.text('👍 1'), findsNothing);
    expect(find.text('❤️ 2'), findsOneWidget);
    expect(find.text('😂 12'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    client.close();
  });
  testWidgets(
      'quick emoji buttons add, replace and remove a reaction with one tap',
      (tester) async {
    final writes = <dynamic>[];
    final client = MockClient((request) async {
      if (request.method == 'GET') return http.Response('[]', 200);
      final emoji = jsonDecode(request.body)['emoji'];
      writes.add(emoji);
      return http.Response(
          jsonEncode(emoji == null
              ? []
              : [
                  {'emoji': emoji, 'count': 1, 'mine': true}
                ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(_testApp(
        home: Scaffold(
            body: SizedBox(
                width: 260,
                child: MessageReactions(
                    api: 'https://test/api',
                    token: 'token',
                    messageId: 'quick',
                    client: client,
                    cache: MessageReactionsCache(),
                    quickChoices: true,
                    showAddButton: false)))));
    await tester.pumpAndSettle();
    for (final emoji in ['👍', '❤️', '❤️']) {
      await tester.tap(find.byTooltip('תגובה $emoji'));
      await tester.pumpAndSettle();
    }
    expect(writes, ['👍', '❤️', null]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    client.close();
  });
  testWidgets('tap own reaction removes it and the library adds a custom emoji',
      (tester) async {
    final writes = <dynamic>[];
    final client = MockClient((request) async {
      if (request.method == 'PUT') {
        final emoji = jsonDecode(request.body)['emoji'];
        writes.add(emoji);
        return http.Response(
            jsonEncode(emoji == null
                ? []
                : [
                    {'emoji': emoji, 'count': 1, 'mine': true}
                  ]),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return http.Response(
          jsonEncode([
            {'emoji': '👍', 'count': 1, 'mine': true}
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(_testApp(
        home: Scaffold(
            body: MessageReactions(
                api: 'https://example.test/api',
                token: 'token',
                messageId: 'id',
                client: client))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();
    expect(writes, [null]);
    expect(find.text('👍'), findsNothing);
    await tester.tap(find.byTooltip('הוספת תגובה'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('message-reaction-library')), findsOneWidget);
    expect(writes, [null]);
    await tester.tap(find.byKey(const ValueKey('reaction-library-emoji-001')));
    await tester.pumpAndSettle();
    expect(writes, [null, '[[bt-emoji:001]]']);
    expect(find.byType(InlineEmojiText), findsOneWidget);
    expect(find.text('[[bt-emoji:001]]'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    client.close();
  });

  testWidgets('the add button delegates the custom selection after closing',
      (tester) async {
    final selected = <String>[];
    final writes = <String>[];
    final client = MockClient((request) async {
      if (request.method != 'GET') writes.add(request.method);
      return http.Response('[]', 200);
    });
    final cache = MessageReactionsCache();
    await tester.pumpWidget(_testApp(
      home: Scaffold(
        body: MessageReactions(
          api: 'https://example.test/api',
          token: 'token',
          messageId: 'delegate',
          client: client,
          cache: cache,
          onReactionSelected: selected.add,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final add = find.byKey(const ValueKey('add-message-reaction'));
    expect(find.descendant(of: add, matching: find.byIcon(Icons.add)),
        findsOneWidget);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(writes, isEmpty);
    await tester.tap(find.byTooltip('סגירה'));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(writes, isEmpty);
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('reaction-library-search')),
        'זהירות מקישור לא ידוע');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reaction-library-emoji-150')));
    await tester.pumpAndSettle();
    expect(selected, ['[[bt-emoji:150]]']);
    expect(writes, isEmpty);
    expect(
        find.byKey(const ValueKey('message-reaction-library')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    client.close();
    cache.dispose();
  });

  for (final accountChanged in [true, false]) {
    testWidgets(
        'a library choice cannot write after ${accountChanged ? 'account' : 'message'} changes',
        (tester) async {
      final writes = <String>[];
      final selected = <String>[];
      final cache = MessageReactionsCache();
      final client = MockClient((request) async {
        if (request.method != 'GET') writes.add(request.method);
        return http.Response('[]', 200);
      });
      Widget view({String token = 'old', String message = 'old-message'}) =>
          _testApp(
            home: Scaffold(
              body: MessageReactions(
                api: 'https://example.test/api',
                token: token,
                messageId: message,
                client: client,
                cache: cache,
                onReactionSelected: selected.add,
              ),
            ),
          );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-message-reaction')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(view(
          token: accountChanged ? 'new' : 'old',
          message: accountChanged ? 'old-message' : 'new-message'));
      await tester.pumpAndSettle();
      final choice = find.byKey(const ValueKey('reaction-library-emoji-001'));
      if (choice.evaluate().isNotEmpty) {
        await tester.tap(choice);
        await tester.pumpAndSettle();
      }
      expect(selected, isEmpty);
      expect(writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      client.close();
      cache.dispose();
    });
  }

  testWidgets('custom reaction chips render images and never print wire IDs',
      (tester) async {
    final client = MockClient((_) async => http.Response(
          jsonEncode([
            {'emoji': '[[bt-emoji:001]]', 'count': 1, 'mine': false},
            {'emoji': '[[bt-emoji:150]]', 'count': 2, 'mine': true},
          ]),
          200,
        ));
    final cache = MessageReactionsCache();
    await tester.pumpWidget(_testApp(
      home: Scaffold(
        body: MessageReactions(
          api: 'https://example.test/api',
          token: 'token',
          messageId: 'custom-chips',
          client: client,
          cache: cache,
          showAddButton: false,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ActionChip), findsNWidgets(2));
    expect(find.text('1'), findsNothing);
    expect(find.text('2'), findsOneWidget);
    expect(find.textContaining('[[bt-emoji:'), findsNothing);
    for (final id in [1, 150]) {
      final image = find.byKey(ValueKey('inline-custom-emoji-$id'));
      expect(image, findsOneWidget);
      expect(tester.getSize(image).width, closeTo(20, .001));
      expect(tester.getSize(image).height, closeTo(20, .001));
      final url = (tester.widget<Image>(image).image as NetworkImage).url;
      expect(url,
          'https://betshuva.com/betshuva-app/expression-library/user-20261008-color/sticker-${id.toString().padLeft(2, '0')}.png');
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    client.close();
    cache.dispose();
  });

  testWidgets(
      'concurrent views and scrolling back reuse one account-scoped read',
      (tester) async {
    final cache = MessageReactionsCache();
    final response = Completer<http.Response>();
    var reads = 0;
    final client = MockClient((request) {
      reads++;
      return response.future;
    });
    Widget view() => _testApp(
          home: Scaffold(
            body: Column(children: [
              for (var i = 0; i < 2; i++)
                MessageReactions(
                    key: ValueKey(i),
                    api: 'https://example.test/api',
                    token: 'token',
                    messageId: 'same-message',
                    client: client,
                    cache: cache,
                    showAddButton: false),
            ]),
          ),
        );
    await tester.pumpWidget(view());
    expect(reads, 1);
    response.complete(_response('👍'));
    await tester.pumpAndSettle();
    expect(find.text('👍'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.text('👍'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    client.close();
  });

  testWidgets('refreshes once per minute and pauses while app is in background',
      (tester) async {
    var now = DateTime.utc(2026, 9, 10);
    final cache = MessageReactionsCache(now: () => now);
    var reads = 0;
    final client = MockClient((request) async {
      reads++;
      return _response('👍');
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    expect(reads, 1);
    now = now.add(const Duration(seconds: 15));
    await tester.pump(const Duration(seconds: 15));
    expect(reads, 1);
    now = now.add(const Duration(seconds: 45));
    await tester.pump(const Duration(seconds: 45));
    expect(reads, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(reads, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(reads, 3);
    await tester.pumpWidget(const SizedBox());
    client.close();
  });

  testWidgets('a late response from a previous account cannot replace new data',
      (tester) async {
    final cache = MessageReactionsCache();
    final oldResponse = Completer<http.Response>();
    final tokens = <String>[];
    final client = MockClient((request) {
      final token = request.headers['Authorization']!;
      tokens.add(token);
      return token == 'Bearer old-token'
          ? oldResponse.future
          : Future.value(_response('❤️'));
    });
    await tester.pumpWidget(_view(client, cache, token: 'old-token'));
    await tester.pumpWidget(_view(client, cache, token: 'new-token'));
    await tester.pumpAndSettle();
    expect(find.text('❤️'), findsOneWidget);
    oldResponse.complete(_response('👍'));
    await tester.pumpAndSettle();
    expect(tokens, ['Bearer old-token', 'Bearer new-token']);
    expect(find.text('👍'), findsNothing);
    expect(find.text('❤️'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    client.close();
  });

  for (final retryAfter in ['120', 'Thu, 10 Sep 2026 10:02:00 GMT', null]) {
    testWidgets('429 cooldown covers all messages and honors $retryAfter',
        (tester) async {
      var now = DateTime.utc(2026, 9, 10, 10);
      final cache = MessageReactionsCache(now: () => now);
      final reads = <String>[];
      final client = MockClient((request) async {
        reads.add(request.headers['Authorization']!);
        if (reads.length == 1) {
          return http.Response('{"retryAfterSeconds":120}', 429,
              headers: {if (retryAfter != null) 'retry-after': retryAfter});
        }
        return _response('👍');
      });
      await tester.pumpWidget(_view(client, cache));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_view(client, cache, messageId: 'second'));
      await tester.pumpAndSettle();
      expect(reads, ['Bearer token']);
      await tester.pumpWidget(
          _view(client, cache, messageId: 'second', token: 'another-account'));
      await tester.pumpAndSettle();
      expect(reads, ['Bearer token', 'Bearer another-account']);
      now = now.add(const Duration(seconds: 119));
      await tester.pumpWidget(_view(client, cache, messageId: 'third'));
      await tester.pumpAndSettle();
      expect(reads.length, 2);
      now = now.add(const Duration(seconds: 2));
      await tester.pumpWidget(_view(client, cache, messageId: 'fourth'));
      await tester.pumpAndSettle();
      expect(reads, ['Bearer token', 'Bearer another-account', 'Bearer token']);
      expect(find.text('👍'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      client.close();
    });
  }

  testWidgets(
      'an old poll cannot undo a completed reaction update in the cache',
      (tester) async {
    var now = DateTime.utc(2026, 9, 10);
    final cache = MessageReactionsCache(now: () => now);
    final staleResponse = Completer<http.Response>();
    var reads = 0;
    final client = MockClient((request) {
      if (request.method == 'PUT') {
        return Future.value(http.Response('[]', 200));
      }
      reads++;
      return reads == 1 ? Future.value(_response('👍')) : staleResponse.future;
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(reads, 2);
    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();
    expect(find.text('👍'), findsNothing);
    staleResponse.complete(_response('👍'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('👍'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    client.close();
  });

  testWidgets('no-longer-visible messages discard cached reaction content',
      (tester) async {
    var now = DateTime.utc(2026, 9, 10);
    final cache = MessageReactionsCache(now: () => now);
    var reads = 0;
    final client = MockClient((request) async {
      reads++;
      return reads == 1 ? _response('👍') : http.Response('{}', 404);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    expect(find.text('👍'), findsOneWidget);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('👍'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    client.close();
  });
}

Widget _view(http.Client client, MessageReactionsCache cache,
        {String token = 'token', String messageId = 'message'}) =>
    _testApp(
      home: Scaffold(
        body: MessageReactions(
          api: 'https://example.test/api',
          token: token,
          messageId: messageId,
          client: client,
          cache: cache,
        ),
      ),
    );

http.Response _response(String emoji) => http.Response(
      jsonEncode([
        {'emoji': emoji, 'count': 1, 'mine': true}
      ]),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
