import 'dart:async';
import 'dart:convert';
import 'package:betshuva/unified_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('matches Hebrew names, email and formatted phone numbers', () {
    expect(contactMatches({'name': 'שָׁלוֹם'}, 'שלום'), isTrue);
    expect(contactMatches({'phone': '050-123-4567'}, '050123'), isTrue);
    expect(contactMatches({'email': 'Me@Example.com'}, 'example'), isTrue);
  });

  testWidgets(
      'saved contacts and groups precede phone contacts and message hits',
      (tester) async {
    await http.runWithClient(() async {
      Map<String, dynamic>? opened;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: UnifiedSearchResults(
        api: 'https://test/api',
        token: 'test',
        query: 'שלום',
        users: const [
          {'id': 'friend', 'name': 'שלום חבר'}
        ],
        groups: const [
          {'id': 'group', 'name': 'שלום קבוצה'}
        ],
        loadDeviceContacts: () async => [
          {'id': 'phone', 'name': 'שלום טלפון'}
        ],
        saveUser: (_) async {},
        openConversation: (_, __) {},
        openMessage: (m) => opened = m,
        approvePictures: (_, __) {},
        pictureRevision: 0,
      ))));
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('שלום חבר')).dy,
          lessThan(tester.getTopLeft(find.text('שלום קבוצה')).dy));
      expect(tester.getTopLeft(find.text('שלום קבוצה')).dy,
          lessThan(tester.getTopLeft(find.text('שלום טלפון')).dy));
      await tester.scrollUntilVisible(find.text('שיחה שנמצאה'), 150);
      await tester.tap(find.text('שיחה שנמצאה'));
      expect(opened?['id'], 'message');
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async => http.Response(
            jsonEncode(request.url.path.endsWith('/users/search')
                ? []
                : {
                    'messages': [
                      {
                        'id': 'message',
                        'body': 'שלום הודעה',
                        'conversation_name': 'שיחה שנמצאה',
                        'kind': 'group'
                      }
                    ],
                    'nextCursor': null,
                  }),
            200, headers: {'content-type': 'application/json; charset=utf-8'})));
  });

  testWidgets('late responses cannot replace the current query',
      (tester) async {
    final oldUserResponse = Completer<http.Response>();
    final oldMessageResponse = Completer<http.Response>();
    await http.runWithClient(() async {
      Widget view(String query) => MaterialApp(
              home: Scaffold(
                  body: UnifiedSearchResults(
            api: 'https://test/api',
            token: 'test',
            query: query,
            users: const [],
            groups: const [],
            loadDeviceContacts: () async => [],
            saveUser: (_) async {},
            openConversation: (_, __) {},
            openMessage: (_) {},
            approvePictures: (_, __) {},
            pictureRevision: 0,
          )));
      await tester.pumpWidget(view('ישן'));
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpWidget(view('חדש'));
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      oldUserResponse.complete(http.Response(
          jsonEncode([
            {'id': 'old', 'name': 'ישן'}
          ]),
          200, headers: {'content-type': 'application/json; charset=utf-8'}));
      oldMessageResponse.complete(http.Response(
          jsonEncode({
            'messages': [
              {'id': 'old', 'body': 'ישן'}
            ],
            'nextCursor': null
          }),
          200, headers: {'content-type': 'application/json; charset=utf-8'}));
      await tester.pumpAndSettle();
      expect(find.text('ישן'), findsNothing);
      expect(find.text('חדש'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async {
              final users = request.url.path.endsWith('/users/search');
              if (request.url.queryParameters['q'] == 'ישן')
                return users
                    ? oldUserResponse.future
                    : oldMessageResponse.future;
              return http.Response(
                  jsonEncode(users
                      ? [
                          {'id': 'new', 'name': 'חדש'}
                        ]
                      : {'messages': [], 'nextCursor': null}),
                  200, headers: {'content-type': 'application/json; charset=utf-8'});
            }));
  });
}
