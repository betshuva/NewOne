import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:betshuva/main.dart';

import 'helpers/google_auth_fixture.dart';

Future<void> _withGoogle(
    WidgetTester tester, Future<void> Function() check) async {
  final google = GoogleAuthFixture()..install(tester);
  try {
    await http.runWithClient(
        check, () => MockClient((request) async => http.Response('{}', 200)));
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await google.dispose();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('new registration only offers Google and cannot skip identity',
      (tester) async {
    await _withGoogle(tester, () async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const MaterialApp(
          home: Directionality(
              textDirection: TextDirection.rtl,
              child: AuthScreen(initialRegistration: true))));
      await tester.pumpAndSettle();
      expect(find.text('הרשמה באמצעות Google'), findsWidgets);
      expect(find.text('הרשמה באימייל'), findsNothing);
      expect(find.text('הרשמה עם SMS'), findsNothing);
      expect(find.text('שלב 1 מתוך 4'), findsOneWidget);
      expect(find.textContaining('Google Drive יוצע בהמשך לבחירתך'),
          findsOneWidget);
      final next = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(next.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('existing users receive Google login without password fields',
      (tester) async {
    await _withGoogle(tester, () async {
      await tester.pumpWidget(const MaterialApp(
          home: Directionality(
              textDirection: TextDirection.rtl, child: AuthScreen())));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('google-login-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('google-login-button')), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('כניסה באמצעות Google'), findsOneWidget);
      expect(find.textContaining('שכחת'), findsNothing);
    });
  });

  testWidgets('SMS login only requests phone, with Google signup link',
      (tester) async {
    await _withGoogle(tester, () async {
      await tester.pumpWidget(const MaterialApp(
          home: Directionality(
              textDirection: TextDirection.rtl, child: PhoneAuthScreen())));
      await tester.pumpAndSettle();
      expect(find.text('כניסה לחשבון קיים עם SMS'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('הרשמה חדשה באמצעות Google'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.tap(find.text('הרשמה חדשה באמצעות Google'));
      await tester.pumpAndSettle();
      expect(find.text('שלב 1 מתוך 4'), findsOneWidget);
    });
  });
}
