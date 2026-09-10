import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:betshuva/message_reactions.dart';

void main() {
  testWidgets('tap own reaction removes it and another emoji replaces it',
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
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MessageReactions(
                api: 'https://example.test/api',
                token: 'token',
                messageId: 'id',
                client: client))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('👍 1'));
    await tester.pumpAndSettle();
    expect(writes, [null]);
    expect(find.text('👍 1'), findsNothing);
    await tester.tap(find.byTooltip('תגובה להודעה'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('❤️'));
    await tester.pumpAndSettle();
    expect(writes, [null, '❤️']);
    expect(find.text('❤️ 1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    client.close();
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
    Widget view() => MaterialApp(
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
    expect(find.text('👍 1'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(view());
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.text('👍 1'), findsNWidgets(2));
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
    expect(find.text('❤️ 1'), findsOneWidget);
    oldResponse.complete(_response('👍'));
    await tester.pumpAndSettle();
    expect(tokens, ['Bearer old-token', 'Bearer new-token']);
    expect(find.text('👍 1'), findsNothing);
    expect(find.text('❤️ 1'), findsOneWidget);
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
      expect(find.text('👍 1'), findsOneWidget);
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
    await tester.tap(find.text('👍 1'));
    await tester.pumpAndSettle();
    expect(find.text('👍 1'), findsNothing);
    staleResponse.complete(_response('👍'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_view(client, cache));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('👍 1'), findsNothing);
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
    expect(find.text('👍 1'), findsOneWidget);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('👍 1'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    client.close();
  });
}

Widget _view(http.Client client, MessageReactionsCache cache,
        {String token = 'token', String messageId = 'message'}) =>
    MaterialApp(
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
