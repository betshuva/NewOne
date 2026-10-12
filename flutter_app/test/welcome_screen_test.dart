import 'package:betshuva/welcome_entry_policy.dart';
import 'package:betshuva/welcome_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(ValueChanged<bool> onContinue,
        {ValueChanged<String>? onOpenUrl, double scale = 1}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: WelcomeScreen(onContinue: onContinue, onOpenUrl: onOpenUrl),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('interactive examples do not modify filters or complete the tour',
      (tester) async {
    final continued = <bool>[];
    await tester.pumpWidget(_app(continued.add));
    expect(find.text('נשארים קרובים לקהילה'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('welcome-feature-1')));
    await tester.pump();
    expect(find.text('בוחרים את התוכן שרוצים לראות'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('welcome-feature-2')));
    await tester.pump();
    expect(find.text('מהקהילה, קרוב אליכם'), findsOneWidget);
    expect(find.text('דוגמה להמחשה'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    expect(continued, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('skip saves the content version before allowing auth navigation',
      (tester) async {
    int? savedWhenContinuing;
    final prefs = await SharedPreferences.getInstance();
    final continued = <bool>[];
    await tester.pumpWidget(_app((registration) {
      savedWhenContinuing = prefs.getInt(welcomeSeenVersionKey);
      continued.add(registration);
    }));
    await tester.tap(find.byKey(const ValueKey('welcome-skip')));
    await tester.pumpAndSettle();
    expect(savedWhenContinuing, welcomeIntroductionVersion);
    expect(continued, [false]);
    await tester.ensureVisible(find.byKey(const ValueKey('welcome-finish')));
    await tester.tap(find.byKey(const ValueKey('welcome-finish')));
    await tester.pumpAndSettle();
    expect(continued, [false]);
  });

  testWidgets('registration remains an explicit choice separate from examples',
      (tester) async {
    final continued = <bool>[];
    await tester.pumpWidget(_app(continued.add));
    await tester.ensureVisible(find.byKey(const ValueKey('welcome-register')));
    await tester.tap(find.byKey(const ValueKey('welcome-register')));
    await tester.pumpAndSettle();
    expect(continued, [true]);
    expect(
        (await SharedPreferences.getInstance()).getInt(welcomeSeenVersionKey),
        welcomeIntroductionVersion);
  });

  testWidgets('320px, short screen and larger text scroll without overflow',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app((_) {}, scale: 1.4));
    expect(find.byKey(const ValueKey('welcome-skip')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('welcome-feature-2')));
    await tester.tap(find.byKey(const ValueKey('welcome-feature-2')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('welcome-finish')));
    expect(tester.getRect(find.byKey(const ValueKey('welcome-finish'))).width,
        lessThanOrEqualTo(320));
    expect(find.textContaining('לבני 18 ומעלה'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legal links use their callbacks without completing the intro',
      (tester) async {
    final opened = <String>[], continued = <bool>[];
    await tester.pumpWidget(_app(continued.add, onOpenUrl: opened.add));
    await tester.ensureVisible(find.text('תנאי שימוש'));
    await tester.tap(find.text('תנאי שימוש'));
    await tester.ensureVisible(find.text('פרטיות'));
    await tester.tap(find.text('פרטיות'));
    expect(opened, [
      'https://betshuva.com/betshuva-app/terms',
      'https://betshuva.com/betshuva-app/privacy',
    ]);
    expect(continued, isEmpty);
    expect(
        (await SharedPreferences.getInstance()).getInt(welcomeSeenVersionKey),
        isNull);
  });
}
