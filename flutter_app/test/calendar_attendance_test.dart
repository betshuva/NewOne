import 'package:betshuva/calendar_event_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'calendar_test.dart' as harness;

const _attendance = {
  'total': 12,
  'accepted': 8,
  'maybe': 1,
  'pending': 2,
  'declined': 1,
};
const _noAttendees = {
  'total': 0,
  'accepted': 0,
  'maybe': 0,
  'pending': 0,
  'declined': 0,
};

final _attendees = <Map<String, dynamic>>[
  for (var i = 1; i <= 8; i++)
    {'user_id': 'accepted-$i', 'name': 'אורח מאשר $i', 'response': 'accepted'},
  {'user_id': 'maybe', 'name': 'אורחת מתלבטת', 'response': 'maybe'},
  {'user_id': 'pending-1', 'name': 'אורח ממתין ראשון', 'response': 'pending'},
  {'user_id': 'pending-2', 'name': 'אורח ממתין שני', 'response': 'pending'},
  {'user_id': 'declined', 'name': 'אורחת שלא תגיע', 'response': 'declined'},
];

Map<String, dynamic> _event(String id, String title, String start, String end,
        {String? response, Map<String, int>? attendance = _attendance}) =>
    {
      ...harness.event(id, title, start, end, response: response),
      if (attendance != null) 'attendee_summary': attendance,
    };

Finder _summary(String id) => find.byWidgetPredicate(
    (widget) => widget is CalendarEventSummary && widget.event['id'] == id);

String _tooltip(WidgetTester tester, String id) {
  final tooltip = tester.widget<Tooltip>(
      find.descendant(of: _summary(id), matching: find.byType(Tooltip)));
  return tooltip.message ?? tooltip.richMessage!.toPlainText();
}

String _text(WidgetTester tester, Finder parent) => tester
    .widgetList<Text>(find.descendant(of: parent, matching: find.byType(Text)))
    .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
    .join('\n');

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Iterable<http.Request> _attendanceRequests(List<http.Request> requests) =>
    requests.where((request) => request.url.path.endsWith('/attendees'));

void main() {
  testWidgets(
      'owner sees attendance in each view and loads names only in event details',
      (tester) async {
    final event =
        _event('owner', 'ברית', '2026-09-18T10:00', '2026-09-18T11:00');
    await harness.withCalendar(tester, (requests) async {
      for (final view in ['חודש', 'שבוע', 'יום']) {
        await _tap(tester, find.text(view));
        expect(_summary('owner'), findsOneWidget);
        final tooltip = _tooltip(tester, 'owner');
        expect(tooltip, contains('ברית'));
        expect(tooltip, contains('10:00'));
        expect(tooltip, contains('11:00'));
        expect(tooltip, contains('8 מתוך 12 מוזמנים אישרו'));
        expect(tooltip, contains('משרד'));
        expect(_attendanceRequests(requests), isEmpty);
        expect(find.text('אורח מאשר 1'), findsNothing);
        expect(tester.takeException(), isNull);
      }

      expect(_text(tester, _summary('owner')),
          contains('8 מתוך 12 מוזמנים אישרו'));
      await _tap(tester, _summary('owner'));
      final details = find.byKey(const ValueKey('calendar-event-details'));
      expect(details, findsOneWidget);
      expect(_attendanceRequests(requests).single.url.path,
          '/api/calendar/events/owner/attendees');
      final detailText = _text(tester, details);
      expect(detailText, contains('8 מתוך 12 מוזמנים אישרו'));
      expect(
          tester
              .widget<Text>(
                  find.byKey(const ValueKey('calendar-attendance-breakdown')))
              .data,
          '8 אישרו · 1 אולי · 2 טרם ענו · 1 סירבו');
      expect(detailText, contains('משרד'));
      expect(detailText, contains('הערות לאירוע'));
      expect(detailText, contains('15 דקות לפני'));
      for (final attendee in _attendees) {
        expect(detailText, contains(attendee['name'] as String));
      }
      expect(detailText, contains('אורחת מתלבטת · אולי'));
      expect(detailText, contains('אורח ממתין ראשון · טרם ענה/תה'));
      expect(detailText, contains('אורחת שלא תגיע · סירב/ה'));
      expect(find.text('עריכה ומוזמנים'), findsOneWidget);
      await _tap(tester, find.text('סגירה'));
      expect(requests.where((request) => request.method != 'GET'), isEmpty);
    }, respond: (request) {
      if (request.url.path.endsWith('/events')) {
        return harness.json({
          'events': [event]
        });
      }
      if (request.url.path.endsWith('/attendees')) {
        return harness.json(_attendees);
      }
      return null;
    });
  });

  testWidgets('invitee sees only own RSVP and never loads attendee details',
      (tester) async {
    // Even if stale client data contains an aggregate, guest UI must hide it.
    final event = {
      ..._event('guest', 'אירוע שהוזמנתי אליו', '2026-09-18T10:00',
          '2026-09-18T11:00',
          response: 'accepted'),
      'attendees': _attendees,
    };
    await harness.withCalendar(tester, (requests) async {
      for (final view in ['חודש', 'שבוע', 'יום']) {
        await _tap(tester, find.text(view));
        final tooltip = _tooltip(tester, 'guest');
        expect(tooltip, contains('תשובתך'));
        expect(tooltip, isNot(contains('מוזמנים אישרו')));
        expect(
            _text(tester, _summary('guest')), isNot(contains('מוזמנים אישרו')));
        expect(_attendanceRequests(requests), isEmpty);
      }

      await _tap(tester, _summary('guest'));
      final detailText =
          _text(tester, find.byKey(const ValueKey('calendar-event-details')));
      expect(detailText, contains('תשובתך'));
      expect(detailText, isNot(contains('מוזמנים אישרו')));
      for (final attendee in _attendees) {
        expect(detailText, isNot(contains(attendee['name'] as String)));
      }
      expect(find.byType(CalendarEventAttendanceDetails), findsNothing);
      expect(find.text('עריכה ומוזמנים'), findsNothing);
      expect(_attendanceRequests(requests), isEmpty);
      await _tap(tester, find.text('סגירה'));
      expect(requests.where((request) => request.method != 'GET'), isEmpty);
    }, respond: (request) {
      if (request.url.path.endsWith('/events')) {
        return harness.json({
          'events': [event]
        });
      }
      if (request.url.path.endsWith('/attendees')) {
        return harness.json(_attendees);
      }
      return null;
    });
  });

  testWidgets(
      'short overlapping events and all-day attendance fit narrow calendar views',
      (tester) async {
    final events = [
      _event('brief', 'אירוע קצר עם כותרת ארוכה במיוחד', '2026-09-18T10:00',
          '2026-09-18T10:10'),
      _event('overlap', 'פגישה חופפת', '2026-09-18T10:00', '2026-09-18T11:00'),
      {
        ..._event('personal', 'משימה לכל היום', '2026-09-18T00:00',
            '2026-09-19T00:00',
            attendance: _noAttendees),
        'all_day': true,
      },
      {
        ..._event('unknown', 'אירוע ללא סיכום מוזמנים', '2026-09-18T00:00',
            '2026-09-19T00:00',
            attendance: null),
        'all_day': true,
      },
    ];
    await harness.withCalendar(
        tester,
        (requests) async {
          expect(tester.takeException(), isNull);
          for (final view in ['שבוע', 'יום']) {
            await _tap(tester, find.text(view));
            for (final id in ['brief', 'overlap', 'personal', 'unknown']) {
              expect(_summary(id), findsOneWidget);
            }
            final briefTooltip = _tooltip(tester, 'brief');
            expect(briefTooltip, contains('אירוע קצר עם כותרת ארוכה במיוחד'));
            expect(briefTooltip, contains('10:00'));
            expect(briefTooltip, contains('10:10'));
            expect(briefTooltip, contains('8 מתוך 12 מוזמנים אישרו'));
            expect(briefTooltip, contains('משרד'));
            expect(tester.getSize(_summary('brief')).height,
                lessThanOrEqualTo(22));
            expect(
                tester
                    .getRect(_summary('brief'))
                    .overlaps(tester.getRect(_summary('overlap'))),
                isFalse);
            expect(_tooltip(tester, 'personal'), contains('אירוע אישי'));
            expect(_tooltip(tester, 'personal'), contains('כל היום'));
            expect(_tooltip(tester, 'unknown'), isNot(contains('אירוע אישי')));
            expect(_attendanceRequests(requests), isEmpty);
            expect(tester.takeException(), isNull);
          }
          expect(requests.where((request) => request.method != 'GET'), isEmpty);
        },
        size: const Size(390, 844),
        respond: (request) {
          if (request.url.path.endsWith('/events')) {
            return harness.json({'events': events});
          }
          return null;
        });
  });
}
