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
}
