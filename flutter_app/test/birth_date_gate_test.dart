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

Finder get _birthDateField => find.widgetWithText(TextField, 'תאריך לידה');

String _birthDateText(WidgetTester tester) =>
    tester.widget<TextField>(_birthDateField).controller!.text;

String _typedDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

Future<void> _enterBirthDate(WidgetTester tester,
    {String value = '15/06/1985'}) async {
  await tester.enterText(_birthDateField, value);
  await tester.pumpAndSettle();
  expect(_birthDateText(tester), value);
  expect(find.byType(DatePickerDialog), findsNothing);
}

ElevatedButton _button(WidgetTester tester, String label) =>
    tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, label));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    // Chrome's widget-test host does not serve the native font assets.
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  testWidgets('underage saved session shows restriction without loading chats',
      (tester) async {
    await _withGate(
        tester, (_) async => _json({'code': 'AGE_RESTRICTED'}, status: 403),
        (requests) async {
      expect(find.text('השירות לבני 18 ומעלה'), findsOneWidget);
      expect(find.byType(ConversationsScreen), findsNothing);
      expect(_birthDateField, findsNothing);
      expect(find.text('נסה שוב'), findsNothing);
      expect(find.text('כניסה מחדש'), findsOneWidget);
      expect(requests.length, 1);
    });
  });

  final now = DateTime.now();
  final invalidDates = [
    (name: 'incomplete date', value: '15/06'),
    (name: 'nonexistent day', value: '31/02/1985'),
    (name: 'minor', value: _typedDate(DateTime(now.year - 17, 1, 1))),
    (name: 'future date', value: _typedDate(now.add(const Duration(days: 1)))),
    (name: 'older than120', value: _typedDate(DateTime(now.year - 121, 1, 1))),
  ];
  for (final invalid in invalidDates) {
    testWidgets('typed ${invalid.name} cannot submit birth date or load chats',
        (tester) async {
      await _withGate(tester, (_) async => _json({'birthDateMissing': true}),
          (requests) async {
        await _enterBirthDate(tester, value: invalid.value);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.tap(find.text('שמירה והמשך'));
        await tester.pumpAndSettle();
        expect(find.text('השלמת הגנת גיל'), findsOneWidget);
        expect(find.byType(ConversationsScreen), findsNothing);
        expect(requests.where((request) => request.method == 'PUT'), isEmpty);
        expect(requests, hasLength(1));
        expect(find.byType(DatePickerDialog), findsNothing);
      });
    });
  }

  testWidgets('adult birth date typed on the18year boundary submits ISO date',
      (tester) async {
    var saved = false;
    final today = DateTime.now();
    final birth = DateTime(today.year - 18, today.month, today.day);
    final iso = '${birth.year.toString().padLeft(4, '0')}-'
        '${birth.month.toString().padLeft(2, '0')}-'
        '${birth.day.toString().padLeft(2, '0')}';
    await _withGate(tester, (request) async {
      if (request.method == 'PUT') {
        expect(jsonDecode(request.body), {'birthDate': iso});
        expect(request.headers['authorization'], 'Bearer account-a');
        saved = true;
        return _json({'ok': true});
      }
      return _json({'birthDateMissing': !saved});
    }, (requests) async {
      await _enterBirthDate(tester, value: _typedDate(birth));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.tap(find.text('שמירה והמשך'));
      await tester.pumpAndSettle();
      expect(
          requests.where((request) => request.method == 'PUT'), hasLength(1));
      expect(find.byType(ConversationsScreen), findsOneWidget);
    });
  });

  testWidgets(
      'editing a valid date to invalid or empty cannot submit stale date',
      (tester) async {
    await _withGate(tester, (_) async => _json({'birthDateMissing': true}),
        (requests) async {
      for (final invalid in ['31/02/1985', '']) {
        await _enterBirthDate(tester);
        await _enterBirthDate(tester, value: invalid);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.tap(find.text('שמירה והמשך'));
        await tester.pumpAndSettle();
        expect(find.text('השלמת הגנת גיל'), findsOneWidget);
        expect(find.byType(ConversationsScreen), findsNothing);
        expect(requests.where((request) => request.method == 'PUT'), isEmpty);
      }
      expect(requests, hasLength(1));
    });
  });

  testWidgets('pending birth-date save closes focused keyboard editing',
      (tester) async {
    final pending = Completer<http.Response>();
    var saved = false;
    await _withGate(tester, (request) async {
      if (request.method == 'PUT') {
        expect(jsonDecode(request.body), {'birthDate': '1985-06-15'});
        return pending.future;
      }
      return _json({'birthDateMissing': !saved});
    }, (requests) async {
      await _enterBirthDate(tester);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await tester.tap(find.text('שמירה והמשך'));
      await tester.pump();
      expect(
          requests.where((request) => request.method == 'PUT'), hasLength(1));
      expect(tester.widget<TextField>(_birthDateField).enabled, isFalse);
      expect(
          tester
              .widget<EditableText>(find.descendant(
                  of: _birthDateField, matching: find.byType(EditableText)))
              .readOnly,
          isTrue);
      expect(tester.testTextInput.hasAnyClients, isFalse,
          reason: 'Pending save must close the focused input connection');
      expect(_birthDateText(tester), '15/06/1985');
      expect(find.byType(ConversationsScreen), findsNothing);
      saved = true;
      pending.complete(_json({'ok': true}));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationsScreen), findsOneWidget);
      expect(
          requests.where((request) => request.method == 'PUT'), hasLength(1));
    });
  });

  testWidgets('concurrent saved date is rechecked before entering the app',
      (tester) async {
    var checks = 0;
    await _withGate(tester, (request) async {
      if (request.method == 'PUT') {
        return _json({'code': 'BIRTH_DATE_ALREADY_SET'}, status: 409);
      }
      return ++checks == 1
          ? _json({'birthDateMissing': true})
          : _json({'code': 'AGE_RESTRICTED'}, status: 403);
    }, (_) async {
      await _enterBirthDate(tester);
      await tester.tap(find.text('שמירה והמשך'));
      await tester.pumpAndSettle();
      expect(checks, 2);
      expect(find.text('השירות לבני 18 ומעלה'), findsOneWidget);
      expect(find.byType(ConversationsScreen), findsNothing);
    });
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
      if (request.method == 'GET')
        return _json({'birthDateMissing': saves < 2});
      submittedDates.add(jsonDecode(request.body)['birthDate'] as String);
      saves++;
      if (saves == 1) return firstSave.future;
      return _json({'ok': true});
    }, (_) async {
      await _enterBirthDate(tester);
      final save = _button(tester, 'שמירה והמשך').onPressed!;
      save();
      save();
      await tester.pump();
      expect(saves, 1);
      firstSave.complete(http.Response('Too many requests', 429,
          headers: {'retry-after': '2'}));
      await tester.pumpAndSettle();
      expect(_birthDateText(tester), '15/06/1985');
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
      await _enterBirthDate(tester);
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
      var saved = false;
      await _withGate(tester, (request) async {
        if (request.method == 'PUT') saved = alreadySet;
        return request.method == 'GET'
            ? _json({'birthDateMissing': !saved})
            : _json({
                'code':
                    alreadySet ? 'BIRTH_DATE_ALREADY_SET' : 'OTHER_CONFLICT',
                'error': 'לא ניתן לשמור',
              }, status: 409);
      }, (_) async {
        await _enterBirthDate(tester);
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
      await _enterBirthDate(tester);
      await tester.pumpWidget(_app(token: 'account-b'));
      await tester.pumpAndSettle();
      expect(_birthDateText(tester), isEmpty);
      await tester.pumpWidget(_app());
      await tester.pump();
      await tester.pumpWidget(_app(token: 'account-b'));
      await tester.pumpAndSettle();
      oldCheck.complete(_json({'birthDateMissing': false}));
      await tester.pumpAndSettle();
      expect(find.text('השלמת הגנת גיל'), findsOneWidget);
      expect(find.byType(ConversationsScreen), findsNothing);
      expect(_birthDateText(tester), isEmpty);
    });
  });

  testWidgets('account change discards old birth-date save completion',
      (tester) async {
    final oldSave = Completer<http.Response>();
    await _withGate(tester, (request) async {
      if (request.method == 'PUT') return oldSave.future;
      return _json({'birthDateMissing': true});
    }, (_) async {
      await _enterBirthDate(tester);
      await tester.tap(find.text('שמירה והמשך'));
      await tester.pump();
      await tester.pumpWidget(_app(token: 'account-b'));
      await tester.pumpAndSettle();
      expect(_birthDateText(tester), isEmpty);
      oldSave.complete(_json({'ok': true}));
      await tester.pumpAndSettle();
      expect(find.text('השלמת הגנת גיל'), findsOneWidget);
      expect(find.byType(ConversationsScreen), findsNothing);
    });
  });
}
