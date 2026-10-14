import 'dart:convert';

import 'package:betshuva/message_reactions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
      'historical retired house reactions remain readable without writes',
      (tester) async {
    final methods = <String>[];
    final client = MockClient((request) async {
      methods.add(request.method);
      return http.Response(
        jsonEncode([
          {'emoji': '[[bt-emoji:041]]', 'count': 1, 'mine': false},
          {'emoji': '[[bt-emoji:097]]', 'count': 2, 'mine': true},
        ]),
        200,
      );
    });
    final cache = MessageReactionsCache();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageReactions(
          api: 'https://fixture.invalid/api',
          token: 'synthetic-token',
          messageId: 'historical-house-reactions',
          client: client,
          cache: cache,
          showAddButton: false,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ActionChip), findsNWidgets(2));
    for (final id in [41, 97]) {
      final artwork = find.byKey(ValueKey('inline-custom-emoji-$id'));
      expect(artwork, findsOneWidget);
      expect((tester.widget<Image>(artwork).image as NetworkImage).url,
          'https://betshuva.com/betshuva-app/api/expressions/emoji/$id');
    }
    expect(find.textContaining('[[bt-emoji:'), findsNothing);
    expect(methods, ['GET']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    client.close();
    cache.dispose();
  });
}
