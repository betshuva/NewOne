import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:betshuva/incoming_share_actions.dart';
import 'calendar_import_test.dart' as fixtures;

Future<void> runImport(WidgetTester tester, Map<String, dynamic> share,
    void Function(IncomingActionResult, List<http.Request>) check) async {
  final requests = <http.Request>[];
  IncomingActionResult? result;
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: FilledButton(
                  child: const Text('open'),
                  onPressed: () async {
                    result = await processIncomingShare(context,
                        share: share,
                        api: 'https://example.test/api',
                        token: 'token',
                        accountId: 'account',
                        canAct: () => true,
                        deliver: (_, __) async => throw StateError(
                            'An event must go to the personal calendar'),
                        createListing: (_) async => false,
                        openChat: (_) async {},
                        capture: () async => null);
                  },
                )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('incoming-share-calendar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calendar-import-continue')));
    await tester.pumpAndSettle();
        await tester.tap(find.text('שמירה'));
        await tester.pumpAndSettle();
        for (var i = 0; i < 100 && result == null; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 10));
        }
    expect(result, isNotNull);
    check(result!, requests);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  },
      () => MockClient((request) async {
            requests.add(request);
            if (request.url.path.endsWith('/import/preview'))
              return fixtures.response({
                'drafts': [
                  {
                    'draft': fixtures.draft,
                    'import_key': 'signed',
                    'warnings': [],
                    'requires_single_occurrence': false
                  }
                ],
                'warnings': [],
              });
            if (request.url.path.endsWith('/settings'))
              return fixtures.response({
                'settings': {'timezone': 'Asia/Jerusalem'}
              });
            if (request.url.path.endsWith('/events'))
              return fixtures.response({
                'ids': ['event']
              }, 201);
            return fixtures.response({'error': 'unexpected'}, 404);
          }));
}

void main() {
  testWidgets(
      'calendar metadata is acknowledged independently from shared text and PDF',
      (tester) async {
    await runImport(tester, {
      'calendar': {'title': 'פגישה', 'beginTime': 1234, 'endTime': 5678},
      'text': 'פרטים נוספים',
      'files': [
        {
          'path': '/cache/info.pdf',
          'name': 'info.pdf',
          'mime': 'application/pdf'
        }
      ]
    }, (result, requests) {
      expect(result.outcome, 'retry');
      expect(result.clearCalendar, isTrue);
      expect(result.clearText, isFalse);
      expect(result.completedPaths, isEmpty);
      expect(requests.where((r) => r.url.path.endsWith('/events')).length, 1);
    });
  });

  testWidgets('shared Google Calendar template becomes an event in Betshuva',
      (tester) async {
    await runImport(tester, {
      'text':
          'https://calendar.google.com/calendar/render?action=TEMPLATE&text=Meeting&dates=20261020T090000Z%2F20261020T100000Z'
    }, (result, requests) {
      expect(result.outcome, 'completed');
      expect(result.clearText, isTrue);
      final preview = jsonDecode(requests.first.body) as Map;
      expect(preview['event']['title'], 'Meeting');
      expect(preview['event']['start_epoch_ms'], isA<int>());
    });
  });

  testWidgets('ICS takes precedence over duplicate structured event extras',
      (tester) async {
    await runImport(tester, {
      'text': 'BEGIN:VCALENDAR',
      'calendar': {'title': 'same event'}
    }, (result, requests) {
      expect(result.outcome, 'completed');
      expect(result.clearText && result.clearCalendar, isTrue);
      final previews = requests
          .where((r) => r.url.path.endsWith('/import/preview'))
          .toList();
      expect(previews.length, 1);
      expect(jsonDecode(previews.single.body)['ics'], 'BEGIN:VCALENDAR');
    });
  });

  testWidgets(
      'an unreadable later ICS retains earlier successful acknowledgement',
      (tester) async {
    await runImport(tester, {
      'text': 'BEGIN:VCALENDAR',
      'files': [
        {
          'path': '/file-that-does-not-exist.ics',
          'name': 'missing.ics',
          'mime': 'text/calendar'
        }
      ]
    }, (result, requests) {
      expect(result.outcome, 'retry');
      expect(result.clearText, isTrue);
      expect(result.completedPaths, isEmpty);
      expect(requests.where((r) => r.url.path.endsWith('/events')).length, 1);
    });
  }, skip: kIsWeb);
}
