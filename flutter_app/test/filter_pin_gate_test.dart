import 'dart:convert';
import 'package:betshuva/filter_pin_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> digits(WidgetTester tester, String value) async {
  for (final digit in value.split('')) {
    final key = find.byKey(ValueKey('filter-pin-key-$digit'));
    await tester.ensureVisible(key);
    await tester.tap(key);
    await tester.pump();
  }
  final confirm = find.widgetWithText(FilledButton, 'אישור');
  await tester.ensureVisible(confirm);
  await tester.tap(confirm);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('locked controls stay unchanged until the server approves PIN',
      (tester) async {
    bool unlocked = false, selected = false;
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/unlock')) {
        expect(jsonDecode(r.body), {'pin': '1234'});
        unlocked = true;
      }
      return http.Response(
          jsonEncode({'configured': true, 'unlocked': unlocked}), 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: StatefulBuilder(
                  builder: (context, setState) => FilterPinGate(
                      api: 'https://example.test/api',
                      token: 'session',
                      child: Switch(
                          key: const ValueKey('protected-switch'),
                          value: selected,
                          onChanged: (v) => setState(() => selected = v)))))));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('protected-switch')),
          warnIfMissed: false);
      expect(selected, false);
      await tester.tap(find.byKey(const ValueKey('filter-pin-lock')));
      await tester.pumpAndSettle();
      await digits(tester, '1234');
      expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('protected-switch')));
      await tester.pumpAndSettle();
      expect(selected, true);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });
  testWidgets('forgot code sends a reset link and does not ask for an email code', (tester) async {
    final posts = <http.Request>[];
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/recover')) posts.add(r);
      return http.Response(jsonEncode({'configured': true, 'unlocked': false, 'ok': true}), 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: FilterPinGate(
        api: 'https://example.test/api', token: 'session', child: Text('settings')))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-pin-lock'))); await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('שכחתי קוד')); await tester.tap(find.text('שכחתי קוד')); await tester.pumpAndSettle();
      expect(posts.length, 1);
      expect(find.text('קישור לבחירת קוד חדש נשלח לאימייל המאומת שהוגדר עם הקוד'), findsOneWidget);
      expect(find.byType(FilterPinPad), findsNothing);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });
  testWidgets('network failure stays locked and permits retry', (tester) async {
    var count = 0;
    final client = MockClient((r) async => http.Response(
        jsonEncode(++count == 1
            ? {'error': 'offline'}
            : {'configured': false, 'unlocked': true}),
        count == 1 ? 503 : 200));
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: FilterPinGate(
                  api: 'https://example.test/api',
                  token: 'session',
                  child: const Text('settings')))));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('filter-pin-lock')));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });
  testWidgets('setting a PIN requires confirmation and then locks editing',
      (tester) async {
    bool configured = false;
    final posts = <http.Request>[];
    final client = MockClient((r) async {
      if (r.method == 'POST' && r.url.path.endsWith('/setup')) {
        posts.add(r);
        configured = true;
      }
      return http.Response(
          jsonEncode({'configured': configured, 'unlocked': !configured}), 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: FilterPinGate(
                  api: 'https://example.test/api',
                  token: 'session',
                  child: const Text('settings')))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-pin-lock')));
      await tester.pumpAndSettle();
      await digits(tester, '0012');
      expect(posts, isEmpty);
      await digits(tester, '0012');
      expect(
          jsonDecode(posts.single.body), {'pin': '0012', 'confirmPin': '0012'});
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });
  testWidgets(
      'expired access is displayed locked without changing the saved filter',
      (tester) async {
    var unlocked = true;
    final client = MockClient((r) async => http.Response(
        jsonEncode({'configured': true, 'unlocked': unlocked}), 200));
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: FilterPinGate(
                  api: 'https://example.test/api',
                  token: 'session',
                  child: const Text('saved filter')))));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);
      unlocked = false;
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.text('saved filter'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });
  testWidgets('leaving closes access and re-entering requires PIN again',
      (tester) async {
    var unlocked = false;
    final requests = <http.Request>[];
    final client = MockClient((r) async {
      requests.add(r);
      if (r.url.path.endsWith('/unlock')) unlocked = true;
      if (r.url.path.endsWith('/enter') || r.url.path.endsWith('/leave'))
        unlocked = false;
      return http.Response(
          jsonEncode({'configured': true, 'unlocked': unlocked}), 200);
    });
    await http.runWithClient(() async {
      Widget screen() => const MaterialApp(
          home: Scaffold(
              body: FilterPinGate(
                  api: 'https://example.test/api',
                  token: 'session',
                  child: Text('settings'))));
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-pin-lock')));
      await tester.pumpAndSettle();
      await digits(tester, '1234');
      expect(
          find.text('ההגדרות פתוחות לעריכה עד היציאה מהמסך'), findsOneWidget);
      await tester.pump(const Duration(minutes: 16));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock_open_outlined), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(requests.any((r) => r.url.path.endsWith('/leave')), true);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      final entries =
          requests.where((r) => r.url.path.endsWith('/enter')).toList();
      expect(entries.length, 2);
      expect(entries.first.headers['X-Filter-Pin-Scope'],
          isNot(entries.last.headers['X-Filter-Pin-Scope']));
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });
  testWidgets('disabling protection requires a PIN and calls only disable',
      (tester) async {
    var configured = true;
    final posts = <http.Request>[];
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/disable')) {
        posts.add(r);
        configured = false;
      }
      return http.Response(
          jsonEncode({'configured': configured, 'unlocked': !configured}), 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: FilterPinGate(
                  api: 'https://example.test/api',
                  token: 'session',
                  child: Text('settings')))));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-pin-lock')));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('filter-pin-disable'));
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      for (final digit in '1234'.split('')) {
        final key = find.byKey(ValueKey('filter-pin-key-$digit'));
        await tester.ensureVisible(key);
        await tester.tap(key);
        await tester.pump();
      }
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('האם אתם בטוחים?'), findsOneWidget);
      expect(
          find.text(
              'פעולה זו מסירה את הנעילה מכל מסכי הסינון. הסינון עצמו ממשיך לפעול.'),
          findsOneWidget);
      expect(posts, isEmpty);
      await tester.tap(find.text('השארת הנעילה'));
      await tester.pumpAndSettle();
      expect(posts, isEmpty);
      expect(find.byType(FilterPinPad), findsOneWidget);
      expect(
          tester.widget<TextButton>(button).style!.foregroundColor!.resolve({}),
          Colors.red.shade700);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('filter-pin-confirm-disable')));
      await tester.pumpAndSettle();
      expect(jsonDecode(posts.single.body), {'pin': '1234'});
      expect(find.text('ההגדרות פתוחות • מומלץ לנעול באמצעות קוד'),
          findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
  });
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(568, 320)
  ])
    testWidgets('keypad fits $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => showDialog(
                          context: context,
                          builder: (_) => const FilterPinPad(
                              title: 'פתיחת הגדרות הסינון', forgot: true)),
                      child: const Text('open'))))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final cancel = find.byKey(const ValueKey('filter-pin-key-cancel'));
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(find.byType(FilterPinPad), findsNothing);
    });
}
