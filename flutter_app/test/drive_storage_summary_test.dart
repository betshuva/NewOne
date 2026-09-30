import 'dart:async';
import 'dart:convert';

import 'package:betshuva/drive_storage_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Widget screen({String token = 'user-a', int revision = 0}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 240,
          child: DriveStorageSummary(
            api: 'https://example.test/api',
            token: token,
            revision: revision,
          ),
        ),
      ),
    );

void main() {
  testWidgets('shows Google free capacity and refreshes on demand',
      (tester) async {
    var calls = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.textContaining('2.50 GB'), findsOneWidget);
      expect(find.textContaining('15.00 GB'), findsOneWidget);
      expect(find.textContaining('Gmail'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(screen(revision: 1));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('0 B'), findsOneWidget);
    },
        () => MockClient((request) async {
              expect(request.url.path, '/api/backup/google/storage');
              expect(request.headers['Authorization'], 'Bearer user-a');
              calls++;
              return http.Response(
                  jsonEncode({
                    'status': 'available',
                    'usedBytes': calls == 1 ? '13421772800' : '16106127360',
                    'freeBytes': calls == 1 ? '2684354560' : '0',
                    'limitBytes': '16106127360',
                  }),
                  200);
            }));
  });

  for (final entry in {
    'disconnected': 'Google Drive אינו מחובר',
    'reconnect_required': 'יש לחבר מחדש',
    'unavailable': 'אינם זמינים כרגע',
    'unlimited': 'ללא מגבלת אחסון',
  }.entries) {
    testWidgets('renders ${entry.key} without inventing free bytes',
        (tester) async {
      await http.runWithClient(() async {
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        expect(find.textContaining(entry.value), findsOneWidget);
        expect(find.textContaining('GB'), findsNothing);
      },
          () => MockClient((_) async => http.Response(
              jsonEncode({
                'status': entry.key == 'unlimited' ? 'available' : entry.key,
                'unlimited': entry.key == 'unlimited',
                'usedBytes': '0',
              }),
              entry.key == 'unavailable' ? 502 : 200)));
    });
  }

  testWidgets(
      'late response from previous account cannot replace current account',
      (tester) async {
    final oldResponse = Completer<http.Response>();
    await http.runWithClient(() async {
      await tester.pumpWidget(screen());
      await tester.pumpWidget(screen(token: 'user-b'));
      await tester.pumpAndSettle();
      expect(find.text('Google Drive אינו מחובר'), findsOneWidget);
      oldResponse.complete(http.Response(
          jsonEncode({
            'status': 'available',
            'usedBytes': '15106127360',
            'freeBytes': '1000000000',
            'limitBytes': '16106127360',
          }),
          200));
      await tester.pumpAndSettle();
      expect(find.text('Google Drive אינו מחובר'), findsOneWidget);
      expect(find.textContaining('GB'), findsNothing);
    },
        () => MockClient((request) async {
              if (request.headers['Authorization'] == 'Bearer user-a') {
                return oldResponse.future;
              }
              return http.Response('{"status":"disconnected"}', 200);
            }));
  });

  testWidgets(
      'large quota distinguishes total Google usage from remaining space',
      (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.textContaining('812.3 MB'), findsOneWidget);
      expect(find.textContaining('16.00 TB'), findsOneWidget);
      expect(find.textContaining('16383.21 GB'), findsOneWidget);
      expect(find.textContaining('מקום פנוי לפי Google'), findsOneWidget);
      expect(find.textContaining('מכסה עשויה להיות משותפת'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
        () => MockClient((_) async => http.Response(
            jsonEncode({
              'status': 'available',
              'usedBytes': '851749971',
              'limitBytes': '17592186044416',
              'freeBytes': '17591334294445',
            }),
            200)));
  });
}
