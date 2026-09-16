import 'dart:convert';
import 'package:betshuva/calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const settings = {
  'city': 'ירושלים',
  'latitude': 31.778,
  'longitude': 35.235,
  'timezone': 'Asia/Jerusalem',
  'israel': true,
  'candle_minutes': 40
};
Map<String, dynamic> event(String id, String title, String start, String end,
        {String? response}) =>
    {
      'id': id,
      'title': title,
      'start_local': start,
      'end_local': end,
      'event_start_local': start,
      'event_end_local': end,
      'timezone': 'Asia/Jerusalem',
      'all_day': false,
      'color': 'blue',
      'notes': 'הערות לאירוע',
      'location': 'משרד',
      'version': 1,
      'owner_name': 'יוצר האירוע',
      'response': response,
      'reminder_minutes': 15
    };
http.Response json(Object b) => http.Response(jsonEncode(b), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});
Future<void> withCalendar(
    WidgetTester tester, Future<void> Function(List<http.Request>) check,
    {Size size = const Size(1200, 900),
    bool pending = false,
    bool failHolidays = false}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <http.Request>[];
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(
              fontFamily: 'NotoSansHebrew',
              colorScheme:
                  ColorScheme.fromSeed(seedColor: const Color(0xFF1B6CA8))),
          home: CalendarScreen(
              api: 'https://example.test/api', token: 'private-token')));
      await tester.pumpAndSettle();
      await check(requests);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    }
  },
      () => MockClient((r) async {
            requests.add(r);
            final p = r.url.path;
            if (r.method == 'POST') {
              return json({
                'ids': ['saved'],
                'ok': true
              });
            }
            if (p.endsWith('/settings')) {
              return json({
                'settings': settings,
                'configured': true,
                'cities': [settings],
                'today': '2026-09-18'
              });
            }
            if (p.endsWith('/contacts')) {
              return json([
                {'id': 'friend', 'name': 'חבר להזמנה'}
              ]);
            }
            if (p.endsWith('/inbox')) {
              return json({
                'notices': [],
                'invitations': pending
                    ? [
                        event('invite', 'הזמנה פרטית', '2026-09-18T15:00',
                            '2026-09-18T16:00',
                            response: 'pending')
                      ]
                    : []
              });
            }
            if (p.endsWith('/events')) {
              return json({
                'events': [
                  event('a', 'פגישה ראשונה', '2026-09-18T09:00',
                      '2026-09-18T10:30'),
                  event('b', 'פגישה חופפת', '2026-09-18T10:00',
                      '2026-09-18T11:00')
                ]
              });
            }
            if (p.endsWith('/holidays')) {
              if (failHolidays) return http.Response('{}', 503);
              return json({
                'configured': true,
                'items': [
                  {
                    'date': '2026-09-18',
                    'title': 'ז׳ בתשרי תשפ״ז',
                    'category': 'hebdate'
                  },
                  {
                    'date': '2026-09-18T18:01:00+03:00',
                    'title': 'הדלקת נרות',
                    'category': 'candles'
                  },
                  {
                    'date': '2026-09-19T19:16:00+03:00',
                    'title': 'הבדלה',
                    'category': 'havdalah'
                  },
                  {
                    'date': '2026-09-19T19:52:00+03:00',
                    'title': 'רבנו תם — 72 דקות אחרי השקיעה',
                    'category': 'rabbeinu_tam'
                  }
                ]
              });
            }
            return json({});
          }));
}

void main() {
  testWidgets(
      'calendar month, week and day show events and distinct exit times',
      (tester) async {
    await withCalendar(tester, (requests) async {
      expect(find.text('לוח שנה'), findsOneWidget);
      expect(find.textContaining('פגישה ראשונה'), findsWidgets);
      expect(find.textContaining('רבנו תם'), findsWidgets);
      await tester.tap(find.text('שבוע'));
      await tester.pumpAndSettle();
      expect(find.text('09:00'), findsOneWidget);
      await tester.tap(find.text('יום'));
      await tester.pumpAndSettle();
      expect(find.textContaining('פגישה חופפת'), findsOneWidget);
      expect(requests.where((r) => r.method != 'GET'), isEmpty);
    });
  });
  testWidgets(
      'mobile month and weekly timeline fit and keep controls accessible',
      (tester) async {
    await withCalendar(tester, (requests) async {
      await tester.tap(find.text('שבוע'));
      await tester.pumpAndSettle();
      expect(find.text('אירוע חדש'), findsOneWidget);
    }, size: const Size(390, 844));
  });
  testWidgets('new event sends selected friend and explicit local time zone',
      (tester) async {
    await withCalendar(tester, (requests) async {
      await tester.tap(find.text('אירוע חדש'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'שם האירוע'), 'ישיבת צוות');
      await tester.ensureVisible(find.text('חבר להזמנה'));
      await tester.tap(find.text('חבר להזמנה'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('שמירה ושליחת הזמנות'));
      await tester.pumpAndSettle();
      final sent = jsonDecode(requests
          .singleWhere(
              (r) => r.method == 'POST' && r.url.path.endsWith('/events'))
          .body);
      expect(sent['title'], 'ישיבת צוות');
      expect(sent['timezone'], 'Asia/Jerusalem');
      expect(sent['invitees'], ['friend']);
      expect(sent['start'], '2026-09-18T09:00');
    });
  });
  testWidgets(
      'invitee can accept a pending invitation without editing the event',
      (tester) async {
    await withCalendar(tester, (requests) async {
      await tester.tap(find.byTooltip('הזמנות ועדכונים'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('הזמנה פרטית'));
      await tester.pumpAndSettle();
      expect(find.text('עריכה ומוזמנים'), findsNothing);
      await tester.tap(find.text('אישור'));
      await tester.pumpAndSettle();
      final sent = requests.singleWhere((r) => r.url.path.endsWith('/respond'));
      expect(jsonDecode(sent.body), {'response': 'accepted', 'version': 1});
    }, pending: true);
  });
  testWidgets('holiday outage is visible without hiding personal events',
      (tester) async {
    await withCalendar(tester, (requests) async {
      expect(find.textContaining('אינם זמינים'), findsOneWidget);
      expect(find.textContaining('פגישה ראשונה'), findsWidgets);
    }, failHolidays: true);
  });
}
