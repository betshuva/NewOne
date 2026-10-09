import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _enforcementTitle = 'אכיפת הסינון הכללי בכל המערכת';
const _filter = {
  'text': true,
  'nonHumanImages': true,
  'men': true,
  'women': false,
  'children': false,
  'video': true,
  'enforceGeneralFilter': true,
};

http.Response _json(Object data, {int status = 200}) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Widget _app(Widget home) => MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansHebrew'),
      home: Directionality(textDirection: TextDirection.rtl, child: home),
    );

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _withNewRegistration(
  WidgetTester tester,
  Future<void> Function(List<http.Request> requests, List<String> googleCalls)
      check,
) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  const channel = MethodChannel('plugins.flutter.io/google_sign_in');
  final googleCalls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
      (call) async {
    googleCalls.add(call.method);
    if (call.method == 'signIn') {
      return {
        'id': 'new-google-user',
        'email': 'new@example.invalid',
        'displayName': 'משתמש חדש',
        'idToken': 'google-credential',
      };
    }
    if (call.method == 'getTokens') {
      return {'idToken': 'google-credential', 'accessToken': 'test-access'};
    }
    return null;
  });
  final requests = <http.Request>[];
  try {
    await http.runWithClient(() async {
      await tester
          .pumpWidget(_app(const AuthScreen(initialRegistration: true)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('הרשמה באמצעות Google').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1400));
      await tester.pumpAndSettle();
      expect(find.text('בחירת סינון'), findsOneWidget);
      await check(requests, googleCalls);
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
            if (request.url.path.endsWith('/filter-pin')) return http.Response(jsonEncode({'configured': false, 'unlocked': true}), 200, headers: {'content-type': 'application/json'});
              requests.add(request);
              if (request.url.path.endsWith('/registration/verify-google')) {
                return _json({
                  'ok': true,
                  'existingAccount': false,
                  'name': 'משתמש חדש',
                  'email': 'new@example.invalid',
                });
              }
              if (request.url.path.endsWith('/auth/google')) {
                // Keep the actual request observable without navigating to Drive setup.
                return _json({
                  'code': 'AGE_RESTRICTED',
                  'error': 'השירות זמין לבני 18 ומעלה בלבד',
                }, status: 403);
              }
              return _json({});
            }));
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // The browser test host does not serve the app's native font assets.
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('settings put filtering before profile and both links still open',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await http.runWithClient(() async {
      await tester.pumpWidget(_app(SettingsScreen(
        me: const {'id': 'settings-user', 'name': 'משתמש הגדרות'},
        token: 'settings-token',
        onBack: () {},
        onLogout: () {},
        onAccountDeleted: () async {},
        onProfileChanged: () async {},
      )));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('סוגי תוכן מותרים')).dy,
          lessThan(tester.getTopLeft(find.text('ערוך פרופיל')).dy));
      await _tap(tester, find.text('סוגי תוכן מותרים'));
      expect(find.byType(ContentFilterSettingsScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await _tap(tester, find.text('ערוך פרופיל'));
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async {
            if (request.url.path.endsWith('/filter-pin')) return http.Response(jsonEncode({'configured': false, 'unlocked': true}), 200, headers: {'content-type': 'application/json'});
              if (request.url.path.endsWith('/filter-settings'))
                return _json(_filter);
              if (request.url.path.endsWith('/profile')) {
                return _json({'id': 'settings-user', 'name': 'משתמש הגדרות'});
              }
              return _json({});
            }));
  });

  testWidgets('general filtering puts enforcement last and saves chosen values',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final updates = <http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(_app(Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) =>
                    const ContentFilterSettingsScreen(token: 'filter-token'))),
            child: const Text('פתח סינון לבדיקה'),
          ),
        ),
      )));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('פתח סינון לבדיקה'));
      for (final category in ['גברים', 'נשים', 'ילדים', 'וידאו']) {
        expect(tester.getTopLeft(find.text(category)).dy,
            lessThan(tester.getTopLeft(find.text(_enforcementTitle)).dy));
      }
      await _tap(tester, find.text('וידאו'));
      await _tap(tester, find.text(_enforcementTitle));
      await _tap(tester, find.text('שמור הגדרות'));
      expect(updates, hasLength(1));
      expect(updates.single.headers['authorization'], 'Bearer filter-token');
      expect(jsonDecode(updates.single.body), {
        ..._filter,
        'video': false,
        'enforceGeneralFilter': false,
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async {
            if (request.url.path.endsWith('/filter-pin')) return http.Response(jsonEncode({'configured': false, 'unlocked': true}), 200, headers: {'content-type': 'application/json'});
              if (request.method == 'PUT') {
                updates.add(request);
                return _json({'ok': true});
              }
              return _json(_filter);
            }));
  });

  testWidgets(
      'Google signup filters first, retains choices, validates details '
      'and waits for age and terms before saving', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _withNewRegistration(tester, (requests, googleCalls) async {
      final authRequests = () => requests
          .where((request) => request.url.path.endsWith('/auth/google'));
      expect(find.text('השלמת פרטים'), findsNothing);
      expect(find.text('שלב 2 מתוך 4'), findsOneWidget);
      for (final category in ['גברים', 'נשים', 'ילדים', 'וידאו']) {
        expect(tester.getTopLeft(find.text(category)).dy,
            lessThan(tester.getTopLeft(find.text(_enforcementTitle)).dy));
      }
      await _tap(tester, find.text('גברים'));
      await _tap(tester, find.text('וידאו'));
      await _tap(tester, find.text(_enforcementTitle));
      await _tap(tester, find.text('המשך'));
      expect(find.text('השלמת פרטים'), findsOneWidget);
      expect(find.text('שלב 3 מתוך 4'), findsOneWidget);
      expect(authRequests(), isEmpty);

      final name = find.widgetWithText(TextField, 'שם מלא');
      await tester.enterText(name, '');
      await _tap(tester, find.text('המשך'));
      expect(find.text('נא להזין שם מלא'), findsOneWidget);
      await tester.enterText(name, 'משתמש חדש');
      await _tap(tester, find.text('המשך'));
      expect(find.text('יש להזין תאריך לידה תקין'), findsOneWidget);
      for (final pair in [('שנה', 1985), ('חודש', 6), ('יום', 15)]) {
        tester
            .widget<DropdownButtonFormField<int>>(
                find.widgetWithText(DropdownButtonFormField<int>, pair.$1))
            .onChanged!(pair.$2);
        await tester.pumpAndSettle();
      }
      await tester.pumpAndSettle();
      const birthDate = '1985-06-15';
      await _tap(tester, find.text('המשך'));
      expect(find.text('יש לבחור מגדר'), findsOneWidget);
      await _tap(tester, find.byType(DropdownButtonFormField<String>));
      await _tap(tester, find.text('זכר').last);

      await _tap(tester, find.text('חזרה'));
      expect(find.text('בחירת סינון'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);
      expect(find.text('מותר'), findsNWidgets(2));
      expect(googleCalls.where((call) => call == 'signIn'), hasLength(1));
      await _tap(tester, find.text('המשך'));
      expect(tester.widget<TextField>(name).controller!.text, 'משתמש חדש');
      expect(
          ['יום', 'חודש', 'שנה']
              .map((label) => tester
                  .widget<DropdownButtonFormField<int>>(
                      find.widgetWithText(DropdownButtonFormField<int>, label))
                  .initialValue)
              .toList(),
          [15, 6, 1985]);
      expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                  find.byType(DropdownButtonFormField<String>))
              .initialValue,
          'male');
      await _tap(tester, find.text('המשך'));
      expect(find.text('אישור וסיום'), findsOneWidget);
      expect(find.text('שלב 4 מתוך 4'), findsOneWidget);
      await _tap(tester, find.text('סיום הרשמה'));
      expect(authRequests(), isEmpty);
      expect(find.textContaining('יש לאשר גיל 18 ומעלה'), findsOneWidget);
      await _tap(tester, find.byType(Checkbox).first);
      await _tap(tester, find.text('סיום הרשמה'));
      expect(authRequests(), isEmpty);
      await _tap(tester, find.byType(Checkbox).last);
      await _tap(tester, find.text('סיום הרשמה'));
      expect(authRequests(), hasLength(1));
      final saved = jsonDecode(authRequests().single.body) as Map;
      expect(saved['idToken'], 'google-credential');
      expect(saved['birthDate'], birthDate);
      expect(saved['gender'], 'male');
      expect(saved['acceptedTerms'], isTrue);
      expect(saved['ageConfirmed'], isTrue);
      expect(saved['contentFilterConfirmed'], isTrue);
      expect(saved['contentFilter'], {
        'text': true,
        'nonHumanImages': true,
        'men': true,
        'women': false,
        'children': false,
        'video': true,
        'enforceGeneralFilter': true,
      });
      expect(find.text('השירות זמין לבני 18 ומעלה בלבד'), findsOneWidget);
      expect(find.byType(MainShell), findsNothing);
      expect(find.byType(GoogleDriveBackupOfferScreen), findsNothing);
    });
  },
      skip:
          kIsWeb); // GIS web owns its sign-in flow; do not fake its DOM widget.

  testWidgets('back from the first filtering step returns to Google identity',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _withNewRegistration(tester, (requests, googleCalls) async {
      await _tap(tester, find.text('חזרה'));
      expect(find.text('בחירת סינון'), findsNothing);
      expect(find.text('הרשמה באמצעות Google'), findsWidgets);
      expect(find.text('שלב 1 מתוך 4'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(
          requests
              .where((request) => request.url.path.endsWith('/auth/google')),
          isEmpty);
      expect(googleCalls.where((call) => call == 'signIn'), hasLength(1));
    });
  }, skip: kIsWeb);
}
