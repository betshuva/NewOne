import 'dart:async';
import 'dart:convert';

import 'package:betshuva/location_autocomplete.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response cities(List<String> names) =>
    http.Response(jsonEncode(names.map((city) => {'city': city}).toList()), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> showPicker(WidgetTester tester, TextEditingController controller,
        {ValueChanged<String>? onChanged,
        ValueChanged<String>? onSelected,
        bool citiesOnly = true}) =>
    tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LocationAutocompleteField(
                controller: controller,
                api: 'https://example.test/api',
                citiesOnly: citiesOnly,
                onChanged: onChanged,
                onSelected: onSelected))));

void main() {
  testWidgets('remote suggestions appear and only selection resolves a city',
      (tester) async {
    final controller = TextEditingController();
    final changed = <String>[];
    final selected = <String>[];
    await http.runWithClient(() async {
      await showPicker(tester, controller,
          onChanged: changed.add, onSelected: selected.add);
      await tester.enterText(find.byType(TextField), 'מצפה');
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      expect(find.text('מצפה רמון'), findsOneWidget);
      expect(changed, ['מצפה']);
      expect(selected, isEmpty);
      await tester.tap(find.text('מצפה רמון'));
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      expect(controller.text, 'מצפה רמון');
      expect(selected, ['מצפה רמון']);
      await tester.pumpWidget(const SizedBox());
    }, () => MockClient((request) async => cities(['מצפה רמון'])));
    controller.dispose();
  });

  testWidgets('older responses cannot replace a newer city search',
      (tester) async {
    final controller = TextEditingController();
    final first = Completer<http.Response>();
    final second = Completer<http.Response>();
    await http.runWithClient(() async {
      await showPicker(tester, controller);
      await tester.enterText(find.byType(TextField), 'מצ');
      await tester.pump(const Duration(milliseconds: 220));
      await tester.enterText(find.byType(TextField), 'קצ');
      await tester.pump(const Duration(milliseconds: 220));
      second.complete(cities(['קצרין']));
      await tester.pumpAndSettle();
      expect(find.text('קצרין'), findsOneWidget);
      first.complete(cities(['מצפה רמון']));
      await tester.pumpAndSettle();
      expect(find.text('קצרין'), findsOneWidget);
      expect(find.text('מצפה רמון'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((request) => request.url.queryParameters['q'] == 'מצ'
            ? first.future
            : second.future));
    controller.dispose();
  });

  testWidgets('calendar suggestions exclude regions and keep offline cities',
      (tester) async {
    final controller = TextEditingController();
    await http.runWithClient(() async {
      await showPicker(tester, controller);
      await tester.enterText(find.byType(TextField), 'ירושלים');
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      expect(find.text('ירושלים'), findsNWidgets(2));
      expect(find.text('אזור ירושלים'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }, () => MockClient((request) async => http.Response('', 503)));
    controller.dispose();
  });

  testWidgets('Azor remains a city while regional options are excluded',
      (tester) async {
    final controller = TextEditingController();
    final selected = <String>[];
    await http.runWithClient(() async {
      await showPicker(tester, controller, onSelected: selected.add);
      await tester.enterText(find.byType(TextField), 'אזור');
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'אזור'), findsOneWidget);
      expect(find.text('אזור המרכז'), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, 'אזור'));
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      expect(selected, ['אזור']);
      await tester.pumpWidget(const SizedBox());
    }, () => MockClient((request) async => cities(['אזור', 'אזור המרכז'])));
    controller.dispose();
  });

  testWidgets('server spelling variants remain selectable', (tester) async {
    final controller = TextEditingController();
    final selected = <String>[];
    await http.runWithClient(() async {
      await showPicker(tester, controller, onSelected: selected.add);
      await tester.enterText(find.byType(TextField), 'קרית');
      await tester.pump(const Duration(milliseconds: 220));
      await tester.pumpAndSettle();
      expect(find.text('קריית גת'), findsOneWidget);
      await tester.tap(find.text('קריית גת'));
      await tester.pumpAndSettle(const Duration(milliseconds: 250));
      expect(controller.text, 'קריית גת');
      expect(selected, ['קריית גת']);
      await tester.pumpWidget(const SizedBox());
    }, () => MockClient((request) async => cities(['קריית גת'])));
    controller.dispose();
  });
}
