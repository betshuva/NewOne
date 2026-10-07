import 'dart:convert';

import 'package:betshuva/filter_history.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _blocked = <String, bool>{
  'text': false,
  'video': false,
  'nonHumanImages': false,
  'men': false,
  'women': false,
  'children': false,
};

const _assistants = {
  kSystemGuideId: 'ישראל מדריך בתשובה',
  kSafeInformationAiId: 'מידע בטוח AI',
};

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

http.Response _staleResponse(http.Request request,
    {bool receivingTextAllowed = false}) {
  final path = request.url.path;
  if (request.method == 'GET' && path.contains('/messages/')) {
    return _json([]);
  }
  if (path.endsWith('/receiving-filter')) {
    return _json({
      'filter': {..._blocked, 'text': receivingTextAllowed}
    });
  }
  if (path.endsWith('/filter-settings')) {
    return _json({'filter': _blocked, 'requiresChoice': true});
  }
  if (path.endsWith('/filter-comparison')) {
    return _json({
      'recipientFilter': _blocked,
      'personalFilter': _blocked,
      'counterpartFilterAvailable': false,
    });
  }
  return _json({});
}

Widget _chat(String id, String name) => MaterialApp(
      home: ChatScreen(
        token: 'token',
        me: const {'id': 'viewer'},
        recipient: {'id': id, 'name': name},
        socket: null,
        embedded: true,
      ),
    );

void _prepare(WidgetTester tester) {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _disposeChat(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  expect(tester.takeException(), isNull);
}

void main() {
  for (final assistant in _assistants.entries) {
    testWidgets('${assistant.value} status is all allowed and read-only',
        (tester) async {
      _prepare(tester);
      final writes = <http.Request>[];
      await http.runWithClient(() async {
        await tester.pumpWidget(_chat(assistant.key, assistant.value));
        await tester.pumpAndSettle();
        expect(find.byTooltip('כל סוגי התוכן מותרים'), findsOneWidget);

        await tester.tap(find.byIcon(Icons.shield_outlined));
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        expect(find.text('מצב הסינון מול ${assistant.value}'), findsOneWidget);
        expect(find.text('מה מותר לשלוח'), findsOneWidget);
        expect(find.text('איזה תוכן אני מוכן לקבל'), findsOneWidget);
        expect(find.descendant(of: dialog, matching: find.text('מותר')),
            findsNWidgets(8));
        expect(
            find.descendant(
                of: dialog, matching: find.byIcon(Icons.check_circle)),
            findsNWidgets(8));
        expect(find.text('חסום'), findsNothing);
        expect(find.textContaining('לאחר אישור הקשר'), findsNothing);
        expect(find.text('שמור'), findsNothing);
        expect(find.byIcon(Icons.save_outlined), findsNothing);
        expect(find.descendant(of: dialog, matching: find.byType(InkWell)),
            findsOneWidget);
        expect(writes, isEmpty);
        await tester.tap(find.text('סגור'));
        await tester.pumpAndSettle();
        await _disposeChat(tester);
      },
          () => MockClient((request) async {
                if (request.url.path.endsWith('/filter-settings') &&
                    request.method != 'GET') {
                  writes.add(request);
                }
                return _staleResponse(request);
              }));
    });

    testWidgets('${assistant.value} sends after refresh without filter choice',
        (tester) async {
      _prepare(tester);
      final sent = <http.Request>[];
      final filterWrites = <http.Request>[];
      await http.runWithClient(() async {
        await tester.pumpWidget(_chat(assistant.key, assistant.value));
        await tester.pumpAndSettle();
        receivingFilterChanges.add('token');
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'הודעת ניסיון');
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        expect(find.textContaining('בחירת התוכן שאקבל'), findsNothing);
        expect(find.textContaining('חסום בהגדרות'), findsNothing);
        expect(sent, hasLength(1));
        expect(jsonDecode(sent.single.body),
            containsPair('toUserId', assistant.key));
        expect(
            jsonDecode(sent.single.body), containsPair('text', 'הודעת ניסיון'));
        expect(filterWrites, isEmpty);
        expect(find.byTooltip('כל סוגי התוכן מותרים'), findsOneWidget);
        await _disposeChat(tester);
      },
          () => MockClient((request) async {
                if (request.url.path.endsWith('/messages') &&
                    request.method == 'POST') {
                  sent.add(request);
                  return _json({'id': 'sent-message', 'status': 'sent'});
                }
                if (request.url.path.endsWith('/filter-settings') &&
                    request.method != 'GET') {
                  filterWrites.add(request);
                }
                return _staleResponse(request);
              }));
    });

    testWidgets('${assistant.value} capture actions ignore stale restrictions',
        (tester) async {
      _prepare(tester);
      await http.runWithClient(() async {
        await tester.pumpWidget(_chat(assistant.key, assistant.value));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.attach_file));
        await tester.pumpAndSettle();
        expect(find.text('חסום בסינון הנמען'), findsNothing);
        for (final label in ['צילום']) {
          final tile = tester.widget<ListTile>(find.ancestor(
              of: find.text(label), matching: find.byType(ListTile)));
          expect(tile.onTap, isNotNull);
          expect(tile.subtitle, isNull);
        }
        expect(find.byIcon(Icons.lock_outline), findsNothing);
        await _disposeChat(tester);
      }, () => MockClient((request) async => _staleResponse(request)));
    });
  }

  testWidgets('an assistant display name does not exempt an ordinary friend',
      (tester) async {
    _prepare(tester);
    await http.runWithClient(() async {
      await tester.pumpWidget(_chat('friend', _assistants[kSystemGuideId]!));
      await tester.pumpAndSettle();
      expect(find.byTooltip('כל סוגי התוכן מותרים'), findsNothing);
      await tester.tap(find.byIcon(Icons.shield_outlined));
      await tester.pumpAndSettle();
      expect(find.text('חסום'), findsNWidgets(4));
      expect(find.textContaining('לאחר אישור הקשר'), findsOneWidget);
      expect(find.text('מה מותר לשלוח'), findsNothing);
      expect(find.text('שמור'), findsOneWidget);
      final save = find.ancestor(
          of: find.text('שמור'), matching: find.byType(FilledButton));
      await tester.tap(find.text('חסום').first);
      await tester.pumpAndSettle();
      expect(find.text('מותר'), findsOneWidget);
      expect(find.text('חסום'), findsNWidgets(3));
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.tap(find.text('סגור'));
      await tester.pumpAndSettle();
      await _disposeChat(tester);
    }, () => MockClient((request) async => _staleResponse(request)));
  });

  testWidgets('ordinary friends still require the first-message filter choice',
      (tester) async {
    _prepare(tester);
    final sent = <http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(_chat('friend', 'חבר'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'הודעת ניסיון');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(find.text('בחירת התוכן שאקבל מחבר'), findsOneWidget);
      expect(sent, isEmpty);
      await tester.tap(find.text('ביטול'));
      await tester.pumpAndSettle();
      await _disposeChat(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/messages') &&
                  request.method == 'POST') {
                sent.add(request);
              }
              return _staleResponse(request, receivingTextAllowed: true);
            }));
  });
}
