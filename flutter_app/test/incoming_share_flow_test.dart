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
        expectSync((request as http.MultipartRequest).fields['toUserId'], 'bob');
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
    await result;
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
}
