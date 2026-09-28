import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:betshuva/direct_support_buttons.dart';

void main() {
  for (final entry
      in {'בקשה לשיפור': 'feature', 'דיווח על תקלה': 'bug'}.entries) {
    testWidgets(
        '${entry.key} opens a form and sends only after explicit submission',
        (tester) async {
      final requests = <http.Request>[];
      final done = Completer<http.Response>();
      final client = MockClient((request) {
        requests.add(request);
        return done.future;
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: DirectSupportButtons(
                  api: 'https://example.test/api',
                  token: 'test-token',
                  appVersion: 'test',
                  client: client))));
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester.tap(find.text('שליחת הפנייה'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(find.text('יש להזין לפחות 5 תווים'), findsOneWidget);
      await tester.enterText(
          find.byType(TextFormField), 'תיאור מפורט של הבקשה');
      await tester.tap(find.text('שליחת הפנייה'));
      await tester.pump();
      expect(requests.length, 1);
      expect(requests.single.headers['authorization'], 'Bearer test-token');
      expect(jsonDecode(requests.single.body)['issueType'], entry.value);
      expect(jsonDecode(requests.single.body)['description'],
          'תיאור מפורט של הבקשה');
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      done.complete(http.Response('{"id":"created"}', 201));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('הפנייה נשלחה'), findsOneWidget);
      client.close();
    });
  }
  testWidgets('cancel never sends and a server error preserves the draft',
      (tester) async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response('{}', 503);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DirectSupportButtons(
                api: 'https://example.test/api',
                token: 'token',
                appVersion: 'test',
                client: client))));
    await tester.tap(find.text('דיווח על תקלה'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.tap(find.text('דיווח על תקלה'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'תיאור התקלה שנשמר');
    await tester.tap(find.text('שליחת הפנייה'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('תיאור התקלה שנשמר'), findsOneWidget);
    expect(find.text('לא ניתן לשלוח את הפנייה'), findsOneWidget);
    client.close();
  });
}
