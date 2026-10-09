import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/google_auth_fixture.dart';

const _required = {
  'code': 'REGISTRATION_REQUIRED',
  'error': 'ליצירת חשבון חדש יש לעבור למסך הרשמה',
};
const _verified = {
  'ok': true,
  'existingAccount': false,
  'name': 'שם מאומת מחשבון Google',
  'email': 'selected@example.invalid',
};
const _user = {
  'id': 'existing-user',
  'name': 'Existing Google Account',
  'phone': '0501234567',
  'email': 'selected@example.invalid',
};

http.Response _json(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

class _Server {
  int loginStatus = 400;
  Object loginBody = _required;
  int verifyStatus = 200;
  Object verifyBody = _verified;
  int finishStatus = 403;
  Object finishBody = const {
    'code': 'AGE_RESTRICTED',
    'error': 'השירות זמין לבני 18 ומעלה בלבד',
  };
  Completer<http.Response>? verificationGate;
  Completer<http.Response>? loginGate;
  int linkPhoneStatus = 200;
  Object linkPhoneBody = const {};
  bool failLinkPhoneConnection = false;
  int sendOtpStatus = 200;
  Object sendOtpBody = const {};
  final requests = <http.Request>[];

  List<http.Request> get auth => requests
      .where((request) => request.url.path.endsWith('/auth/google'))
      .toList();
  List<http.Request> get verify => requests
      .where(
          (request) => request.url.path.endsWith('/registration/verify-google'))
      .toList();
  List<http.Request> get linkPhone => requests
      .where((request) => request.url.path.endsWith('/link-phone'))
      .toList();
  List<http.Request> get sendOtp => requests
      .where((request) => request.url.path.endsWith('/send-otp'))
      .toList();

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/auth/google')) {
      if (auth.length == 1) {
        if (loginGate != null) return await loginGate!.future;
        return _json(loginBody, loginStatus);
      }
      return _json(finishBody, finishStatus);
    }
    if (path.endsWith('/registration/verify-google')) {
      if (verificationGate != null) return await verificationGate!.future;
      return _json(verifyBody, verifyStatus);
    }
    if (path.endsWith('/link-phone')) {
      if (failLinkPhoneConnection) {
        throw http.ClientException('Offline fixture', request.url);
      }
      return _json(linkPhoneBody, linkPhoneStatus);
    }
    if (path.endsWith('/send-otp')) {
      return _json(sendOtpBody, sendOtpStatus);
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

Future<void> _withFixture(WidgetTester tester, _Server server,
    Future<void> Function(GoogleAuthFixture google) check,
    {Widget home = const AuthScreen(),
    Size surfaceSize = const Size(900, 1100)}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(surfaceSize);
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
    if (server.loginGate != null && !server.loginGate!.isCompleted) {
      server.loginGate!.complete(_json(_required, 400));
    }
    if (server.verificationGate != null &&
        !server.verificationGate!.isCompleted) {
      server.verificationGate!.complete(_json(_verified));
    }
    await tester.pump(const Duration(seconds: 2));
    await google.dispose();
    await tester.binding.setSurfaceSize(null);
  }
}

Future<void> _tap(WidgetTester tester, Finder button) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, GoogleAuthFixture google) async {
  await google.choose(tester);
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 1500));
  await tester.pumpAndSettle();
}

void _expectNoSessionOrProtectedScreens() {
  expect(find.byType(MainShell), findsNothing);
  expect(find.byType(GooglePhoneSetupScreen), findsNothing);
  expect(find.byType(GoogleDriveBackupOfferScreen), findsNothing);
}

Future<void> _selectBirth(WidgetTester tester, String value) async {
  final parts = value.split('/').map(int.parse).toList();
  for (final pair in [
    ('שנה', parts[2]),
    ('חודש', parts[1]),
    ('יום', parts[0])
  ]) {
    tester
        .widget<DropdownButtonFormField<int>>(
            find.widgetWithText(DropdownButtonFormField<int>, pair.$1))
        .onChanged!(pair.$2);
    await tester.pumpAndSettle();
  }
}

List<int?> _birthSelection(WidgetTester tester) => ['יום', 'חודש', 'שנה']
    .map((label) => tester
        .widget<DropdownButtonFormField<int>>(
            find.widgetWithText(DropdownButtonFormField<int>, label))
        .initialValue)
    .toList();

Future<String> _fillDetails(WidgetTester tester) async {
  await _tap(tester, find.text('המשך'));
  expect(find.text('השלמת פרטים'), findsOneWidget);
  expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'שם מלא'))
          .controller!
          .text,
      _verified['name']);
  await _selectBirth(tester, '15/06/1985');
  await tester.pumpAndSettle();
  const birthDate = '1985-06-15';
  await _tap(tester, find.byType(DropdownButtonFormField<String>));
  await _tap(tester, find.text('זכר').last);
  await _tap(tester, find.text('המשך'));
  expect(find.text('אישור וסיום'), findsOneWidget);
  return birthDate;
}

Future<void> _acceptConsents(WidgetTester tester) async {
  await _tap(tester, find.byType(Checkbox).first);
  await _tap(tester, find.byType(Checkbox).last);
}

Future<void> _finishSignup(
    WidgetTester tester, GoogleAuthFixture google) async {
  await _choose(tester, google);
  expect(find.text('בחירת סינון'), findsOneWidget);
  await _fillDetails(tester);
  await _acceptConsents(tester);
  await _tap(tester, find.text('סיום הרשמה'));
}

void _expectConversations() {
  expect(find.byType(MainShell), findsOneWidget);
  expect(find.byType(ConversationsScreen), findsOneWidget);
  expect(find.byType(SettingsScreen), findsNothing);
  expect(find.byType(GoogleDriveBackupOfferScreen), findsNothing);
  expect(find.byType(GooglePhoneSetupScreen), findsNothing);
  final screen = find.byType(ConversationsScreen).evaluate().single.widget
      as ConversationsScreen;
  expect(screen.currentMainNavigationIndex, 0);
}

Future<void> _tapWhileWaitingForSms(WidgetTester tester, Finder button) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await tester.ensureVisible(button);
  await tester.tap(button);
  // The SMS waiting animation repeats, so settling is inappropriate here.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 100));
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
      'missing Google account automatically registers the selected '
      'identity and waits for filters, details and consents', (tester) async {
    final server = _Server();
    await _withFixture(tester, server, (google) async {
      await tester.enterText(find.widgetWithText(TextField, 'כתובת אימייל'),
          'old-login@example.invalid');
      await tester.enterText(
          find.widgetWithText(TextField, 'סיסמה'), 'old-login-password');
      await _choose(tester, google);
      expect(find.text('בחירת סינון'), findsOneWidget);
      expect(find.text('שלב 2 מתוך 4'), findsOneWidget);
      expect(find.text('כניסה לחשבון'), findsNothing);
      expect(google.choiceCount, 1);
      expect(server.auth, hasLength(1));
      expect(server.verify, hasLength(1));
      expect(jsonDecode(server.auth.single.body)['idToken'], google.idToken);
      expect(
          jsonDecode(server.verify.single.body), {'idToken': google.idToken});
      expect(jsonDecode(server.auth.single.body), {'idToken': google.idToken});
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      _expectNoSessionOrProtectedScreens();
      await _tap(tester, find.text('גברים'));
      await _tap(tester, find.text('אכיפת הסינון הכללי בכל המערכת'));
      final birthDate = await _fillDetails(tester);
      expect(find.text('old-login@example.invalid'), findsNothing);
      await _tap(tester, find.text('סיום הרשמה'));
      expect(server.auth, hasLength(1));
      await _tap(tester, find.byType(Checkbox).first);
      await _tap(tester, find.text('סיום הרשמה'));
      expect(server.auth, hasLength(1));
      await _tap(tester, find.byType(Checkbox).last);
      await _tap(tester, find.text('סיום הרשמה'));
      expect(server.auth, hasLength(2));
      final saved = jsonDecode(server.auth.last.body) as Map;
      expect(saved['idToken'], google.idToken);
      expect(saved['birthDate'], birthDate);
      expect(saved['gender'], 'male');
      expect(saved['acceptedTerms'], isTrue);
      expect(saved['ageConfirmed'], isTrue);
      expect(saved['contentFilterConfirmed'], isTrue);
      expect(saved['contentFilter']['men'], isTrue);
      expect(saved['contentFilter']['enforceGeneralFilter'], isTrue);
      expect(google.choiceCount, 1);
      expect(server.verify, hasLength(1));
      expect(find.text('אישור וסיום'), findsOneWidget);
      expect(find.text('השירות זמין לבני 18 ומעלה בלבד'), findsOneWidget);
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      _expectNoSessionOrProtectedScreens();
      await _tap(tester, find.widgetWithText(TextButton, 'כניסה'));
      expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'כתובת אימייל'))
              .controller!
              .text,
          'selected@example.invalid');
      expect(google.choiceCount, 1);
      expect(server.auth, hasLength(2));
    });
  });

  for (final error in [
    (status: 401, code: 'REGISTRATION_REQUIRED'),
    (status: 400, code: 'OTHER_VALIDATION_ERROR'),
    (status: 403, code: 'REGISTRATION_REQUIRED'),
    (status: 403, code: 'AGE_RESTRICTED'),
    (status: 429, code: 'REGISTRATION_REQUIRED'),
    (status: 500, code: 'REGISTRATION_REQUIRED'),
  ]) {
    testWidgets(
        'Google login ${error.status}/${error.code} stays an error '
        'and never starts registration', (tester) async {
      final server = _Server()
        ..loginStatus = error.status
        ..loginBody = {'code': error.code, 'error': 'Login was refused'};
      await _withFixture(tester, server, (google) async {
        await _choose(tester, google);
        expect(find.text('כניסה לחשבון'), findsOneWidget);
        expect(find.text('Login was refused'), findsOneWidget);
        expect(find.text('הרשמה שלב אחר שלב'), findsNothing);
        expect(find.text('בחירת סינון'), findsNothing);
        expect(server.auth, hasLength(1));
        expect(server.verify, isEmpty);
        expect(google.choiceCount, 1);
        expect(
            (await SharedPreferences.getInstance()).getString('token'), isNull);
        _expectNoSessionOrProtectedScreens();
      });
    });
  }

  testWidgets(
      'existing Google login keeps its normal route without signup '
      'verification or a second Google selection', (tester) async {
    final server = _Server()
      ..loginStatus = 200
      ..loginBody = {'token': 'existing-session', 'user': _user};
    await _withFixture(tester, server, (google) async {
      await _choose(tester, google);
      expect(find.byType(GoogleDriveBackupOfferScreen), findsOneWidget);
      expect(find.text('הרשמה שלב אחר שלב'), findsNothing);
      expect(find.text('השלמת פרטים'), findsNothing);
      expect(server.auth, hasLength(1));
      expect(server.verify, isEmpty);
      expect(google.choiceCount, 1);
      expect((await SharedPreferences.getInstance()).getString('token'),
          'existing-session');
    });
  });

  testWidgets(
      'completed Google registration opens conversations on a phone '
      'without opening settings or the Drive offer', (tester) async {
    final server = _Server()
      ..finishStatus = 200
      ..finishBody = {'token': 'registered-session', 'user': _user};
    await _withFixture(tester, server, (google) async {
      await _finishSignup(tester, google);
      _expectConversations();
      expect(find.byType(AuthScreen), findsNothing);
      expect(server.auth, hasLength(2));
      expect(server.verify, hasLength(1));
      final signup = jsonDecode(server.auth.last.body) as Map;
      expect(signup['acceptedTerms'], isTrue);
      expect(signup['ageConfirmed'], isTrue);
      expect(signup['contentFilterConfirmed'], isTrue);
      expect(signup['gender'], 'male');
      expect(signup['birthDate'], isNotEmpty);
      expect(signup['idToken'], google.idToken);
      expect(google.choiceCount, 1);
      expect(server.linkPhone, isEmpty);
      expect(server.sendOtp, isEmpty);
      expect((await SharedPreferences.getInstance()).getString('token'),
          'registered-session');
    }, surfaceSize: const Size(390, 844));
  });

  testWidgets(
      'Google signup requires an adult selected date and clears a previously '
      'valid date when edited to an month without the selected day',
      (tester) async {
    final server = _Server();
    await _withFixture(tester, server, (google) async {
      await _choose(tester, google);
      await _tap(tester, find.text('המשך'));
      expect(find.text('השלמת פרטים'), findsOneWidget);

      await _selectBirth(tester, '15/06/1985');
      await tester.pumpAndSettle();
      await _tap(tester, find.byType(DropdownButtonFormField<String>));
      await _tap(tester, find.text('זכר').last);
      await _selectBirth(tester, '31/01/1985');
      tester
          .widget<DropdownButtonFormField<int>>(
              find.widgetWithText(DropdownButtonFormField<int>, 'חודש'))
          .onChanged!(2);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('המשך'));
      expect(find.text('השלמת פרטים'), findsOneWidget);
      expect(find.text('אישור וסיום'), findsNothing);
      expect(server.auth, hasLength(1));
      final now = DateTime.now();
      await _selectBirth(tester, '31/12/${now.year - 18}');
      await _tap(tester, find.text('המשך'));
      expect(find.text('השלמת פרטים'), findsOneWidget);
      expect(find.text('אישור וסיום'), findsNothing);
      expect(server.auth, hasLength(1));
      await _selectBirth(tester, '15/06/1985');
      await _tap(tester, find.text('המשך'));
      expect(find.text('אישור וסיום'), findsOneWidget);
      expect(server.auth, hasLength(1));
      await _acceptConsents(tester);
      await _tap(tester, find.text('סיום הרשמה'));
      expect(server.auth, hasLength(2));
      expect(jsonDecode(server.auth.last.body)['birthDate'], '1985-06-15');
      expect(google.choiceCount, 1);
      expect(find.byType(DatePickerDialog), findsNothing);
    });
  });

  testWidgets(
      'new Google registration without a phone retains phone errors '
      'and enters conversations only after successful linking', (tester) async {
    final server = _Server()
      ..finishStatus = 200
      ..finishBody = {
        'token': 'signup-needs-phone',
        'user': {..._user, 'phone': null},
      };
    await _withFixture(tester, server, (google) async {
      await _finishSignup(tester, google);
      expect(find.byType(GooglePhoneSetupScreen), findsOneWidget);
      expect(find.byType(MainShell), findsNothing);
      expect(find.byType(GoogleDriveBackupOfferScreen), findsNothing);
      final phoneScreen = tester
          .widget<GooglePhoneSetupScreen>(find.byType(GooglePhoneSetupScreen));
      expect(phoneScreen.requireVerification, isFalse);
      expect(phoneScreen.offerDriveBackup, isFalse);
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      await tester.enterText(
          find.widgetWithText(TextField, 'מספר טלפון'), '123');
      await _tap(tester, find.text('שמור והיכנס'));
      expect(find.text('נא להזין מספר טלפון תקין'), findsOneWidget);
      expect(server.linkPhone, isEmpty);
      await tester.enterText(
          find.widgetWithText(TextField, 'מספר טלפון'), '0501234567');
      server.failLinkPhoneConnection = true;
      await _tap(tester, find.text('שמור והיכנס'));
      expect(find.text('שגיאת חיבור'), findsOneWidget);
      expect(find.byType(GooglePhoneSetupScreen), findsOneWidget);
      expect(find.byType(MainShell), findsNothing);
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      server.failLinkPhoneConnection = false;
      server.linkPhoneStatus = 422;
      server.linkPhoneBody = {'error': 'מספר הטלפון לא אושר'};
      await _tap(tester, find.text('שמור והיכנס'));
      expect(find.text('מספר הטלפון לא אושר'), findsOneWidget);
      expect(find.byType(GooglePhoneSetupScreen), findsOneWidget);
      expect(find.byType(MainShell), findsNothing);
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'מספר טלפון'))
              .controller!
              .text,
          '0501234567');
      server.linkPhoneStatus = 200;
      server.linkPhoneBody = {'token': 'linked-signup-session'};
      await _tap(tester, find.text('שמור והיכנס'));
      _expectConversations();
      expect(server.linkPhone, hasLength(3));
      for (final request in server.linkPhone) {
        expect(request.headers['authorization'], 'Bearer signup-needs-phone');
        expect(jsonDecode(request.body), {'phone': '0501234567'});
      }
      expect(server.sendOtp, isEmpty);
      expect(server.auth, hasLength(2));
      expect(server.verify, hasLength(1));
      expect(google.choiceCount, 1);
      expect((await SharedPreferences.getInstance()).getString('token'),
          'linked-signup-session');
    });
  });

  testWidgets(
      'existing account found during signup without a phone enters '
      'conversations after linking without opening the Drive offer',
      (tester) async {
    final server = _Server()
      ..verifyBody = {..._verified, 'existingAccount': true}
      ..finishStatus = 200
      ..finishBody = {
        'token': 'existing-signup-needs-phone',
        'user': {..._user, 'phone': ''},
      };
    await _withFixture(tester, server, (google) async {
      await _choose(tester, google);
      expect(find.byType(GooglePhoneSetupScreen), findsOneWidget);
      expect(
          tester
              .widget<GooglePhoneSetupScreen>(
                  find.byType(GooglePhoneSetupScreen))
              .offerDriveBackup,
          isFalse);
      expect(find.text('השלמת פרטים'), findsNothing);
      expect(server.auth, hasLength(2));
      expect(jsonDecode(server.auth.last.body), {'idToken': google.idToken});
      await tester.enterText(
          find.widgetWithText(TextField, 'מספר טלפון'), '0501234567');
      await _tap(tester, find.text('שמור והיכנס'));
      _expectConversations();
      expect(server.linkPhone, hasLength(1));
      expect(google.choiceCount, 1);
      // A successful link may keep the original session instead of rotating it.
      expect((await SharedPreferences.getInstance()).getString('token'),
          'existing-signup-needs-phone');
    });
  });

  testWidgets(
      'normal Google login without a phone keeps the legacy Drive '
      'offer after successful linking', (tester) async {
    final server = _Server()
      ..loginStatus = 200
      ..loginBody = {
        'token': 'login-needs-phone',
        'user': {..._user, 'phone': ''},
      };
    await _withFixture(tester, server, (google) async {
      await _choose(tester, google);
      expect(find.byType(GooglePhoneSetupScreen), findsOneWidget);
      expect(
          tester
              .widget<GooglePhoneSetupScreen>(
                  find.byType(GooglePhoneSetupScreen))
              .offerDriveBackup,
          isTrue);
      await tester.enterText(
          find.widgetWithText(TextField, 'מספר טלפון'), '0501234567');
      await _tap(tester, find.text('שמור והיכנס'));
      expect(find.byType(GoogleDriveBackupOfferScreen), findsOneWidget);
      expect(find.byType(MainShell), findsNothing);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(server.auth, hasLength(1));
      expect(server.verify, isEmpty);
      expect(server.linkPhone, hasLength(1));
      expect(server.sendOtp, isEmpty);
      expect((await SharedPreferences.getInstance()).getString('token'),
          'login-needs-phone');
    });
  });

  testWidgets(
      'signup phone OTP validates and retains failed attempts before '
      'entering conversations with the linked session', (tester) async {
    final server = _Server();
    await _withFixture(tester, server, (google) async {
      await tester.enterText(
          find.widgetWithText(TextField, 'מספר טלפון'), '0501234567');
      await _tapWhileWaitingForSms(tester, find.text('שלח קוד אימות'));
      expect(server.sendOtp, hasLength(1));
      expect(server.sendOtp.single.headers['authorization'],
          'Bearer otp-signup-session');
      expect(jsonDecode(server.sendOtp.single.body), {'phone': '0501234567'});
      expect(find.widgetWithText(TextField, 'קוד אימות'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'קוד אימות'), '12');
      await _tapWhileWaitingForSms(tester, find.text('אמת וכנס'));
      expect(find.text('נא להזין קוד בן 6 ספרות'), findsOneWidget);
      expect(server.linkPhone, isEmpty);
      await tester.enterText(
          find.widgetWithText(TextField, 'קוד אימות'), '123456');
      server.linkPhoneStatus = 400;
      server.linkPhoneBody = {'error': 'קוד האימות לא אושר'};
      await _tapWhileWaitingForSms(tester, find.text('אמת וכנס'));
      expect(find.text('קוד האימות לא אושר'), findsOneWidget);
      expect(find.byType(GooglePhoneSetupScreen), findsOneWidget);
      expect(find.byType(MainShell), findsNothing);
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      server.failLinkPhoneConnection = true;
      await _tapWhileWaitingForSms(tester, find.text('אמת וכנס'));
      expect(find.text('שגיאת חיבור'), findsOneWidget);
      expect(find.byType(GooglePhoneSetupScreen), findsOneWidget);
      expect(find.byType(GoogleDriveBackupOfferScreen), findsNothing);
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      server.failLinkPhoneConnection = false;
      server.linkPhoneStatus = 200;
      server.linkPhoneBody = {'token': 'verified-signup-session'};
      await _tapWhileWaitingForSms(tester, find.text('אמת וכנס'));
      await tester.pumpAndSettle();
      _expectConversations();
      expect(server.linkPhone, hasLength(3));
      for (final request in server.linkPhone) {
        expect(request.headers['authorization'], 'Bearer otp-signup-session');
        expect(jsonDecode(request.body),
            {'phone': '0501234567', 'code': '123456'});
      }
      expect(server.auth, isEmpty);
      expect(server.verify, isEmpty);
      expect(google.choiceCount, 0);
      expect((await SharedPreferences.getInstance()).getString('token'),
          'verified-signup-session');
    },
        home: const GooglePhoneSetupScreen(
            token: 'otp-signup-session', offerDriveBackup: false));
  });

  testWidgets('default phone OTP flow preserves the legacy Drive offer route',
      (tester) async {
    final server = _Server();
    await _withFixture(tester, server, (google) async {
      expect(
          tester
              .widget<GooglePhoneSetupScreen>(
                  find.byType(GooglePhoneSetupScreen))
              .offerDriveBackup,
          isTrue);
      await tester.enterText(
          find.widgetWithText(TextField, 'מספר טלפון'), '0501234567');
      await _tapWhileWaitingForSms(tester, find.text('שלח קוד אימות'));
      await tester.enterText(
          find.widgetWithText(TextField, 'קוד אימות'), '654321');
      await _tapWhileWaitingForSms(tester, find.text('אמת וכנס'));
      await tester.pumpAndSettle();
      expect(find.byType(GoogleDriveBackupOfferScreen), findsOneWidget);
      expect(find.byType(MainShell), findsNothing);
      expect(server.sendOtp, hasLength(1));
      expect(server.linkPhone, hasLength(1));
      expect(jsonDecode(server.linkPhone.single.body),
          {'phone': '0501234567', 'code': '654321'});
      expect((await SharedPreferences.getInstance()).getString('token'),
          'legacy-otp-session');
      expect(google.choiceCount, 0);
    }, home: const GooglePhoneSetupScreen(token: 'legacy-otp-session'));
  });

  testWidgets(
      'failed identity verification remains retryable and returning '
      'to login chooses a fresh Google credential', (tester) async {
    final server = _Server()
      ..verifyStatus = 503
      ..verifyBody = {'error': 'Verification temporarily unavailable'};
    await _withFixture(tester, server, (google) async {
      await _choose(tester, google);
      expect(find.text('הרשמה שלב אחר שלב'), findsOneWidget);
      expect(find.text('שלב 1 מתוך 4'), findsOneWidget);
      expect(find.textContaining('Verification temporarily unavailable'),
          findsOneWidget);
      expect(find.text('בחירת סינון'), findsNothing);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(google.choiceCount, 1);
      expect(server.auth, hasLength(1));
      expect(server.verify, hasLength(1));
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      await _tap(tester, find.widgetWithText(TextButton, 'כניסה'));
      google.idToken = 'fresh-google-token';
      google.email = 'fresh@example.invalid';
      server.finishStatus = 401;
      server.finishBody = {'error': 'Fresh account refused'};
      await _choose(tester, google);
      expect(server.auth, hasLength(2));
      expect(
          jsonDecode(server.auth.last.body)['idToken'], 'fresh-google-token');
      expect(google.choiceCount, 2);
      expect(server.verify, hasLength(1));
      expect(find.text('כניסה לחשבון'), findsOneWidget);
      expect(find.text('Fresh account refused'), findsOneWidget);
      _expectNoSessionOrProtectedScreens();
    });
  });

  testWidgets(
      'verification retry reuses the chosen account without Google '
      'selection, sign-out or account creation', (tester) async {
    final server = _Server()
      ..verifyStatus = 503
      ..verifyBody = {'error': 'Verification temporarily unavailable'};
    await _withFixture(tester, server, (google) async {
      await _choose(tester, google);
      expect(find.text('שלב 1 מתוך 4'), findsOneWidget);
      final signOuts = google.calls.where((call) => call == 'signOut').length;
      server.verifyStatus = 200;
      server.verifyBody = _verified;
      await _tap(tester, find.text('נסה שוב לאמת את חשבון Google שנבחר'));
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('בחירת סינון'), findsOneWidget);
      expect(find.textContaining('Verification temporarily unavailable'),
          findsNothing);
      expect(google.choiceCount, 1);
      expect(
          google.calls.where((call) => call == 'signOut'), hasLength(signOuts));
      expect(server.auth, hasLength(1));
      expect(server.verify, hasLength(2));
      for (final request in server.verify) {
        expect(jsonDecode(request.body), {'idToken': google.idToken});
      }
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      _expectNoSessionOrProtectedScreens();
    });
  });

  testWidgets(
      'returning from a fully consented draft to Google login chooses '
      'fresh identity and sends no stale registration fields', (tester) async {
    final server = _Server();
    await _withFixture(tester, server, (google) async {
      await _choose(tester, google);
      await _tap(tester, find.text('גברים'));
      await _tap(tester, find.text('אכיפת הסינון הכללי בכל המערכת'));
      await _fillDetails(tester);
      await _acceptConsents(tester);
      expect(server.auth, hasLength(1));
      await _tap(tester, find.widgetWithText(TextButton, 'כניסה'));
      expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'כתובת אימייל'))
              .controller!
              .text,
          'selected@example.invalid');
      google.idToken = 'another-google-token';
      google.email = 'another@example.invalid';
      server.finishStatus = 400;
      server.finishBody = _required;
      server.verifyBody = {
        ..._verified,
        'name': 'חשבון שני מאומת',
        'email': 'another@example.invalid'
      };
      await _choose(tester, google);
      expect(server.auth, hasLength(2));
      expect(jsonDecode(server.auth.last.body),
          {'idToken': 'another-google-token'});
      expect(server.verify, hasLength(2));
      expect(jsonDecode(server.verify.last.body),
          {'idToken': 'another-google-token'});
      expect(google.choiceCount, 2);
      expect(find.text('בחירת סינון'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse);
      expect(find.text('מותר'), findsNothing);
      await _tap(tester, find.text('המשך'));
      expect(
          tester
              .widget<TextField>(find.widgetWithText(TextField, 'שם מלא'))
              .controller!
              .text,
          'חשבון שני מאומת');
      expect(_birthSelection(tester), [null, null, null]);
      expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                  find.byType(DropdownButtonFormField<String>))
              .initialValue,
          isNull);
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      _expectNoSessionOrProtectedScreens();
    });
  });

  testWidgets(
      'registration-required at final signup does not reset chosen '
      'filters, profile details or consents', (tester) async {
    final server = _Server()
      ..finishStatus = 400
      ..finishBody = _required;
    await _withFixture(tester, server, (google) async {
      await _choose(tester, google);
      await _tap(tester, find.text('גברים'));
      final birthDate = await _fillDetails(tester);
      await _acceptConsents(tester);
      await _tap(tester, find.text('סיום הרשמה'));
      expect(find.text('אישור וסיום'), findsOneWidget);
      expect(find.text('שלב 4 מתוך 4'), findsOneWidget);
      expect(server.auth, hasLength(2));
      expect(server.verify, hasLength(1));
      expect(google.choiceCount, 1);
      for (final checkbox
          in tester.widgetList<Checkbox>(find.byType(Checkbox))) {
        expect(checkbox.value, isTrue);
      }
      await _tap(tester, find.text('חזרה'));
      expect(find.text('השלמת פרטים'), findsOneWidget);
      expect(_birthSelection(tester), [15, 6, 1985]);
      expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                  find.byType(DropdownButtonFormField<String>))
              .initialValue,
          'male');
      await _tap(tester, find.text('המשך'));
      await _tap(tester, find.text('סיום הרשמה'));
      expect(server.auth, hasLength(3));
      expect(jsonDecode(server.auth.last.body)['birthDate'], birthDate);
      expect(jsonDecode(server.auth.last.body)['contentFilter']['men'], isTrue);
      expect(server.verify, hasLength(1));
      expect(google.choiceCount, 1);
      _expectNoSessionOrProtectedScreens();
    });
  });

  testWidgets(
      'account found by verification after lookup race enters existing '
      'account without creating signup details', (tester) async {
    final server = _Server()
      ..verifyBody = {..._verified, 'existingAccount': true}
      ..finishStatus = 200
      ..finishBody = {'token': 'existing-race-session', 'user': _user};
    await _withFixture(tester, server, (google) async {
      await _choose(tester, google);
      expect(find.byType(MainShell), findsOneWidget);
      expect(find.text('השלמת פרטים'), findsNothing);
      expect(find.byType(GoogleDriveBackupOfferScreen), findsNothing);
      expect(server.auth, hasLength(2));
      expect(server.verify, hasLength(1));
      expect(google.choiceCount, 1);
      for (final request in server.auth) {
        expect(jsonDecode(request.body)['idToken'], google.idToken);
      }
      expect((await SharedPreferences.getInstance()).getString('token'),
          'existing-race-session');
    });
  });

  testWidgets(
      'pending Google login cannot switch tabs or start a second '
      'identity flow', (tester) async {
    final server = _Server()..loginGate = Completer<http.Response>();
    await _withFixture(tester, server, (google) async {
      await google.choose(tester);
      for (var i = 0; i < 30 && server.auth.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(server.auth, hasLength(1));
      expect(server.verify, isEmpty);
      await tester.tap(find.text('הרשמה'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('כניסה'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('כניסה לחשבון'), findsOneWidget);
      expect(find.text('הרשמה שלב אחר שלב'), findsNothing);
      expect(google.choiceCount, 1);
      expect(server.auth, hasLength(1));
      server.loginGate!.complete(_json(_required, 400));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('בחירת סינון'), findsOneWidget);
      expect(server.verify, hasLength(1));
      expect(google.choiceCount, 1);
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      _expectNoSessionOrProtectedScreens();
    });
  });

  testWidgets(
      'verification in flight and its success delay cannot exit the '
      'wizard through the login header', (tester) async {
    final server = _Server()..verificationGate = Completer<http.Response>();
    await _withFixture(tester, server, (google) async {
      await google.choose(tester);
      for (var i = 0; i < 30 && server.verify.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(server.verify, hasLength(1));
      final login = find.widgetWithText(TextButton, 'כניסה');
      expect(tester.widget<TextButton>(login).onPressed, isNull);
      await tester.tap(login);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('הרשמה שלב אחר שלב'), findsOneWidget);
      expect(find.text('כניסה לחשבון'), findsNothing);
      server.verificationGate!.complete(_json(_verified));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('האימות הצליח!'), findsOneWidget);
      expect(tester.widget<TextButton>(login).onPressed, isNull);
      await tester.tap(login);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('הרשמה שלב אחר שלב'), findsOneWidget);
      expect(find.text('כניסה לחשבון'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('בחירת סינון'), findsOneWidget);
      expect(tester.widget<TextButton>(login).onPressed, isNotNull);
      expect(server.auth, hasLength(1));
      expect(server.verify, hasLength(1));
      expect(google.choiceCount, 1);
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      _expectNoSessionOrProtectedScreens();
    });
  });

  testWidgets(
      'late verification after leaving auth never reopens registration '
      'or creates a session', (tester) async {
    final server = _Server()..verificationGate = Completer<http.Response>();
    await _withFixture(tester, server, (google) async {
      await google.choose(tester);
      for (var i = 0; i < 20 && server.verify.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(server.verify, hasLength(1));
      expect(google.choiceCount, 1);
      await tester.pumpWidget(const MaterialApp(home: Text('Auth closed')));
      server.verificationGate!.complete(_json(_verified));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Auth closed'), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
      expect(server.auth, hasLength(1));
      expect(server.verify, hasLength(1));
      expect(
          (await SharedPreferences.getInstance()).getString('token'), isNull);
      expect(tester.takeException(), isNull);
    });
  });
}
