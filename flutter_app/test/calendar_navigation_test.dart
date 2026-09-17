import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'calendar_test.dart' as harness;

Finder _key(String key) => find.byKey(ValueKey(key));

bool _selected(WidgetTester tester, Finder target) {
  final widget = tester.widget(target);
  if (widget is Semantics && widget.properties.selected != null) {
    return widget.properties.selected!;
  }
  return tester
      .widgetList<Semantics>(
          find.ancestor(of: target, matching: find.byType(Semantics)))
      .firstWhere((widget) => widget.properties.selected != null)
      .properties
      .selected!;
}

Color? _background(WidgetTester tester, Finder target) {
  Color? colorOf(Widget widget) {
    if (widget is ColoredBox) return widget.color;
    if (widget is Container) {
      final decoration = widget.decoration;
      return widget.color ??
          (decoration is BoxDecoration ? decoration.color : null);
    }
    return null;
  }

  return colorOf(tester.widget(target)) ??
      tester
          .widgetList(find.descendant(
              of: target,
              matching:
                  find.byWidgetPredicate((widget) => colorOf(widget) != null)))
          .map(colorOf)
          .first;
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('month arrows navigate Hebrew months across Rosh Hashanah',
      (tester) async {
    await harness.withCalendar(tester, (requests) async {
      await _tap(tester, find.text('חודש'));
      void expectRange(String start, String end) {
        final request = requests.lastWhere((request) =>
            request.method == 'GET' && request.url.path.endsWith('/events'));
        expect(request.url.queryParameters['start'], start);
        expect(request.url.queryParameters['end'], end);
      }

      expect(find.text('תשרי תשפ״ז'), findsOneWidget);
      expectRange('2026-09-06', '2026-10-18');

      await _tap(tester, find.byTooltip('הקודם'));
      expect(find.text('אלול תשפ״ו'), findsOneWidget);
      expectRange('2026-08-09', '2026-09-20');

      await _tap(tester, find.byTooltip('הבא'));
      expect(find.text('תשרי תשפ״ז'), findsOneWidget);
      expectRange('2026-09-06', '2026-10-18');

      await _tap(tester, find.byTooltip('הבא'));
      expect(find.text('חשוון תשפ״ז'), findsOneWidget);
      expectRange('2026-10-11', '2026-11-22');
      expect(requests.where((request) => request.method != 'GET'), isEmpty);
    });
  });

  testWidgets('navigation arrows keep their intended physical direction in RTL',
      (tester) async {
    await harness.withCalendar(tester, (requests) async {
      final previous = find.byTooltip('הקודם');
      final next = find.byTooltip('הבא');
      final previousIcon = tester.widget<Icon>(
          find.descendant(of: previous, matching: find.byType(Icon)));
      final nextIcon = tester
          .widget<Icon>(find.descendant(of: next, matching: find.byType(Icon)));

      expect(previousIcon.icon, Icons.chevron_right);
      expect(previousIcon.textDirection, TextDirection.ltr);
      expect(nextIcon.icon, Icons.chevron_left);
      expect(nextIcon.textDirection, TextDirection.ltr);
      final dateCenter = tester.getCenter(_key('calendar-date-picker')).dx;
      expect(tester.getCenter(previous).dx, greaterThan(dateCenter));
      expect(tester.getCenter(next).dx, lessThan(dateCenter));
    });
  });

  testWidgets('chosen day stays marked in month, week and day views',
      (tester) async {
    await harness.withCalendar(tester, (requests) async {
      await _tap(tester, find.text('חודש'));
      expect(_selected(tester, _key('calendar-month-day-2026-09-18')), isTrue);
      await _tap(tester, _key('calendar-month-day-2026-09-16'));

      expect(_selected(tester, _key('calendar-header-2026-09-16')), isTrue);
      final selectedColumn =
          _background(tester, _key('calendar-column-2026-09-16'));
      expect(selectedColumn, isNotNull);
      expect(selectedColumn, isNot(Colors.transparent));

      await _tap(tester, find.text('שבוע'));
      expect(_selected(tester, _key('calendar-header-2026-09-16')), isTrue);
      expect(_selected(tester, _key('calendar-header-2026-09-17')), isFalse);
      expect(_background(tester, _key('calendar-column-2026-09-16')),
          selectedColumn);
      expect(_background(tester, _key('calendar-column-2026-09-17')),
          isNot(selectedColumn));

      await _tap(tester, find.text('חודש'));
      expect(_selected(tester, _key('calendar-month-day-2026-09-16')), isTrue);
      expect(_selected(tester, _key('calendar-month-day-2026-09-18')), isFalse);
      expect(_background(tester, _key('calendar-month-day-2026-09-16')),
          isNot(_background(tester, _key('calendar-month-day-2026-09-17'))));
      expect(_background(tester, _key('calendar-month-day-2026-09-16')),
          isNot(_background(tester, _key('calendar-month-day-2026-09-18'))));

      await _tap(tester, find.text('היום'));
      expect(_selected(tester, _key('calendar-month-day-2026-09-18')), isTrue);
      expect(_selected(tester, _key('calendar-month-day-2026-09-16')), isFalse);
    });
  });

  testWidgets('choosing a week header selects the day used for a new event',
      (tester) async {
    await harness.withCalendar(tester, (requests) async {
      await _tap(tester, find.text('שבוע'));
      await _tap(tester, _key('calendar-header-2026-09-17'));

      final views = tester.widget<SegmentedButton<String>>(
          find.byType(SegmentedButton<String>));
      expect(views.selected, {'week'});
      expect(_selected(tester, _key('calendar-header-2026-09-17')), isTrue);
      expect(_selected(tester, _key('calendar-header-2026-09-18')), isFalse);

      await _tap(tester, find.text('אירוע חדש'));
      await tester.enterText(
          find.widgetWithText(TextField, 'שם האירוע'), 'אירוע ביום שנבחר');
      await _tap(tester, find.text('שמירה'));

      final request = requests.singleWhere((request) =>
          request.method == 'POST' && request.url.path.endsWith('/events'));
      final saved = jsonDecode(request.body) as Map<String, dynamic>;
      expect(saved['start'], '2026-09-17T09:00');
      expect(saved['end'], '2026-09-17T10:00');
      expect(saved['timezone'], 'Asia/Jerusalem');
    });
  });

  testWidgets('Hebrew year and leap months can be chosen on a narrow screen',
      (tester) async {
    await harness.withCalendar(tester, (requests) async {
      await _tap(tester, find.text('חודש'));
      await _tap(tester, _key('calendar-date-picker'));
      await _tap(tester, _key('calendar-picker-year'));
      await _tap(tester, find.text('תשפ״ד').last);
      await _tap(tester, _key('calendar-picker-month'));
      expect(find.text('אדר א׳'), findsWidgets);
      expect(find.text('אדר ב׳'), findsWidgets);
      await _tap(tester, find.text('אדר א׳').last);
      await _tap(tester, _key('calendar-picker-day-2024-02-10'));
      await _tap(tester, find.text('אישור'));

      expect(find.text('אדר א׳ תשפ״ד'), findsOneWidget);
      expect(_selected(tester, _key('calendar-month-day-2024-02-10')), isTrue);
      final request = requests.lastWhere((request) =>
          request.method == 'GET' && request.url.path.endsWith('/events'));
      expect(request.url.queryParameters['start'], '2024-02-04');
      expect(request.url.queryParameters['end'], '2024-03-17');

      await _tap(tester, find.byTooltip('הבא'));
      expect(find.text('אדר ב׳ תשפ״ד'), findsOneWidget);
      await _tap(tester, find.byTooltip('הבא'));
      expect(find.text('ניסן תשפ״ד'), findsOneWidget);
    }, size: const Size(390, 844));
  });

  testWidgets('long Hebrew dates fit day and week controls at 320 pixels',
      (tester) async {
    await harness.withCalendar(
        tester,
        (requests) async {
          expect(tester.takeException(), isNull);
          for (final view in ['יום', 'שבוע']) {
            await _tap(tester, find.text(view));
            expect(
                find.descendant(
                    of: _key('calendar-date-picker'),
                    matching: find.text('כ״ח באדר א׳ תשפ״ד')),
                findsOneWidget);
            for (final control in [
              find.byTooltip('הקודם'),
              _key('calendar-date-picker'),
              find.byTooltip('הבא'),
              find.text('היום'),
            ]) {
              final rect = tester.getRect(control);
              expect(rect.left, greaterThanOrEqualTo(0));
              expect(rect.right, lessThanOrEqualTo(320));
            }
            expect(tester.takeException(), isNull);
          }
        },
        size: const Size(320, 844),
        respond: (request) {
          if (request.url.path.endsWith('/settings')) {
            return harness.json({
              'settings': harness.settings,
              'configured': true,
              'source': 'saved',
              'location_allowed': false,
              'cities': [harness.settings],
              'timezones': ['Asia/Jerusalem'],
              'today': '2024-03-08',
            });
          }
          return null;
        });
  });
}
