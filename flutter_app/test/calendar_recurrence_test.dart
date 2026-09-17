import 'dart:convert';

import 'package:betshuva/calendar_event_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'calendar_test.dart' as harness;

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String field, String option) async {
  await _tap(tester, _key(field));
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

Future<void> _newEvent(WidgetTester tester) async {
  await _tap(tester, find.text('אירוע חדש'));
  await tester.enterText(
      find.widgetWithText(TextField, 'שם האירוע'), 'אירוע חוזר');
}

String _summary(WidgetTester tester) =>
    tester.widget<Text>(_key('calendar-repeat-summary')).data!;

Map<String, dynamic> _sent(List<http.Request> requests,
        {String method = 'POST'}) =>
    jsonDecode(requests.singleWhere((r) => r.method == method).body)
        as Map<String, dynamic>;

void main() {
  testWidgets('daily interval and total count are saved with a live summary',
      (tester) async {
    await harness.withCalendar(tester, (requests) async {
      await _newEvent(tester);
      await _choose(tester, 'calendar-repeat', 'יומי');
      await _choose(tester, 'calendar-repeat-interval', 'כל 3 ימים');
      await tester.enterText(_key('calendar-repeat-count'), '6');
      await tester.pump();
      expect(_summary(tester), contains('כל 3 ימים'));
      expect(_summary(tester), contains('09:00'));
      expect(_summary(tester), contains('6 מופעים בסך הכול'));
      await _tap(tester, find.text('שמירה'));
      final sent = _sent(requests);
      expect(sent['repeat'], 'daily');
      expect(sent['interval'], 3);
      expect(sent['end_type'], 'count');
      expect(sent['count'], 6);
      expect(sent.containsKey('until'), isFalse);
      expect(sent.containsKey('weekdays'), isFalse);
      expect(sent['start'], '2026-09-18T09:00');
      expect(sent['timezone'], 'Asia/Jerusalem');
    });
  });

  testWidgets('weekly Hebrew day buttons send ISO days and fit a narrow dialog',
      (tester) async {
    await harness.withCalendar(tester, (requests) async {
      await _newEvent(tester);
      await _choose(tester, 'calendar-repeat', 'שבועי');
      expect(
          tester.widget<FilterChip>(_key('calendar-repeat-weekday-5')).selected,
          isTrue,
          reason: 'The initial date is Friday.');
      await _tap(tester, _key('calendar-repeat-weekday-5'));
      await _tap(tester, _key('calendar-repeat-weekday-7'));
      await _tap(tester, _key('calendar-repeat-weekday-2'));
      expect(_summary(tester), contains('ראשון, שלישי'));
      expect(_summary(tester), contains('החל מ־20/9/2026'));
      expect(_summary(tester), contains('09:00'));
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('שמירה'));
      final sent = _sent(requests);
      expect(sent['repeat'], 'weekly');
      expect(sent['weekdays'], [2, 7]);
      expect(sent['count'], 4);
      expect(sent.containsKey('interval'), isFalse);
    }, size: const Size(320, 844));
  });

  testWidgets('monthly until date uses Hebrew picker and inclusive API date',
      (tester) async {
    await harness.withCalendar(tester, (requests) async {
      await _newEvent(tester);
      await _choose(tester, 'calendar-repeat', 'כל חודש (לועזי)');
      expect(find.textContaining('בחודש קצר יותר'), findsOneWidget);
      await _choose(tester, 'calendar-repeat-end', 'בתאריך');
      await _tap(tester, _key('calendar-repeat-until'));
      expect(_key('calendar-hebrew-date-picker'), findsOneWidget);
      await _tap(tester, _key('calendar-picker-day-2026-10-18'));
      await _tap(tester, _key('calendar-picker-confirm'));
      expect(_summary(tester), contains('בכל חודש לועזי בתאריך 18'));
      expect(_summary(tester), contains('18/10/2026'));
      expect(_summary(tester), contains('כולל יום זה'));
      expect(find.text('ניתן ליצור עד 104 מופעים בכל סדרה.'), findsOneWidget);
      await _tap(tester, find.text('שמירה'));
      final sent = _sent(requests);
      expect(sent['repeat'], 'monthly');
      expect(sent['end_type'], 'until');
      expect(sent['until'], '2026-10-18');
      expect(sent.containsKey('count'), isFalse);
      expect(sent.containsKey('weekdays'), isFalse);
    });
  });

  testWidgets('count outside 1 to 104 cannot create a series', (tester) async {
    await harness.withCalendar(tester, (requests) async {
      await _newEvent(tester);
      await _choose(tester, 'calendar-repeat', 'יומי');
      for (final invalid in ['0', '105', '1.5', '']) {
        await tester.ensureVisible(_key('calendar-repeat-count'));
        await tester.enterText(_key('calendar-repeat-count'), invalid);
        await _tap(tester, find.text('שמירה'));
        expect(find.text('יש להזין מספר מופעים בין 1 ל־104'), findsOneWidget);
        expect(requests.where((r) => r.method == 'POST'), isEmpty);
      }
      await tester.ensureVisible(_key('calendar-repeat-count'));
      await tester.enterText(_key('calendar-repeat-count'), '104');
      await _choose(tester, 'calendar-repeat-interval', 'כל 7 ימים');
      await _tap(tester, find.text('שמירה'));
      expect(_sent(requests)['count'], 104);
      expect(_sent(requests)['interval'], 7);
    });
  });

  testWidgets('weekly series requires a day and all-day summary stays correct',
      (tester) async {
    await harness.withCalendar(tester, (requests) async {
      await _newEvent(tester);
      await _tap(tester, find.byType(SwitchListTile));
      await _choose(tester, 'calendar-repeat', 'שבועי');
      await _tap(tester, _key('calendar-repeat-weekday-5'));
      await _tap(tester, find.text('שמירה'));
      expect(find.text('יש לבחור לפחות יום אחד בשבוע'), findsOneWidget);
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
      await _tap(tester, _key('calendar-repeat-weekday-6'));
      expect(_summary(tester), contains('שבת'));
      expect(_summary(tester), contains('כל היום'));
      expect(_summary(tester), isNot(contains('09:00')));
      await _tap(tester, find.text('שמירה'));
      expect(_sent(requests)['all_day'], isTrue);
      expect(_sent(requests)['weekdays'], [6]);
      expect(_sent(requests)['start'], '2026-09-18T00:00');
    });
  });

  for (final wholeSeries in [false, true]) {
    testWidgets(
        'series editor sends ${wholeSeries ? 'series' : 'single'} scope',
        (tester) async {
      final existing = {
        ...harness.event(
            'recurring', 'סדרת פגישות', '2026-09-18T09:00', '2026-09-18T10:00'),
        'series_id': 'series-id',
        'series_revision': 'opaque-series-revision',
      };
      await harness.withCalendar(tester, (requests) async {
        await _tap(
            tester,
            find.byWidgetPredicate((w) =>
                w is CalendarEventSummary && w.event['id'] == 'recurring'));
        await _tap(tester, find.text('עריכה ומוזמנים'));
        expect(_key('calendar-repeat'), findsNothing);
        await tester.enterText(
            find.widgetWithText(TextField, 'שם האירוע'), 'כותרת מעודכנת');
        if (wholeSeries) {
          await _choose(tester, 'calendar-edit-scope', 'כל הסדרה');
          expect(find.textContaining('בכל המופעים שלא בוטלו'), findsOneWidget);
        } else {
          expect(find.text('השינויים יישמרו במופע זה בלבד.'), findsOneWidget);
        }
        await _tap(tester, find.text('שמירה'));
        final sent = _sent(requests, method: 'PUT');
        expect(sent['scope'], wholeSeries ? 'series' : 'single');
        expect(sent['version'], 1);
        expect(sent['title'], 'כותרת מעודכנת');
        expect(sent['repeat'], 'none');
        if (wholeSeries) {
          expect(sent['series_revision'], 'opaque-series-revision');
        } else {
          expect(sent.containsKey('series_revision'), isFalse);
        }
        expect(sent.containsKey('end_type'), isFalse);
        expect(sent.containsKey('until'), isFalse);
      }, respond: (request) {
        if (request.url.path.endsWith('/events')) {
          return harness.json({
            'events': [existing]
          });
        }
        if (request.url.path.endsWith('/attendees')) return harness.json([]);
        return null;
      });
    });
  }
}
