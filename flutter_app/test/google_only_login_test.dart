import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/google_auth_fixture.dart';

const _user = {
  'id': 'google-login-existing-user',
  'name': 'משתמש Google קיים',
  'phone': '0501234567',
  'email': 'selected@example.invalid',
};

http.Response _json(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

class _LoginServer {
  int loginStatus = 200;
  Object loginBody = const {'token': 'google-login-session', 'user': _user};
  final requests = <http.Request>[];
  final authResponses = <http.Response>[];
  Future<http.Response>? pendingAuthResponse;

  List<http.Request> get auth => requests
      .where((request) => request.url.path.endsWith('/auth/google'))
      .toList();

  List<http.Request> get registration => requests
      .where((request) => request.url.path.contains('/registration/'))
      .toList();

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/auth/google')) {
      final pending = pendingAuthResponse;
      if (pending != null) {
        pendingAuthResponse = null;
        return pending;
      }
      if (authResponses.isNotEmpty) {
        return authResponses.removeAt(0);
      }
      return _json(loginBody, loginStatus);
    }
    if (path.endsWith('/profile')) return _json(_user);
    if (path.endsWith('/registration-status')) {
      return _json({'birthDateMissing': false});
    }
    if (path.endsWith('/users') ||
        path.endsWith('/groups') ||
        path.endsWith('/message-requests')) return _json([]);
    return _json({});
  }
}

Future<void> _withLogin(
  WidgetTester tester,
  _LoginServer server,
  Future<void> Function(GoogleAuthFixture google) check, {
  Size viewport = const Size(1440, 1100),
  Widget home = const AuthScreen(),
}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(viewport);
  final google = GoogleAuthFixture()..install(tester);
  try {
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: Directionality(textDirection: TextDirection.rtl, child: home),
      ));
      await tester.pumpAndSettle();
      await check(google);
      expect(tester.takeException(), isNull);
    }, () => MockClient(server.respond));
  } finally {
    for (final element in find.byType(ConversationsScreen).evaluate()) {
      (element.widget as ConversationsScreen).socket?.disconnect();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    await google.dispose();
    await tester.binding.setSurfaceSize(null);
  }
}

void _expectGoogleOnly() {
  expect(find.byKey(const ValueKey('google-login-card')), findsOneWidget);
  expect(find.byKey(const ValueKey('google-login-button')), findsOneWidget);
  expect(find.text('כניסה באמצעות Google'), findsWidgets);
  expect(find.byType(TextField), findsNothing);
  expect(find.byType(TextFormField), findsNothing);
  expect(find.textContaining('שכחת'), findsNothing);
  expect(find.textContaining('שחזור סיסמה'), findsNothing);
  expect(find.text('כניסה עם SMS'), findsNothing);
  expect(find.text('הרשמה באימייל'), findsNothing);
}

Future<void> _expectNoSession() async {
  expect((await SharedPreferences.getInstance()).getString('token'), isNull);
  expect(find.byType(MainShell), findsNothing);
  expect(find.byType(GoogleDriveBackupOfferScreen), findsNothing);
  expect(find.byType(GooglePhoneSetupScreen), findsNothing);
}

Future<void> _choose(WidgetTester tester, GoogleAuthFixture google) async {
  await google.choose(tester);
  await tester.pumpAndSettle();
}

void _expectExistingLogin(_LoginServer server, GoogleAuthFixture google) {
  expect(server.auth, hasLength(1));
  expect(jsonDecode(server.auth.single.body), {'idToken': google.idToken});
  expect(server.registration, isEmpty);
  expect(google.choiceCount, 1);
  expect(find.text('הרשמה שלב אחר שלב'), findsNothing);
  expect(find.text('השלמת פרטים'), findsNothing);
  expect(find.byType(GoogleDriveBackupOfferScreen), findsOneWidget);
  expect(find.byType(GooglePhoneSetupScreen), findsNothing);
}

http.Response _html(int status) => http.Response(
    '<html><head><title>Service unavailable</title></head></html>', status,
    headers: {'content-type': 'text/html; charset=utf-8'});

void _expectFriendlyUnavailable() {
  expect(find.text('שירות הכניסה אינו זמין כרגע. נסה שוב בעוד כמה רגעים.'),
      findsOneWidget);
  expect(find.textContaining('FormatException'), findsNothing);
  expect(find.textContaining('Unexpected token'), findsNothing);
  expect(find.textContaining('TypeError'), findsNothing);
  expect(find.textContaining('<html>'), findsNothing);
  _expectGoogleOnly();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  for (final viewport in [
    (name: 'desktop', size: const Size(1440, 1100)),
    (name: 'mobile', size: const Size(390, 844)),
  ]) {
    testWidgets(
        '${viewport.name} login offers only Google without credential fields',
        (tester) async {
      final server = _LoginServer();
      await _withLogin(tester, server, (google) async {
        _expectGoogleOnly();
        expect(find.text('stale@example.invalid'), findsNothing);
        expect(server.auth, isEmpty);
        expect(server.registration, isEmpty);
        expect(google.choiceCount, 0);
        final card =
            tester.getRect(find.byKey(const ValueKey('google-login-card')));
        expect(card.left, greaterThanOrEqualTo(0));
        expect(card.right, lessThanOrEqualTo(viewport.size.width));
        await _expectNoSession();
      },
          viewport: viewport.size,
          home: const AuthScreen(initialEmail: 'stale@example.invalid'));
    });

    testWidgets(
        '${viewport.name} Google login preserves the existing account route',
        (tester) async {
      final server = _LoginServer();
      await _withLogin(tester, server, (google) async {
        await _choose(tester, google);
        _expectExistingLogin(server, google);
        expect((await SharedPreferences.getInstance()).getString('token'),
            'google-login-session');
      }, viewport: viewport.size);
    });

    testWidgets(
        '${viewport.name} login can open registration and return without authenticating',
        (tester) async {
      final server = _LoginServer();
      await _withLogin(tester, server, (google) async {
        await tester.tap(find.widgetWithText(TextButton, 'הרשמה'));
        await tester.pumpAndSettle();
        expect(find.text('הרשמה שלב אחר שלב'), findsOneWidget);
        expect(find.text('שלב 1 מתוך 4'), findsOneWidget);
        expect(find.byKey(const ValueKey('google-login-card')), findsNothing);
        expect(server.auth, isEmpty);
        expect(server.registration, isEmpty);
        await tester.tap(find.widgetWithText(TextButton, 'כניסה'));
        await tester.pumpAndSettle();
        _expectGoogleOnly();
        expect(google.choiceCount, 0);
        expect(server.auth, isEmpty);
        expect(server.registration, isEmpty);
        await _expectNoSession();
      }, viewport: viewport.size);
    });
  }

  testWidgets(
      'cancelled Google selection creates no session and can be retried',
      (tester) async {
    final server = _LoginServer();
    await _withLogin(tester, server, (google) async {
      google.cancelSelection = true;
      await _choose(tester, google);
      _expectGoogleOnly();
      expect(google.choiceCount, 1);
      expect(server.auth, isEmpty);
      expect(server.registration, isEmpty);
      await _expectNoSession();
      google.cancelSelection = false;
      await _choose(tester, google);
      expect(google.choiceCount, 2);
      expect(server.auth, hasLength(1));
      expect(jsonDecode(server.auth.single.body), {'idToken': google.idToken});
      expect(find.byType(GoogleDriveBackupOfferScreen), findsOneWidget);
    });
  });

  testWidgets('Google credential error remains on login and permits retry',
      (tester) async {
    final server = _LoginServer();
    await _withLogin(tester, server, (google) async {
      google.failTokenRetrieval = true;
      await _choose(tester, google);
      _expectGoogleOnly();
      expect(find.textContaining('Google נכשלה'), findsOneWidget);
      expect(server.auth, isEmpty);
      expect(server.registration, isEmpty);
      await _expectNoSession();
      google.failTokenRetrieval = false;
      await _choose(tester, google);
      expect(google.choiceCount, 2);
      expect(server.auth, hasLength(1));
      expect(find.byType(GoogleDriveBackupOfferScreen), findsOneWidget);
    });
  });

  testWidgets(
      'refused Google login shows the server error without registration and retries fresh identity',
      (tester) async {
    final server = _LoginServer()
      ..loginStatus = 401
      ..loginBody = {'error': 'הכניסה לא זמינה כרגע'};
    await _withLogin(tester, server, (google) async {
      await _choose(tester, google);
      await tester.pump(const Duration(seconds: 5));
      _expectGoogleOnly();
      expect(find.text('הכניסה לא זמינה כרגע'), findsOneWidget);
      expect(server.auth, hasLength(1));
      expect(jsonDecode(server.auth.single.body), {'idToken': google.idToken});
      expect(server.registration, isEmpty);
      await _expectNoSession();
      google.idToken = 'fresh-google-login-token';
      google.email = 'fresh@example.invalid';
      server.loginStatus = 200;
      server.loginBody = {'token': 'fresh-google-session', 'user': _user};
      await _choose(tester, google);
      expect(server.auth, hasLength(2));
      expect(jsonDecode(server.auth.last.body),
          {'idToken': 'fresh-google-login-token'});
      expect(server.registration, isEmpty);
      expect(google.choiceCount, 2);
      expect(find.byType(GoogleDriveBackupOfferScreen), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getString('token'),
          'fresh-google-session');
    });
  });

  testWidgets('Google HTML gateway response retries once after four seconds',
      (tester) async {
    final server = _LoginServer()..authResponses.add(_html(502));
    await _withLogin(tester, server, (google) async {
      await google.choose(tester);
      await tester.pump();
      expect(server.auth, hasLength(1));
      await tester.pump(const Duration(milliseconds: 3900));
      expect(server.auth, hasLength(1));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(server.auth, hasLength(2));
      expect(server.auth.map((request) => jsonDecode(request.body)),
          everyElement({'idToken': google.idToken}));
      expect(google.choiceCount, 1);
      expect(server.registration, isEmpty);
      expect(find.byType(GoogleDriveBackupOfferScreen), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getString('token'),
          'google-login-session');
    });
  });

  testWidgets(
      'persistent Google HTML gateway failure stays friendly and retries a new choice',
      (tester) async {
    final server = _LoginServer()
      ..authResponses.addAll([_html(503), _html(503)]);
    await _withLogin(tester, server, (google) async {
      await _choose(tester, google);
      await tester.pump(const Duration(seconds: 5));
      _expectFriendlyUnavailable();
      expect(server.auth, hasLength(2));
      expect(google.choiceCount, 1);
      expect(server.registration, isEmpty);
      await _expectNoSession();
      google.idToken = 'fresh-after-gateway-failure';
      google.email = 'fresh-after-gateway@example.invalid';
      await _choose(tester, google);
      expect(server.auth, hasLength(3));
      expect(jsonDecode(server.auth.last.body), {'idToken': google.idToken});
      expect(google.choiceCount, 2);
      expect(find.byType(GoogleDriveBackupOfferScreen), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getString('token'),
          'google-login-session');
    });
  });

  for (final response in [
    (name: 'HTML 200', value: _html(200)),
    (
      name: 'invalid JSON 200',
      value: http.Response('{"token":', 200,
          headers: {'content-type': 'application/json'})
    ),
    (name: 'non-map JSON 200', value: _json(['unexpected'])),
    (name: 'missing token JSON 200', value: _json({'user': _user})),
    (name: 'empty token JSON 200', value: _json({'token': '', 'user': _user})),
    (
      name: 'invalid user JSON 200',
      value: _json({
        'token': 'untrusted-session',
        'user': ['unexpected']
      })
    ),
  ]) {
    testWidgets(
        'Google ${response.name} stays friendly without retry or session',
        (tester) async {
      final server = _LoginServer()..authResponses.add(response.value);
      await _withLogin(tester, server, (google) async {
        await _choose(tester, google);
        await tester.pump(const Duration(seconds: 5));
        _expectFriendlyUnavailable();
        expect(server.auth, hasLength(1));
        expect(google.choiceCount, 1);
        expect(server.registration, isEmpty);
        await _expectNoSession();
      });
    });
  }

  for (final response in [
    (name: 'success', value: _json({'token': 'late-session', 'user': _user})),
    (name: 'gateway error', value: _html(502)),
  ]) {
    testWidgets(
        'late Google ${response.name} after disposal does not retry or authenticate',
        (tester) async {
      final pending = Completer<http.Response>();
      final server = _LoginServer()..pendingAuthResponse = pending.future;
      await _withLogin(tester, server, (google) async {
        await google.choose(tester);
        await tester.pump();
        expect(server.auth, hasLength(1));
        await tester.pumpWidget(const SizedBox.shrink());
        pending.complete(response.value);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(server.auth, hasLength(1));
        await _expectNoSession();
      });
    });
  }

  testWidgets(
      'disposing during the pending Google retry prevents the second request',
      (tester) async {
    final server = _LoginServer()..authResponses.add(_html(502));
    await _withLogin(tester, server, (google) async {
      await google.choose(tester);
      await tester.pump();
      expect(server.auth, hasLength(1));
      await tester.pump(const Duration(seconds: 1));
      expect(server.auth, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
      expect(server.auth, hasLength(1));
      await _expectNoSession();
    });
  });
}
