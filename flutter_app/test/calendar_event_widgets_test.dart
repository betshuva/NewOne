import 'dart:async';

import 'package:betshuva/calendar_event_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> event({Object? summary, String? response}) => {
      'id': 'event',
      'owner_id': 'owner',
      'title': 'ברית',
      'start_local': '2026-09-18T10:00',
      'end_local': '2026-09-18T11:00',
      'all_day': false,
      'response': response,
      'location': 'אולם ירושלים',
      'notes': 'כניסה מצד ימין',
      'reminder_minutes': 15,
      if (summary != null) 'attendee_summary': summary,
    };

const counts = {
  'total': 12,
  'accepted': 8,
  'maybe': 1,
  'pending': 2,
  'declined': 1,
};

Widget app(Widget child, {double scale = 1}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    );

String tooltip(WidgetTester tester) =>
    tester.widget<Tooltip>(find.byType(Tooltip).first).message!;

void main() {
  testWidgets('bounded event shows time, owner counts and location',
      (tester) async {
    await tester.pumpWidget(app(SizedBox(
      width: 280,
      height: 70,
      child: CalendarEventSummary(
          event: event(summary: counts), color: Colors.blue),
    )));
    expect(find.text('ברית · \u206610:00–11:00\u2069'), findsOneWidget);
    expect(find.text('8 מתוך 12 מוזמנים אישרו'), findsOneWidget);
    expect(find.text('מקום: אולם ירושלים'), findsOneWidget);
    expect(tooltip(tester), contains('8 אישרו · 1 אולי · 2 טרם ענו · 1 סירבו'));
    expect(tooltip(tester), contains('כניסה מצד ימין'));
    expect(tooltip(tester), contains('תזכורת: 15 דקות לפני'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tiny overlap cards and scaled chips keep their bounds',
      (tester) async {
    for (final scale in [1.0, 2.5]) {
      for (final width in [5.0, 45.0, 280.0]) {
        for (final compact in [false, true]) {
          await tester.pumpWidget(app(
              SizedBox(
                width: width,
                height: 14,
                child: CalendarEventSummary(
                  event: event(summary: counts),
                  color: Colors.blue,
                  compact: compact,
                ),
              ),
              scale: scale));
          expect(tester.takeException(), isNull,
              reason: '$scale/$width/$compact');
          expect(tester.getSize(find.byType(CalendarEventSummary)),
              Size(width, 14));
          expect(find.byKey(const ValueKey('calendar-event-extra-0')),
              findsNothing);
          expect(tooltip(tester), contains('8 מתוך 12 מוזמנים אישרו'));
        }
      }
    }
  });

  testWidgets('compact chip stays one line when vertical space is available',
      (tester) async {
    await tester.pumpWidget(app(SizedBox(
      width: 600,
      height: 90,
      child: CalendarEventSummary(
          event: event(summary: counts), color: Colors.blue, compact: true),
    )));
    expect(find.text('ברית · \u206610:00–11:00\u2069 · 8 מתוך 12 אישרו'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-event-extra-0')), findsNothing);
  });

  testWidgets('unknown aggregate is not a personal event; known zero is',
      (tester) async {
    for (final summary in [
      null,
      {'total': 0}
    ]) {
      await tester.pumpWidget(app(SizedBox(
        width: 300,
        height: 70,
        child: CalendarEventSummary(
            event: event(summary: summary), color: Colors.blue),
      )));
      expect(tooltip(tester).contains('אירוע אישי'), summary != null);
      expect(tooltip(tester), isNot(contains('0 מתוך')));
    }
  });

  testWidgets('tooltip keeps long notes to a readable preview', (tester) async {
    final notes = List.filled(60, 'פרט חשוב ').join();
    await tester.pumpWidget(app(SizedBox(
      width: 300,
      height: 70,
      child: CalendarEventSummary(
        event: {...event(summary: counts), 'notes': notes},
        color: Colors.blue,
      ),
    )));
    final description = tooltip(tester);
    expect(description, contains('${notes.substring(0, 200)}…'));
    expect(description, isNot(contains(notes)));
    expect(description.length, lessThan(450));
    expect(description, contains('8 מתוך 12 מוזמנים אישרו'));
  });

  testWidgets('guest summary never exposes supplied owner counts',
      (tester) async {
    await tester.pumpWidget(app(SizedBox(
      width: 300,
      height: 70,
      child: CalendarEventSummary(
          event: event(summary: counts, response: 'maybe'), color: Colors.blue),
    )));
    expect(find.text('תשובתך: אולי'), findsOneWidget);
    expect(tooltip(tester), isNot(contains('מוזמנים')));
    expect(tooltip(tester), isNot(contains('8')));
  });

  testWidgets('owner details replace cached counts and exclude the owner',
      (tester) async {
    final loaded = Completer<List<Map<String, dynamic>>>();
    var requests = 0;
    final details = CalendarEventAttendanceDetails(
      event: event(summary: counts),
      loadAttendees: () {
        requests++;
        return loaded.future;
      },
    );
    await tester.pumpWidget(app(details));
    expect(find.text('8 מתוך 12 מוזמנים אישרו'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    loaded.complete([
      {'user_id': 'owner', 'name': 'בעל האירוע', 'response': 'accepted'},
      {'user_id': 'a', 'name': 'שרה', 'response': 'accepted'},
      {'user_id': 'b', 'name': 'דוד', 'response': 'pending'},
      {'user_id': 'c', 'name': 'רות', 'response': 'maybe'},
      {'user_id': 'd', 'name': 'דן', 'response': 'declined'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('1 מתוך 4 מוזמנים אישרו'), findsOneWidget);
    expect(find.text('8 מתוך 12 מוזמנים אישרו'), findsNothing);
    expect(find.text('1 אישרו · 1 אולי · 1 טרם ענו · 1 סירבו'), findsOneWidget);
    expect(find.text('שרה · אישר/ה'), findsOneWidget);
    expect(find.textContaining('בעל האירוע'), findsNothing);
    await tester.pumpWidget(app(details));
    expect(requests, 1);
  });

  testWidgets('failed details keep unknown attendance and retry successfully',
      (tester) async {
    var requests = 0;
    await tester.pumpWidget(app(CalendarEventAttendanceDetails(
      event: event(),
      loadAttendees: () async {
        if (++requests == 1) throw StateError('network unavailable');
        return [];
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('לא ניתן לטעון את תשובות המוזמנים.'), findsOneWidget);
    expect(find.text('אירוע אישי'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('calendar-attendance-retry')));
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.text('אירוע אישי'), findsOneWidget);
    expect(find.text('לא ניתן לטעון את תשובות המוזמנים.'), findsNothing);
  });

  testWidgets('guest details never fetch invitees or show owner counts',
      (tester) async {
    var requests = 0;
    await tester.pumpWidget(app(CalendarEventAttendanceDetails(
      event: event(summary: counts, response: 'accepted'),
      loadAttendees: () async {
        requests++;
        return [];
      },
    )));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.text('תשובתך: אישור'), findsOneWidget);
    expect(find.textContaining('מוזמנים'), findsNothing);
  });
}
