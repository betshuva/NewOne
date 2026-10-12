import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:betshuva/welcome_entry_policy.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/google_auth_fixture.dart';

final _launchUri = Uri.parse('https://betshuva.com/betshuva-app/');
const _existingToken = 'welcome-existing-session';

http.Response _json(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

class _SplashServer {
  int statusCode = 200;
  Map<String, dynamic> registrationStatus = {'birthDateMissing': false};
  final requests = <http.Request>[];

  List<http.Request> get statusChecks => requests
      .where((request) => request.url.path.endsWith('/registration-status'))
      .toList();

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/registration-status')) {
      return _json(registrationStatus, statusCode);
    }
    if (path.endsWith('/profile')) {
      return _json({
        'id': 'welcome-existing-user',
        'name': 'משתמש בדיקה',
        'email': 'welcome@example.invalid',
        'phone': '',
      });
    }
    return _json({});
  }
}

Future<void> _showSplash(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'NotoSansHebrew'),
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: SplashScreen(initialUri: _launchUri),
    ),
  ));
  await tester.pump(const Duration(seconds: 2));
  await tester.pumpAndSettle();
}

Future<void> _withSplash(
  WidgetTester tester,
  _SplashServer server,
  Future<void> Function() check, {
  Map<String, Object> preferences = const {},
}) async {
  SharedPreferences.setMockInitialValues(preferences);
  await tester.binding.setSurfaceSize(const Size(390, 844));
  final google = GoogleAuthFixture()..install(tester);
  try {
    await http.runWithClient(() async {
      await _showSplash(tester);
      await check();
      expect(google.choiceCount, 0);
      expect(
          server.requests.where((request) =>
              request.url.path.endsWith('/auth/google') ||
              request.url.path.endsWith('/registration/verify-google')),
          isEmpty);
      expect(tester.takeException(), isNull);
    }, () => MockClient(server.respond));
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await google.dispose();
    await tester.binding.setSurfaceSize(null);
  }
}

void _expectWelcome() {
  expect(find.byKey(const ValueKey('welcome-screen')), findsOneWidget);
  expect(find.byType(AuthScreen), findsNothing);
  expect(find.byType(GooglePhoneSetupScreen), findsNothing);
}

void _expectGoogleLogin() {
  expect(find.byKey(const ValueKey('welcome-screen')), findsNothing);
  expect(find.byKey(const ValueKey('google-login-card')), findsOneWidget);
  expect(find.byKey(const ValueKey('google-login-button')), findsOneWidget);
  expect(find.byType(TextField), findsNothing);
  expect(_authScreen().initialRegistration, isFalse);
}

AuthScreen _authScreen() =>
    find.byType(AuthScreen).evaluate().single.widget as AuthScreen;

Future<void> _tapWelcome(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  testWidgets(
      'first native guest skips welcome and the next launch goes directly to Google login',
      (tester) async {
    final server = _SplashServer();
    await _withSplash(tester, server, () async {
      _expectWelcome();
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getInt(welcomeSeenVersionKey), isNull);
      expect(server.statusChecks, isEmpty);
      await _tapWelcome(tester, 'welcome-skip');
      _expectGoogleLogin();
      expect(preferences.getInt(welcomeSeenVersionKey),
          welcomeIntroductionVersion);
      expect(preferences.getString('token'), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _showSplash(tester);
      _expectGoogleLogin();
      expect(server.statusChecks, isEmpty);
    });
  }, skip: kIsWeb);

  testWidgets(
      'first native guest finishes welcome into Google login and saves the seen version',
      (tester) async {
    await _withSplash(tester, _SplashServer(), () async {
      _expectWelcome();
      await _tapWelcome(tester, 'welcome-finish');
      _expectGoogleLogin();
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getInt(welcomeSeenVersionKey),
          welcomeIntroductionVersion);
      expect(preferences.getString('token'), isNull);
    });
  }, skip: kIsWeb);

  testWidgets(
      'native welcome registration opens the Google signup wizard without authenticating',
      (tester) async {
    await _withSplash(tester, _SplashServer(), () async {
      _expectWelcome();
      await _tapWelcome(tester, 'welcome-register');
      expect(find.byKey(const ValueKey('welcome-screen')), findsNothing);
      expect(_authScreen().initialRegistration, isTrue);
      expect(find.text('שלב 1 מתוך 4'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getInt(welcomeSeenVersionKey),
          welcomeIntroductionVersion);
      expect(preferences.getString('token'), isNull);
    });
  }, skip: kIsWeb);

  testWidgets(
      'a guest who has already seen welcome opens Google login directly',
      (tester) async {
    final server = _SplashServer();
    await _withSplash(tester, server, () async {
      _expectGoogleLogin();
      expect(server.statusChecks, isEmpty);
    }, preferences: {welcomeSeenVersionKey: welcomeIntroductionVersion});
  });

  testWidgets(
      'incomplete existing registration bypasses welcome and returns to the signup wizard',
      (tester) async {
    final server = _SplashServer()
      ..registrationStatus = {'registrationIncomplete': true};
    await _withSplash(tester, server, () async {
      expect(find.byKey(const ValueKey('welcome-screen')), findsNothing);
      expect(_authScreen().initialRegistration, isTrue);
      expect(find.text('שלב 1 מתוך 4'), findsOneWidget);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('token'), isNull);
      expect(preferences.getInt(welcomeSeenVersionKey), isNull);
      expect(server.statusChecks, hasLength(1));
      expect(server.statusChecks.single.headers['Authorization'],
          'Bearer $_existingToken');
    }, preferences: const {'token': _existingToken});
  });

  for (final status in [
    (name: 'missing phone', data: {'phoneMissing': true}, verification: false),
    (
      name: 'required verification',
      data: {'verificationRequired': true},
      verification: true
    ),
  ]) {
    testWidgets(
        'existing ${status.name} bypasses welcome and retains its phone setup route',
        (tester) async {
      final server = _SplashServer()..registrationStatus = status.data;
      await _withSplash(tester, server, () async {
        expect(find.byKey(const ValueKey('welcome-screen')), findsNothing);
        expect(find.byType(AuthScreen), findsNothing);
        final phoneSetup = tester.widget<GooglePhoneSetupScreen>(
            find.byType(GooglePhoneSetupScreen));
        expect(phoneSetup.token, _existingToken);
        expect(phoneSetup.requireVerification, status.verification);
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString('token'), _existingToken);
        expect(preferences.getInt(welcomeSeenVersionKey), isNull);
        expect(server.statusChecks, hasLength(1));
      }, preferences: const {'token': _existingToken});
    });
  }
}
