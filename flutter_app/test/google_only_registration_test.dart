import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:betshuva/main.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('new registration only offers Google and cannot skip identity',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: Directionality(
        textDirection: TextDirection.rtl,
        child: AuthScreen(initialRegistration: true))));
    await tester.pumpAndSettle();
    expect(find.text('הרשמה באמצעות Google'), findsWidgets);
    expect(find.text('הרשמה באימייל'), findsNothing);
    expect(find.text('הרשמה עם SMS'), findsNothing);
    expect(find.text('שלב 1 מתוך 4'), findsOneWidget);
    expect(find.textContaining('Google Drive יוצע בהמשך לבחירתך'), findsOneWidget);
    final next = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(next.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('existing users retain password login', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Directionality(
        textDirection: TextDirection.rtl, child: AuthScreen())));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'כתובת אימייל'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'סיסמה'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('SMS login only requests phone, with Google signup link',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Directionality(
        textDirection: TextDirection.rtl, child: PhoneAuthScreen())));
    await tester.pumpAndSettle();
    expect(find.text('כניסה לחשבון קיים עם SMS'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('הרשמה חדשה באמצעות Google'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNothing);
    await tester.tap(find.text('הרשמה חדשה באמצעות Google'));
    await tester.pumpAndSettle();
    expect(find.text('שלב 1 מתוך 4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
