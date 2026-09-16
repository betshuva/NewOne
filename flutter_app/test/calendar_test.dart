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
  'candle_minutes': 15
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
    bool failHolidays = false,
    Map<String, dynamic> initialSettings = settings,
    http.Response? Function(http.Request)? respond}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <http.Request>[];
  var currentSettings = Map<String, dynamic>.from(initialSettings);
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
            final response = respond?.call(r);
            if (response != null) return response;
            if (r.method == 'POST') {
              return json({
                'ids': ['saved'],
                'ok': true
              });
            }
            if (p.endsWith('/settings')) {
              if (r.method == 'PUT') {
                currentSettings = Map<String, dynamic>.from(jsonDecode(r.body));
              }
              return json({
                'settings': currentSettings,
                'configured': true,
                'source': 'saved',
                'location_allowed': false,
                'cities': [settings],
                'timezones': [
                  'Asia/Jerusalem',
                  'Europe/London',
                  'Europe/Berlin',
                  'America/New_York'
                ],
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
      'city search resolves hidden coordinates and local calendar rules',
      (tester) async {
    const london = {
      'city': 'לונדון',
      'latitude': 51.5072,
      'longitude': -0.1276,
      'timezone': 'Europe/London',
      'israel': false,
      'candle_minutes': 15
    };
    await withCalendar(tester, (requests) async {
      await tester.tap(find.byTooltip('עיר וזמני שבת'));
      await tester.pumpAndSettle();
      expect(find.text('קו רוחב'), findsNothing);
      expect(find.text('קו אורך'), findsNothing);
      expect(find.widgetWithText(TextField, 'אזור זמן'), findsNothing);
      expect(find.widgetWithText(TextField, 'דקות הדלקת נרות לפני השקיעה'),
          findsNothing);
      await tester.enterText(
          find.widgetWithText(TextField, 'עיר או יישוב'), 'לונ');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'לונדון'));
      await tester.pumpAndSettle();
      expect(
          requests.any((r) =>
              r.url.path == '/api/localities' &&
              r.url.queryParameters['q'] == 'לונ'),
          isTrue);
      expect(
          requests
              .singleWhere((r) => r.url.path.endsWith('/location'))
              .url
              .queryParameters,
          {'city': 'לונדון'});
      expect(find.text('לונדון · Europe/London'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse);
      expect(find.widgetWithText(TextField, 'דקות הדלקת נרות לפני השקיעה'),
          findsNothing);
      await tester.tap(find.text('שמירה'));
      await tester.pumpAndSettle();
      expect(jsonDecode(requests.singleWhere((r) => r.method == 'PUT').body),
          london);
      expect(find.textContaining('לונדון · Europe/London'), findsOneWidget);
    }, respond: (r) {
      if (r.url.path == '/api/localities') {
        return json([
          {'city': 'לונדון'}
        ]);
      }
      if (r.url.path.endsWith('/location')) return json({'settings': london});
      return null;
    });
  });

  testWidgets('legacy saved candle offset is replaced with fixed 15 minutes',
      (tester) async {
    await withCalendar(tester, (requests) async {
      expect(find.textContaining('הדלקה 15 דק׳ לפני שקיעה'), findsOneWidget);
      expect(find.textContaining('הדלקה 40'), findsNothing);
      await tester.tap(find.byTooltip('עיר וזמני שבת'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'דקות הדלקת נרות לפני השקיעה'),
          findsNothing);
      await tester.tap(find.text('שמירה'));
      await tester.pumpAndSettle();
      expect(jsonDecode(requests.singleWhere((r) => r.method == 'PUT').body),
          settings);
    }, initialSettings: {...settings, 'candle_minutes': 40});
  });

  testWidgets(
      'mobile time zone list supports Hebrew search and persists choice',
      (tester) async {
    await withCalendar(tester, (requests) async {
      await tester.tap(find.byTooltip('עיר וזמני שבת'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'דקות הדלקת נרות לפני השקיעה'),
          findsNothing);
      await tester.tap(find.byKey(const ValueKey('calendar-timezone')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 330);
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(
          find.widgetWithText(TextField, 'חיפוש אזור זמן'), 'ברלין');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'ברלין · Europe/Berlin'),
          findsOneWidget);
      expect(find.widgetWithText(ListTile, 'לונדון · Europe/London'),
          findsNothing);
      await tester.tap(find.widgetWithText(ListTile, 'ברלין · Europe/Berlin'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('שמירה'));
      await tester.tap(find.text('שמירה'));
      await tester.pumpAndSettle();
      expect(jsonDecode(requests.singleWhere((r) => r.method == 'PUT').body),
          {...settings, 'timezone': 'Europe/Berlin'});
    }, size: const Size(390, 844));
  });

  testWidgets(
      'typed city preserves chosen time zone and ignores legacy city candle offset',
      (tester) async {
    const haifa = {
      'city': 'חיפה',
      'latitude': 32.794,
      'longitude': 34.9896,
      'timezone': 'Asia/Jerusalem',
      'israel': true,
      'candle_minutes': 30
    };
    await withCalendar(tester, (requests) async {
      await tester.tap(find.byTooltip('עיר וזמני שבת'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'עיר או יישוב'), 'חיפה');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      // Dismiss suggestions without choosing a city; save resolves the text.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'דקות הדלקת נרות לפני השקיעה'),
          findsNothing);
      await tester.tap(find.byKey(const ValueKey('calendar-timezone')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'חיפוש אזור זמן'), 'ברלין');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'ברלין · Europe/Berlin'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('שמירה'));
      await tester.pumpAndSettle();
      expect(jsonDecode(requests.singleWhere((r) => r.method == 'PUT').body),
          {...haifa, 'timezone': 'Europe/Berlin', 'candle_minutes': 15});
    }, respond: (r) {
      if (r.url.path == '/api/localities') return json([]);
      if (r.url.path.endsWith('/location')) return json({'settings': haifa});
      return null;
    });
  });

  testWidgets('unresolved city shows an error and cannot save old coordinates',
      (tester) async {
    await withCalendar(tester, (requests) async {
      await tester.tap(find.byTooltip('עיר וזמני שבת'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'עיר או יישוב'), 'עיר לא קיימת');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tester.tap(find.text('שמירה'));
      await tester.pumpAndSettle();
      expect(find.text('לא ניתן למצוא את העיר'), findsOneWidget);
      expect(find.text('מיקום וזמני שבת וחג'), findsOneWidget);
      expect(requests.where((r) => r.method == 'PUT'), isEmpty);
    }, respond: (r) {
      if (r.url.path == '/api/localities') return json([]);
      if (r.url.path.endsWith('/location')) {
        return http.Response(
            jsonEncode({'error': 'לא ניתן למצוא את העיר'}), 404,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return null;
    });
  });

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
