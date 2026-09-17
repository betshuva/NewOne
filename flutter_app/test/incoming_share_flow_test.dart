import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:betshuva/main.dart';

void main() {
  testWidgets(
      'direct recipient is preselected; pending and rejected files do not drop the rest',
      (tester) async {
    var uploads = 0;
    var sends = 0;
    final client = MockClient.streaming((request, stream) async {
      final bytes = await stream.toBytes();
      Object reply;
      if (request.method == 'GET') {
        reply = request.url.path.endsWith('/users')
            ? [
                {'id': 'bob', 'name': 'Bob'},
                {'id': 'carol', 'name': 'Carol'}
              ]
            : [];
      } else if (request.url.path.endsWith('/upload')) {
        expectSync(request, isA<http.MultipartRequest>());
        expectSync(
            (request as http.MultipartRequest).fields['toUserId'], 'bob');
        expectSync(bytes, isNotEmpty);
        uploads++;
        reply = uploads == 1
            ? {'status': 'pending'}
            : uploads == 2
                ? {'status': 'rejected', 'reason': 'blocked fixture'}
                : {
                    'status': 'approved',
                    'url': '/test/third.png',
                    'fileType': 'image'
                  };
      } else {
        sends++;
        final body = jsonDecode(utf8.decode(bytes)) as Map;
        expectSync(body['toUserId'], 'bob');
        expectSync(body['fileUrl'], '/test/third.png');
        reply = {'id': 'message-id'};
      }
      return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(reply))), 200,
          headers: {'content-type': 'application/json'});
    });
    late BuildContext screen;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      screen = context;
      return const SizedBox();
    }))));
    final result = forwardChatMessages(
        screen,
        'test-token',
        null,
        List.generate(
            3,
            (i) => <String, dynamic>{
                  'localBytes': Uint8List.fromList([1, 2, i]),
                  'fileName': 'image-$i.png',
                  'fileType': 'image',
                }),
        initialRecipientId: 'bob',
        client: client);
    await tester.pumpAndSettle();
    expect(find.text('שליחה אל Bob'), findsOneWidget);
    expect(find.text('Carol'), findsNothing);
    expect(uploads, 0); // Selecting the Android target alone never sends.
    await tester.tap(find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
    await tester.pumpAndSettle();
    final outcome = await result;
    expect(outcome.completedMessageIndexes, {0, 2});
    expect(outcome.sentCount, 1);
    expect(outcome.pendingCount, 1);
    expect(uploads, 3);
    expect(sends, 1);
    expect(find.textContaining('1 קבצים ממתינים לסריקה'), findsOneWidget);
    client.close();
  });

  testWidgets('a stale direct target cannot silently send to another person',
      (tester) async {
    var writes = 0;
    final client = MockClient((request) async {
      if (request.method != 'GET') writes++;
      return http.Response(
          jsonEncode(request.url.path.endsWith('/users')
              ? [
                  {'id': 'carol', 'name': 'Carol'}
                ]
              : []),
          200);
    });
    late BuildContext screen;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      screen = context;
      return const SizedBox();
    }))));
    final result = forwardChatMessages(
        screen,
        'test-token',
        null,
        [
          {'text': 'hello'}
        ],
        initialRecipientId: 'removed-user',
        client: client);
    await tester.pumpAndSettle();
    await result;
    expect(writes, 0);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.textContaining('איש הקשר אינו זמין'), findsOneWidget);
    client.close();
  });

  testWidgets(
      'recipient selection survives search, resize and keyboard changes',
      (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final writes = <http.Request>[];
    final client = MockClient((request) async {
      if (request.method != 'GET') {
        writes.add(request);
        return http.Response('{"id":"sent"}', 200);
      }
      return http.Response(
          jsonEncode(switch (request.url.path.replaceFirst('/betshuva-app', '')) {
            '/api/users' => [
                {'id': 'shared-id', 'name': 'Bob'},
                {'id': 'carol', 'name': 'Carol'},
              ],
            '/api/groups' => [
                {'id': 'shared-id', 'name': 'Study group'},
              ],
            _ => [],
          }),
          200);
    });
    addTearDown(client.close);
    late BuildContext screen;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      screen = context;
      return const SizedBox();
    }))));
    final result = forwardChatMessages(
        screen,
        'test-token',
        null,
        [
          {
            'fileUrl': '/test/approved.png',
            'fileName': 'approved.png',
            'fileType': 'image'
          },
        ],
        client: client);
    await tester.pumpAndSettle();
    final search = find.byKey(const ValueKey('forward-target-search'));
    final user = find.byKey(const ValueKey('forward-target-user:shared-id'));
    final group = find.byKey(const ValueKey('forward-target-group:shared-id'));
    await tester.enterText(search, 'bob');
    await tester.pumpAndSettle();
    await tester.tap(user);
    await tester.pumpAndSettle();
    await tester.enterText(search, 'study');
    await tester.pumpAndSettle();
    expect(user, findsNothing);
    expect(find.byKey(const ValueKey('forward-selected-user:shared-id')),
        findsOneWidget);
    await tester.tap(group);
    await tester.pumpAndSettle();
    expect(find.text('1 פריטים • 2 יעדים'), findsOneWidget);

    tester.view.physicalSize = const Size(390, 740);
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.widget<CheckboxListTile>(group).value, isTrue);
    expect(find.text('1 פריטים • 2 יעדים'), findsOneWidget);
    await tester.enterText(search, 'bob');
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(user).value, isTrue);
    await tester.enterText(search, 'no matching target');
    await tester.pumpAndSettle();
    expect(find.textContaining('התואמים לחיפוש'), findsOneWidget);
    expect(find.text('1 פריטים • 2 יעדים'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'העבר ל־2 יעדים'));
    await tester.pumpAndSettle();
    final outcome = await result;
    expect(outcome.completedMessageIndexes, {0});
    expect(writes.map((request) => request.url.path.replaceFirst('/betshuva-app', '')),
        ['/api/messages', '/api/groups/shared-id/messages']);
    expect(jsonDecode(writes.first.body)['toUserId'], 'shared-id');
    expect(
        writes.every((request) =>
            jsonDecode(request.body)['fileUrl'] == '/test/approved.png'),
        isTrue);
  });

  testWidgets(
      'only messages accepted by every selected recipient are completed',
      (tester) async {
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response(
            jsonEncode(request.url.path.endsWith('/users')
                ? [
                    {'id': 'bob', 'name': 'Bob'}
                  ]
                : request.url.path.endsWith('/groups')
                    ? [
                        {'id': 'study', 'name': 'Study group'}
                      ]
                    : []),
            200);
      }
      final body = jsonDecode(request.body);
      final rejected = request.url.path.contains('/groups/') &&
          body['text'] == 'partially sent';
      return http.Response(
          rejected ? '{"error":"Group filter rejected"}' : '{}',
          rejected ? 403 : 200);
    });
    addTearDown(client.close);
    late BuildContext screen;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      screen = context;
      return const SizedBox();
    }))));
    final result = forwardChatMessages(
        screen,
        'test-token',
        null,
        [
          {'text': 'fully sent'},
          {'text': 'partially sent'},
        ],
        client: client);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('forward-target-user:bob')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('forward-target-group:study')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'העבר ל־2 יעדים'));
    await tester.pumpAndSettle();
    final outcome = await result;
    expect(outcome.completedMessageIndexes, {0});
    expect(outcome.sentCount, 3);
    expect(outcome.totalDeliveries, 4);
    expect(find.textContaining('Group filter rejected'), findsOneWidget);
  });

  testWidgets(
      'cancelling or invalidating a forwarding choice performs no writes',
      (tester) async {
    var writes = 0;
    var allowed = true;
    final client = MockClient((request) async {
      if (request.method != 'GET') writes++;
      return http.Response(
          jsonEncode(request.url.path.endsWith('/users')
              ? [
                  {'id': 'bob', 'name': 'Bob'}
                ]
              : []),
          200);
    });
    addTearDown(client.close);
    late BuildContext screen;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      screen = context;
      return const SizedBox();
    }))));
    Future<ForwardChatResult> open() => forwardChatMessages(
        screen,
        'test-token',
        null,
        [
          {'text': 'hello'}
        ],
        initialRecipientId: 'bob',
        client: client,
        canForward: () => allowed);
    final cancelled = open();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('ביטול העברה'));
    await tester.pumpAndSettle();
    expect((await cancelled).cancelled, isTrue);
    expect(writes, 0);

    final invalidated = open();
    await tester.pumpAndSettle();
    allowed = false;
    await tester.tap(find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
    await tester.pumpAndSettle();
    final outcome = await invalidated;
    expect(outcome.cancelled, isTrue);
    expect(outcome.completedMessageIndexes, isEmpty);
    expect(writes, 0);
  });
}
