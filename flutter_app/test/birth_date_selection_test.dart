import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:betshuva/birth_date_selection.dart';

Finder field(String name) =>
    find.widgetWithText(DropdownButtonFormField<int>, name);
Future<void> select(WidgetTester tester, String name, int value) async {
  tester.widget<DropdownButtonFormField<int>>(field(name)).onChanged!(value);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('separate RTL selections have no text input, slash or calendar',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 300,
                child: BirthDateSelection(value: null, onChanged: (_) {})))));
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(DropdownButtonFormField<int>), findsNWidgets(3));
    expect(find.textContaining('/'), findsNothing);
    expect(tester.getCenter(field('יום')).dx,
        greaterThan(tester.getCenter(field('חודש')).dx));
    await tester.tap(field('יום'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3').last);
    await tester.pumpAndSettle();
    expect(
        tester.widget<DropdownButtonFormField<int>>(field('יום')).initialValue,
        3);
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'partial selections persist through parent rebuild and produce a date',
      (tester) async {
    DateTime? result;
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
                body: BirthDateSelection(
                    value: result,
                    onChanged: (value) => setState(() => result = value))))));
    await select(tester, 'יום', 15);
    expect(result, isNull);
    await select(tester, 'חודש', 6);
    expect(result, isNull);
    await select(tester, 'שנה', 1985);
    expect(result, DateTime(1985, 6, 15));
  });
  testWidgets(
      'month and leap year changes invalidate a previously selected day',
      (tester) async {
    DateTime? result = DateTime(1984, 1, 31);
    await tester.pumpWidget(MaterialApp(
        home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
                body: BirthDateSelection(
                    value: result,
                    onChanged: (value) => setState(() => result = value))))));
    await select(tester, 'חודש', 2);
    expect(result, isNull);
    expect(
        tester
            .widget<DropdownButton<int>>(find.descendant(
                of: field('יום'), matching: find.byType(DropdownButton<int>)))
            .items!
            .length,
        29);
    await select(tester, 'יום', 29);
    expect(result, DateTime(1984, 2, 29));
    await select(tester, 'שנה', 1985);
    expect(result, isNull);
    expect(
        tester.widget<DropdownButtonFormField<int>>(field('יום')).initialValue,
        isNull);
    expect(
        tester
            .widget<DropdownButton<int>>(find.descendant(
                of: field('יום'), matching: find.byType(DropdownButton<int>)))
            .items!
            .length,
        28);
  });
  testWidgets(
      'eighteen year boundary is enforced and younger years are not offered',
      (tester) async {
    final now = DateTime.now();
    DateTime? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BirthDateSelection(
                value: null, onChanged: (v) => result = v))));
    final years = tester
        .widget<DropdownButton<int>>(find.descendant(
            of: field('שנה'), matching: find.byType(DropdownButton<int>)))
        .items!
        .map((v) => v.value!)
        .toList();
    expect(years.first, now.year - 18);
    expect(years.last, now.year - 120);
    await select(tester, 'שנה', now.year - 18);
    await select(tester, 'חודש', now.month);
    final lastDay = DateTime(now.year - 18, now.month + 1, 0).day;
    await select(tester, 'יום', now.day > lastDay ? lastDay : now.day);
    expect(result, isNotNull);
    if (now.day < lastDay) {
      await select(tester, 'יום', now.day + 1);
      expect(result, isNull);
      expect(find.text('ניתן להירשם מגיל 18 ומעלה בלבד'), findsOneWidget);
    }
  });
  testWidgets('parent reset clears date and disabled fields cannot change',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BirthDateSelection(
                value: DateTime(1985, 6, 15),
                enabled: false,
                onChanged: (_) => fail('disabled')))));
    for (final f in tester.widgetList<DropdownButtonFormField<int>>(
        find.byType(DropdownButtonFormField<int>))) {
      expect(f.onChanged, isNull);
    }
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BirthDateSelection(value: null, onChanged: (_) {}))));
    for (final f in tester.widgetList<DropdownButtonFormField<int>>(
        find.byType(DropdownButtonFormField<int>))) {
      expect(f.initialValue, isNull);
    }
  });
}
