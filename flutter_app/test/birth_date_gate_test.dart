import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object data, {int status = 200, String? retryAfter}) =>
    http.Response(jsonEncode(data), status, headers: {
      'content-type': 'application/json; charset=utf-8',
      if (retryAfter != null) 'retry-after': retryAfter,
    });

Widget _app({String token = 'account-a'}) => MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansHebrew'),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: MainShell(token: token),
      ),
    );

Future<void> _withGate(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) respond,
  Future<void> Function(List<http.Request>) check,
) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  SharedPreferences.setMockInitialValues({'token': 'account-a'});
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <http.Request>[];
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await check(requests);
      expect(tester.takeException(), isNull);
    } finally {
      for (final shell in tester
          .widgetList<ConversationsScreen>(find.byType(ConversationsScreen))) {
        shell.socket?.disconnect();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      debugDefaultTargetPlatformOverride = null;
    }
  },
      () => MockClient((request) async {
            requests.add(request);
            final path = request.url.path;
            if (path.endsWith('/registration-status') ||
                path.endsWith('/profile/birth-date')) {
              return respond(request);
            }
            if (path.endsWith('/profile')) {
              return _json({'id': 'gate-user', 'name': 'משתמש בדיקה'});
            }
            if (path.endsWith('/users') ||
                path.endsWith('/groups') ||
                path.endsWith('/message-requests') ||
                path.endsWith('/messages') ||
                path.contains('/messages/')) {
              return _json([]);
            }
            if (path.endsWith('/filter-settings') ||
                path.endsWith('/receiving-filter')) {
              return _json({
                'filter': {
                  for (final kind in [
                    'text',
                    'video',
                    'nonHumanImages',
                    'men',
                    'women',
                    'children'
                  ])
                    kind: true,
                },
                'requiresChoice': false,
              });
            }
            return _json({});
          }));
}

Future<void> _selectBirthDate(WidgetTester tester) async {
  await tester.tap(find.text('יש לבחור תאריך'));
  await tester.pumpAndSettle();
  final context = tester.element(find.byType(DatePickerDialog));
  await tester.tap(find.text(MaterialLocalizations.of(context).okButtonLabel));
  await tester.pumpAndSettle();
  expect(find.text('יש לבחור תאריך'), findsNothing);
}

ElevatedButton _button(WidgetTester tester, String label) =>
    tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, label));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  testWidgets('status 429 waits for Retry-After then manually rechecks account',
      (tester) async {
    var checks = 0;
    await _withGate(tester, (request) async {
      expect(request.method, 'GET');
      checks++;
      return checks == 1
          ? _json({'error': 'עומס בקשות'}, status: 429, retryAfter: '2')
          : _json({'birthDateMissing': false});
    }, (requests) async {
      expect(find.text('בדיקת פרטי החשבון'), findsOneWidget);
      expect(find.text('השלמת הגנת גיל'), findsNothing);
      expect(find.byType(ConversationsScreen), findsNothing);
      expect(_button(tester, 'ניסיון נוסף בעוד 2 שניות').onPressed, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(_button(tester, 'ניסיון נוסף בעוד 1 שניות').onPressed, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(_button(tester, 'נסה שוב').onPressed, isNotNull);
      expect(checks, 1);
      await tester.tap(find.text('נסה שוב'));
      await tester.pumpAndSettle();
      expect(checks, 2);
      expect(find.byType(ConversationsScreen), findsOneWidget);
      expect(requests.where((request) => request.method == 'PUT'), isEmpty);
    });
  });

  testWidgets('connection error retries to actual missing date form',
      (tester) async {
    var checks = 0;
    await _withGate(tester, (request) async {
      if (++checks == 1) throw http.ClientException('offline');
      return _json({'birthDateMissing': true});
    }, (_) async {
      expect(find.text('בדיקת פרטי החשבון'), findsOneWidget);
      expect(find.text('השלמת הגנת גיל'), findsNothing);
      await tester.tap(find.text('נסה שוב'));
      await tester.pumpAndSettle();
      expect(find.text('השלמת הגנת גיל'), findsOneWidget);
      expect(find.byType(ConversationsScreen), findsNothing);
      expect(checks, 2);
    });
  });

  testWidgets('status rate limit accepts an HTTP-date Retry-After',
      (tester) async {
    var checks = 0;
    await _withGate(tester, (_) async {
      checks++;
      return _json({},
          status: 429,
          retryAfter:
              formatHttpDate(DateTime.now().add(const Duration(seconds: 3))));
    }, (_) async {
      final retry = find.byType(ElevatedButton);
      expect(tester.widget<ElevatedButton>(retry).onPressed, isNull);
      expect(find.textContaining('ניסיון נוסף בעוד'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(_button(tester, 'נסה שוב').onPressed, isNotNull);
      expect(checks, 1);
    });
  });

  for (final invalid in [
    ('server failure', http.Response('<html>unavailable</html>', 503)),
    ('empty status', _json({})),
    ('invalid status type', _json({'birthDateMissing': 'false'})),
    ('non-object status', _json([])),
  ]) {
    testWidgets('${invalid.$1} cannot enter app or invent missing birth date',
        (tester) async {
      await _withGate(tester, (_) async => invalid.$2, (requests) async {
        expect(find.text('בדיקת פרטי החשבון'), findsOneWidget);
        expect(find.text('השלמת הגנת גיל'), findsNothing);
        expect(find.byType(ConversationsScreen), findsNothing);
        expect(_button(tester, 'נסה שוב').onPressed, isNotNull);
        expect(requests.length, 1);
      });
    });
  }

  testWidgets('401 offers sign-in without requiring another date of birth',
      (tester) async {
    await _withGate(tester, (_) async => _json({}, status: 401), (_) async {
      expect(find.text('כניסה מחדש'), findsOneWidget);
      expect(find.text('השלמת הגנת גיל'), findsNothing);
      expect(find.byType(ConversationsScreen), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), 'account-a');
      await tester.tap(find.text('כניסה מחדש'));
      await tester.pumpAndSettle();
      expect(find.byType(AuthScreen), findsOneWidget);
      expect(prefs.getString('token'), isNull);
    });
  });

  testWidgets(
      'save preserves chosen date after 429 and prevents duplicate taps',
      (tester) async {
    var saves = 0;
    final firstSave = Completer<http.Response>();
    final submittedDates = <String>[];
    await _withGate(tester, (request) async {
      if (request.method == 'GET') return _json({'birthDateMissing': true});
      submittedDates.add(jsonDecode(request.body)['birthDate'] as String);
      saves++;
      if (saves == 1) return firstSave.future;
      return _json({'ok': true});
    }, (_) async {
      await _selectBirthDate(tester);
      final save = _button(tester, 'שמירה והמשך').onPressed!;
      save();
      save();
      await tester.pump();
      expect(saves, 1);
      firstSave.complete(http.Response('Too many requests', 429,
          headers: {'retry-after': '2'}));
      await tester.pumpAndSettle();
      expect(find.text('יש לבחור תאריך'), findsNothing);
      expect(find.byType(ConversationsScreen), findsNothing);
      expect(_button(tester, 'שמירה אפשרית בעוד 2 שניות').onPressed, isNull);
      save();
      await tester.pump();
      expect(saves, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(saves, 1);
      expect(_button(tester, 'שמירה והמשך').onPressed, isNotNull);
      await tester.tap(find.text('שמירה והמשך'));
      await tester.pumpAndSettle();
      expect(saves, 2);
      expect(submittedDates[0], submittedDates[1]);
      expect(find.byType(ConversationsScreen), findsOneWidget);
    });
  });

  testWidgets('save rate limit supports retryAfterSeconds JSON',
      (tester) async {
    await _withGate(tester, (request) async {
      return request.method == 'GET'
          ? _json({'birthDateMissing': true})
          : _json({'error': 'נא להמתין', 'retryAfterSeconds': 2}, status: 429);
    }, (_) async {
      await _selectBirthDate(tester);
      await tester.tap(find.text('שמירה והמשך'));
      await tester.pumpAndSettle();
      expect(find.text('נא להמתין'), findsOneWidget);
      expect(_button(tester, 'שמירה אפשרית בעוד 2 שניות').onPressed, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(_button(tester, 'שמירה והמשך').onPressed, isNotNull);
    });
  });

  for (final alreadySet in [false, true]) {
    testWidgets(
        '409 completes only with authenticated already-set code $alreadySet',
        (tester) async {
      await _withGate(tester, (request) async {
        return request.method == 'GET'
            ? _json({'birthDateMissing': true})
            : _json({
                'code':
                    alreadySet ? 'BIRTH_DATE_ALREADY_SET' : 'OTHER_CONFLICT',
                'error': 'לא ניתן לשמור',
              }, status: 409);
      }, (_) async {
        await _selectBirthDate(tester);
        await tester.tap(find.text('שמירה והמשך'));
        await tester.pumpAndSettle();
        expect(find.byType(ConversationsScreen),
            alreadySet ? findsOneWidget : findsNothing);
        expect(find.text('השלמת הגנת גיל'),
            alreadySet ? findsNothing : findsOneWidget);
      });
    });
  }

  testWidgets('account change discards earlier pending registration response',
      (tester) async {
    final oldCheck = Completer<http.Response>();
    var initialCheck = true;
    await _withGate(tester, (request) async {
      if (request.headers['Authorization'] == 'Bearer account-a') {
        if (initialCheck) {
          initialCheck = false;
          return _json({'birthDateMissing': true});
        }
        return oldCheck.future;
      }
      return _json({'birthDateMissing': true});
    }, (_) async {
      await _selectBirthDate(tester);
      await tester.pumpWidget(_app(token: 'account-b'));
      await tester.pumpAndSettle();
      expect(find.text('יש לבחור תאריך'), findsOneWidget);
      await tester.pumpWidget(_app());
      await tester.pump();
      await tester.pumpWidget(_app(token: 'account-b'));
      await tester.pumpAndSettle();
      oldCheck.complete(_json({'birthDateMissing': false}));
      await tester.pumpAndSettle();
      expect(find.text('השלמת הגנת גיל'), findsOneWidget);
      expect(find.byType(ConversationsScreen), findsNothing);
      expect(find.text('יש לבחור תאריך'), findsOneWidget);
    });
  });

  testWidgets('account change discards old birth-date save completion',
      (tester) async {
    final oldSave = Completer<http.Response>();
    await _withGate(tester, (request) async {
      if (request.method == 'PUT') return oldSave.future;
      return _json({'birthDateMissing': true});
    }, (_) async {
      await _selectBirthDate(tester);
      await tester.tap(find.text('שמירה והמשך'));
      await tester.pump();
      await tester.pumpWidget(_app(token: 'account-b'));
      await tester.pumpAndSettle();
      expect(find.text('יש לבחור תאריך'), findsOneWidget);
      oldSave.complete(_json({'ok': true}));
      await tester.pumpAndSettle();
      expect(find.text('השלמת הגנת גיל'), findsOneWidget);
      expect(find.byType(ConversationsScreen), findsNothing);
    });
  });
}
