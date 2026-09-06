import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:betshuva/main.dart';

void main() {
  testWidgets('full listing shows AI and sends consultation on tap', (tester) async {
    // Widget tests block real HTTP images; this test verifies navigation and sending.
    final previousErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      final error = details.exception;
      if (error is NetworkImageLoadException && error.statusCode == 400 &&
          error.uri.path.endsWith('/assets/assets/guide/safe-information-ai.png')) {
        return;
      }
      previousErrorHandler?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousErrorHandler);
    SharedPreferences.setMockInitialValues({});
    final sent = <Map<String, dynamic>>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: Directionality(textDirection: TextDirection.rtl,
          child: ListingDetailScreen(
            token: 'test', me: const {'id': 'test-user'}, socket: null,
            item: const {
              'id': '11111111-1111-4111-8111-111111111111',
              'title': 'מקרר לבדיקה', 'type': 'sale', 'price': 100.0,
              'seller_id': 'seller', 'seller_name': 'מפרסם',
              'status': 'active',
            },
          )),
      ));
      expect(find.text('AI'), findsOneWidget);
      expect(sent, isEmpty);
      await tester.tap(find.text('AI'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(sent.length, 1);
      expect(sent.single['toUserId'], kSafeInformationAiId);
      expect(sent.single['text'], contains('betshuva://listing/11111111-1111-4111-8111-111111111111'));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }, () => MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/messages')) {
        sent.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response('{"id":"sent-message","status":"read"}', 200);
      }
      if (request.url.path.contains('/messages/')) return http.Response('[]', 200);
      if (request.url.path.endsWith('filter-settings')) return http.Response('{"filter":{"text":true},"requiresChoice":false}', 200);
      if (request.url.path.endsWith('receiving-filter')) return http.Response('{"filter":{"text":true}}', 200);
      return http.Response('{}', 200);
    }));
  });
  for (final autoSend in [true, false]) {
    testWidgets('listing question auto-send=$autoSend only sends once', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final sent = <Map<String, dynamic>>[];
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
          home: Directionality(textDirection: TextDirection.rtl,
            child: ChatScreen(
              token: 'test', me: const {'id': 'test-user'}, socket: null,
              recipient: const {'id': kSafeInformationAiId, 'name': 'מידע בטוח'},
              initialText: 'שאלת התייעצות', autoSendInitialMessage: autoSend,
            )),
        ));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(sent.length, autoSend ? 1 : 0);
        if (autoSend) expect(sent.single['text'], 'שאלת התייעצות');
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(sent.length, autoSend ? 1 : 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }, () => MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/messages')) {
          sent.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'id':'sent-message','status':'read'}), 200);
        }
        if (request.url.path.contains('/messages/')) return http.Response('[]', 200);
        if (request.url.path.endsWith('filter-settings')) return http.Response('{"filter":{"text":true},"requiresChoice":false}', 200);
        if (request.url.path.endsWith('receiving-filter')) return http.Response('{"filter":{"text":true}}', 200);
        return http.Response('{}', 200);
      }));
    });
  }
}
