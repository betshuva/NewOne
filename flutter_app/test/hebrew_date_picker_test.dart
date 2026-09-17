import 'dart:ui' show SemanticsAction, Tristate;

import 'package:betshuva/hebrew_date_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Finder _key(String value) => find.byKey(ValueKey(value));

class _PickerResult {
  DateTime? date;
  bool completed = false;
}

Future<_PickerResult> _openPicker(
  WidgetTester tester, {
  DateTime? initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
  Size size = const Size(600, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final result = _PickerResult();
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'NotoSansHebrew'),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const ValueKey('open-picker'),
            onPressed: () async {
              result.date = await showHebrewDatePicker(
                context: context,
                initialDate: initialDate ?? DateTime.utc(2026, 9, 18),
                firstDate: firstDate ?? DateTime.utc(2020, 1, 1),
                lastDate: lastDate ?? DateTime.utc(2100, 12, 31),
              );
              result.completed = true;
            },
            child: const Text('פתיחת הלוח'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(_key('open-picker'));
  await tester.pumpAndSettle();
  return result;
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.ensureVisible(_key('calendar-picker-confirm'));
  await tester.tap(_key('calendar-picker-confirm'));
  await tester.pumpAndSettle();
}

Future<void> _chooseDropdown(
  WidgetTester tester,
  String key,
  String label,
) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
  final choice = find.text(label).last;
  await tester.ensureVisible(choice);
  await tester.tap(choice);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Web test fonts are initialized with the first widget frame; awaiting a
    // manual FontLoader here would block that initialization.
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  testWidgets(
      'partial boundary months disable dates and clamp forward movement',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final result = await _openPicker(
        tester,
        firstDate: DateTime.utc(2026, 9, 16),
        lastDate: DateTime.utc(2026, 10, 15),
      );
      expect(
        tester.widget<IconButton>(_key('calendar-picker-prev')).onPressed,
        isNull,
      );
      expect(
        tester.widget<InkWell>(_key('calendar-picker-day-2026-09-15')).onTap,
        isNull,
      );
      expect(
        tester
            .getSemantics(_key('calendar-picker-day-semantics-2026-09-15'))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isFalse,
      );
      await tester.tap(_key('calendar-picker-next'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<IconButton>(_key('calendar-picker-next')).onPressed,
        isNull,
      );
      expect(
        tester.widget<InkWell>(_key('calendar-picker-day-2026-10-16')).onTap,
        isNull,
      );
      await _confirm(tester);
      expect(result.date, DateTime.utc(2026, 10, 15));
      expect(result.completed, isTrue);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
      'choosing the first partial month clamps to its first allowed day',
      (tester) async {
    final result = await _openPicker(
      tester,
      initialDate: DateTime.utc(2026, 10, 15),
      firstDate: DateTime.utc(2026, 9, 16),
      lastDate: DateTime.utc(2026, 10, 15),
    );
    final months = tester.widget<DropdownButton<int>>(
      _key('calendar-picker-month'),
    );
    expect(months.items!.map((item) => item.value), [7, 8]);
    await _chooseDropdown(tester, 'calendar-picker-month', 'תשרי');
    await _confirm(tester);
    expect(result.date, DateTime.utc(2026, 9, 16));
  });

  testWidgets('cancelling after month and day changes does not commit a date',
      (tester) async {
    final result = await _openPicker(tester);
    await tester.tap(_key('calendar-picker-next'));
    await tester.pumpAndSettle();
    await tester.tap(_key('calendar-picker-day-2026-10-20'));
    await tester.pumpAndSettle();
    expect(result.completed, isFalse);
    await tester.tap(_key('calendar-picker-cancel'));
    await tester.pumpAndSettle();
    expect(result.completed, isTrue);
    expect(result.date, isNull);
    expect(_key('calendar-hebrew-date-picker'), findsNothing);
  });

  testWidgets('a narrow short viewport scrolls to days and confirmation',
      (tester) async {
    final result = await _openPicker(
      tester,
      size: const Size(320, 360),
    );
    expect(tester.takeException(), isNull);
    final selected = _key('calendar-picker-day-2026-09-25');
    await tester.ensureVisible(selected);
    await tester.tap(selected);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _confirm(tester);
    expect(result.date, DateTime.utc(2026, 9, 25));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Hebrew dropdowns preserve the day from Adar II into a common year',
      (tester) async {
    final result = await _openPicker(
      tester,
      initialDate: DateTime.utc(2024, 2, 10),
    );
    expect(find.text('חודש עברי'), findsOneWidget);
    expect(find.text('שנה עברית'), findsOneWidget);
    await _chooseDropdown(tester, 'calendar-picker-month', 'אדר ב׳');
    expect(find.text('11/3/2024'), findsOneWidget);
    await _chooseDropdown(tester, 'calendar-picker-year', 'תשפ״ה');
    final months = tester.widget<DropdownButton<int>>(
      _key('calendar-picker-month'),
    );
    expect(months.value, 12);
    expect(months.items!.map((item) => item.value), isNot(contains(13)));
    expect(find.text('1/3/2025'), findsOneWidget);
    expect(result.completed, isFalse);
    await _confirm(tester);
    expect(result.date, DateTime.utc(2025, 3, 1));
  });

  testWidgets('moving from day 30 of Adar I clamps to day 29 of Adar II',
      (tester) async {
    final result = await _openPicker(
      tester,
      initialDate: DateTime.utc(2024, 3, 10),
    );
    await tester.tap(_key('calendar-picker-next'));
    await tester.pumpAndSettle();
    await _confirm(tester);
    expect(result.date, DateTime.utc(2024, 4, 8));
  });

  testWidgets('the right arrow goes back one Hebrew month in RTL',
      (tester) async {
    final result = await _openPicker(tester);
    final previous = _key('calendar-picker-prev');
    final next = _key('calendar-picker-next');
    expect(
        tester.getCenter(previous).dx, greaterThan(tester.getCenter(next).dx));
    final previousIcon = tester.widget<Icon>(
      find.descendant(of: previous, matching: find.byType(Icon)),
    );
    final nextIcon = tester.widget<Icon>(
      find.descendant(of: next, matching: find.byType(Icon)),
    );
    expect(previousIcon.icon, Icons.chevron_right);
    expect(previousIcon.textDirection, TextDirection.ltr);
    expect(nextIcon.icon, Icons.chevron_left);
    expect(nextIcon.textDirection, TextDirection.ltr);
    await tester.tap(previous);
    await tester.pumpAndSettle();
    await _confirm(tester);
    expect(result.date, DateTime.utc(2026, 8, 20));
  });

  testWidgets('screen readers can activate days and hear their selected state',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final result = await _openPicker(tester);
      final original = _key('calendar-picker-day-semantics-2026-09-18');
      final target = _key('calendar-picker-day-semantics-2026-09-19');
      expect(
        tester
            .getSemantics(original)
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      final node = tester.getSemantics(target);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(node.getSemanticsData().label, startsWith('ח׳ בתשרי תשפ״ז'));
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(
        tester
            .getSemantics(original)
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isFalse,
      );
      expect(
        tester
            .getSemantics(target)
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      await _confirm(tester);
      expect(result.date, DateTime.utc(2026, 9, 19));
    } finally {
      semantics.dispose();
    }
  });
}
