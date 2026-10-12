import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = <String, dynamic>{
  'id': 'layout-test-user',
  'city': 'רחובות',
};
const _scrollKey = ValueKey('listing-form-scroll');
const _draftKey = ValueKey('listing-save-draft');
const _publishKey = ValueKey('listing-publish');
const _editKey = ValueKey('listing-save-changes');
const _restoreKey = ValueKey('listing-restore-draft');

class _ListingServer {
  _ListingServer(this.category);

  final String category;
  final writes = <http.Request>[];

  Future<http.Response> respond(http.Request request) async {
    if (request.method != 'GET') writes.add(request);
    final Object body;
    if (request.url.path.endsWith('/listings/layout-existing')) {
      body = {
        'id': 'layout-existing',
        'title': 'מודעה קיימת',
        'description': 'תיאור קיים לבדיקה',
        'category': category,
        'city': 'רחובות',
        'price': 100,
        'images': <String>[],
      };
    } else if (request.url.path.endsWith('/listing-catalog.json')) {
      body = <String, dynamic>{};
    } else {
      body = <dynamic>[];
    }
    return http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }
}

Finder _field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label);

Finder _decoratedField(String label) => find.byWidgetPredicate((widget) =>
    widget is InputDecorator && widget.decoration.labelText == label);

Finder _checkbox(String label) => find.widgetWithText(CheckboxListTile, label);

void _prepare(WidgetTester tester, Size size) {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
}

Future<void> _mount(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) =>
        Directionality(textDirection: TextDirection.rtl, child: child!),
    home: screen,
  ));
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Future<void> _category(WidgetTester tester, String category) async {
  await tester.ensureVisible(_decoratedField('קטגוריה'));
  await tester.tap(_decoratedField('קטגוריה'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(category).last);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(_field(label));
  await tester.enterText(_field(label), value);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

void _expectSeparateRows(WidgetTester tester, List<Finder> fields) {
  final rects = fields.map((finder) {
    expect(finder, findsOneWidget);
    return tester.getRect(finder);
  }).toList();
  for (var i = 1; i < rects.length; i++) {
    expect(rects[i].top, greaterThanOrEqualTo(rects[i - 1].bottom),
        reason: 'Each field must occupy its own row');
    expect(rects[i].left, closeTo(rects.first.left, 1));
    expect(rects[i].right, closeTo(rects.first.right, 1));
  }
}

void _expectNoErrors(WidgetTester tester) {
  final errors = <Object>[];
  Object? error;
  while ((error = tester.takeException()) != null) {
    errors.add(error!);
  }
  expect(errors, isEmpty);
}

Future<void> _expectPinnedActions(
    WidgetTester tester, Size size, bool editing) async {
  final action = find.byKey(editing ? _editKey : _publishKey);
  expect(action.hitTestable(), findsOneWidget);
  if (!editing) expect(find.byKey(_draftKey).hitTestable(), findsOneWidget);
  final initialRect = tester.getRect(action);

  await tester.drag(find.byKey(_scrollKey), const Offset(0, -650));
  await tester.pumpAndSettle();
  expect(action.hitTestable(), findsOneWidget);
  expect(tester.getRect(action).top, closeTo(initialRect.top, 1),
      reason: 'The save action must stay pinned while the form scrolls');

  // A visible keyboard is especially important on a narrow phone: saving must
  // remain reachable without first dismissing it or scrolling to the end.
  const keyboardHeight = 300.0;
  tester.view.viewInsets = const FakeViewPadding(bottom: keyboardHeight);
  await tester.pumpAndSettle();
  expect(action.hitTestable(), findsOneWidget);
  expect(tester.getRect(action).bottom,
      lessThanOrEqualTo(size.height - keyboardHeight + 1));
  if (!editing) {
    expect(find.byKey(_draftKey).hitTestable(), findsOneWidget);
    expect(tester.getRect(find.byKey(_draftKey)).bottom,
        lessThanOrEqualTo(size.height - keyboardHeight + 1));
  }
  _expectNoErrors(tester);
  tester.view.resetViewInsets();
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in [const Size(1400, 1000), const Size(360, 844)]) {
    for (final editing in [false, true]) {
      testWidgets(
          '${editing ? 'edit' : 'new'} vehicle form has separate RTL rows and pinned actions at ${size.width}',
          (tester) async {
        _prepare(tester, size);
        final server = _ListingServer('רכב');
        await http.runWithClient(() async {
          await _mount(
              tester,
              editing
                  ? const EditListingScreen(
                      listingId: 'layout-existing', token: 'layout-token')
                  : const PostListingScreen(
                      token: 'layout-token', me: _owner, embedded: true));

          _expectSeparateRows(tester, [
            for (final label in [
              'יצרן',
              'דגם',
              'שנת ייצור',
              'קילומטראז׳',
              'יד',
              'תיבת הילוכים',
              'סוג דלק',
              'צבע',
              'תוקף מבחן רישוי (טסט)',
            ])
              _decoratedField(label),
          ]);
          await _expectPinnedActions(tester, size, editing);
          expect(server.writes, isEmpty);
          await _unmount(tester);
        }, () => MockClient(server.respond));
      });

      testWidgets(
          '${editing ? 'edit' : 'new'} property form puts inputs and amenities on separate RTL rows at ${size.width}',
          (tester) async {
        _prepare(tester, size);
        final server = _ListingServer('נדל״ן');
        await http.runWithClient(() async {
          await _mount(
              tester,
              editing
                  ? const EditListingScreen(
                      listingId: 'layout-existing', token: 'layout-token')
                  : const PostListingScreen(
                      token: 'layout-token', me: _owner, embedded: true));
          if (!editing) await _category(tester, 'נדל״ן');

          _expectSeparateRows(tester, [
            _decoratedField(editing ? 'סוג עסקה' : 'סוג עסקה *'),
            _decoratedField(editing ? 'סוג נכס' : 'סוג נכס *'),
            _decoratedField('רחוב / שכונה'),
            _decoratedField('חדרים'),
            _decoratedField(editing ? 'מ״ר' : 'שטח במ״ר'),
            _decoratedField('קומה'),
            _decoratedField('מתוך קומות'),
          ]);
          _expectSeparateRows(tester, [
            for (final label in [
              'חניה',
              'מעלית',
              'ממ״ד',
              'מרפסת',
              'נגישות',
              'מחסן',
              'מיזוג',
              'אפשר בעלי חיים',
            ])
              _checkbox(label),
          ]);
          await _expectPinnedActions(tester, size, editing);
          expect(server.writes, isEmpty);
          await _unmount(tester);
        }, () => MockClient(server.respond));
      });
    }
  }

  for (final editing in [false, true]) {
    testWidgets(
        '${editing ? 'edit' : 'new'} furniture characteristics use one full width field per row',
        (tester) async {
      _prepare(tester, const Size(1400, 1000));
      final server = _ListingServer('רהיטים');
      await http.runWithClient(() async {
        await _mount(
            tester,
            editing
                ? const EditListingScreen(
                    listingId: 'layout-existing', token: 'layout-token')
                : const PostListingScreen(
                    token: 'layout-token', me: _owner, embedded: true));
        if (!editing) await _category(tester, 'רהיטים');
        _expectSeparateRows(tester, [
          for (final label in [
            'סוג הרהיט',
            'מתאים לחדר',
            'סגנון',
            'חומר',
            'מידות',
            'מספר מקומות / קיבולת',
            'צבע',
            'פירוק והרכבה',
            'גיל המוצר',
            'פגמים ובלאי',
          ])
            _decoratedField(label),
        ]);
        _expectNoErrors(tester);
        await _unmount(tester);
      }, () => MockClient(server.respond));
    });
  }

  testWidgets('incomplete vehicle draft saves locally and restores exact copy',
      (tester) async {
    _prepare(tester, const Size(360, 844));
    final server = _ListingServer('רכב');
    await http.runWithClient(() async {
      await _mount(
          tester,
          const PostListingScreen(
              token: 'layout-token', me: _owner, embedded: true));
      final values = {
        'יצרן': 'יצרן לבדיקה',
        'דגם': 'דגם לטיוטה',
        'שנת ייצור': '2018',
        'קילומטראז׳': '12345',
        'יד': '2',
        'כותרת המודעה *': 'טיוטה',
        'תיאור מפורט *': '',
      };
      for (final entry in values.entries) {
        await _enter(tester, entry.key, entry.value);
      }
      expect(find.byKey(_draftKey).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(_draftKey));
      await tester.pumpAndSettle();
      expect(server.writes, isEmpty,
          reason: 'Saving a partial draft must not publish a listing');
      await _unmount(tester);

      await _mount(
          tester,
          const PostListingScreen(
              token: 'rotated-layout-token', me: _owner, embedded: true));
      expect(find.byKey(_restoreKey).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(_restoreKey));
      await tester.pumpAndSettle();
      for (final entry in values.entries) {
        expect(tester.widget<TextField>(_field(entry.key)).controller!.text,
            entry.value);
      }
      expect(server.writes, isEmpty);
      _expectNoErrors(tester);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets('property draft restores its category and isolates user accounts',
      (tester) async {
    _prepare(tester, const Size(360, 844));
    final server = _ListingServer('נדל״ן');
    await http.runWithClient(() async {
      await _mount(
          tester,
          const PostListingScreen(
              token: 'layout-token', me: _owner, embedded: true));
      await _category(tester, 'נדל״ן');
      await _enter(tester, 'רחוב / שכונה', 'שכונת הבדיקה');
      await _enter(tester, 'חדרים', '3.5');
      await tester.ensureVisible(_checkbox('חניה'));
      await tester.tap(_checkbox('חניה'));
      await tester.pumpAndSettle();
      await _enter(tester, 'כותרת המודעה *', 'טיוטת נכס');
      await _enter(tester, 'תיאור מפורט *', '');
      await tester.tap(find.byKey(_draftKey));
      await tester.pumpAndSettle();
      expect(server.writes, isEmpty);
      await _unmount(tester);

      // Account isolation is based on the user identity, even when a caller
      // accidentally reuses the same access token in this test harness.
      await _mount(
          tester,
          const PostListingScreen(
              token: 'layout-token',
              me: {'id': 'different-layout-user', 'city': 'חיפה'},
              embedded: true));
      expect(find.byKey(_restoreKey), findsNothing);
      expect(
          tester.widget<TextField>(_field('כותרת המודעה *')).controller!.text,
          isEmpty);
      await _unmount(tester);

      await _mount(
          tester,
          const PostListingScreen(
              token: 'rotated-layout-token', me: _owner, embedded: true));
      expect(find.byKey(_restoreKey).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(_restoreKey));
      await tester.pumpAndSettle();
      expect(_decoratedField('סוג נכס *'), findsOneWidget);
      expect(
          tester
              .widget<DropdownButton<String>>(find.ancestor(
                  of: _decoratedField('קטגוריה'),
                  matching: find.byType(DropdownButton<String>)))
              .value,
          'נדל״ן');
      expect(tester.widget<TextField>(_field('רחוב / שכונה')).controller!.text,
          'שכונת הבדיקה');
      expect(tester.widget<TextField>(_field('חדרים')).controller!.text, '3.5');
      expect(tester.widget<CheckboxListTile>(_checkbox('חניה')).value, isTrue);
      expect(
          tester.widget<TextField>(_field('כותרת המודעה *')).controller!.text,
          'טיוטת נכס');
      expect(tester.widget<TextField>(_field('תיאור מפורט *')).controller!.text,
          isEmpty);
      expect(server.writes, isEmpty);
      _expectNoErrors(tester);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });
}
