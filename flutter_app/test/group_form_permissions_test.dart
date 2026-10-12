import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

final _form = <String, dynamic>{
  'id': 'own-form',
  'group_id': 'group-one',
  'group_name': 'קבוצה',
  'form_type': 'survey',
  'title': 'הסקר שלי',
  'description': '',
  'status': 'open',
  'anonymous': false,
  'updated_at': '2026-10-12T10:00:00Z',
  'created_by': 'member-one',
  'my_role': 'member',
  'isAdmin': false,
  'isCreator': true,
  'canManage': true,
  'canSend': true,
  'questions': [
    {
      'text': 'מתי מגיעים?',
      'options': ['בוקר', 'ערב'],
    },
  ],
};

Future<void> _open(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansHebrew'),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => screen)),
                  child: const Text('פתח'))))));
  await tester.tap(find.text('פתח'));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scrollable = find
        .descendant(
            of: find.byType(ListView).last, matching: find.byType(Scrollable))
        .first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(finder, 150, scrollable: scrollable);
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Future<void> _withGroup(WidgetTester tester,
    {required Map<String, dynamic> group,
    required Future<void> Function(
            Map<String, dynamic> serverGroup, List<http.Request> requests)
        action,
    bool textAllowed = true}) async {
  SharedPreferences.setMockInitialValues({});
  final serverGroup = Map<String, dynamic>.from(group);
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/groups')) return _json([serverGroup]);
    if (path.endsWith('/filter-settings')) {
      return _json({
        'filter': {
          'text': textAllowed,
          'video': true,
          'nonHumanImages': true,
          'men': true,
          'women': true,
          'children': true,
        },
        'personalFilter': {'text': true},
        'requiresChoice': false,
      });
    }
    if (path.endsWith('/messages') ||
        path.contains('/messages/') ||
        path.endsWith('/members') ||
        path.endsWith('/upload-batch-notices')) {
      return _json([]);
    }
    if (path.endsWith('/group-one')) {
      return _json({...serverGroup, 'members': []});
    }
    return _json({});
  });
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: GroupChatScreen(
            token: 'token',
            me: const {'id': 'member-one', 'name': 'חבר'},
            group: Map<String, dynamic>.from(group),
            socket: null)));
    await tester.pumpAndSettle();
    await action(serverGroup, requests);
    await _close(tester);
  }, () => client);
}

void main() {
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  for (final allowed in [true, false]) {
    testWidgets('forms center follows server create permission ($allowed)',
        (tester) async {
      final client = MockClient((request) async => _json({
            'forms': [],
            'isAdmin': false,
            'canCreate': allowed,
          }));
      await http.runWithClient(() async {
        await _open(
            tester,
            EducationFormsScreen(
                token: 'token',
                groupId: 'group-one',
                groupName: 'קבוצה',
                isAdmin: false,
                // A stale caller hint must not override the server decision.
                canCreate: !allowed));
        expect(
            find.text('יצירה חדשה'), allowed ? findsOneWidget : findsNothing);
        if (allowed) {
          await _tap(tester, find.text('יצירה חדשה'));
          final creator = tester.widget<CreateEducationFormScreen>(
              find.byType(CreateEducationFormScreen));
          expect(creator.groupId, 'group-one');
          expect(creator.lockType, isFalse);
          expect(find.byType(SegmentedButton<String>), findsOneWidget);
        }
        await _close(tester);
      }, () => client);
    });
  }

  testWidgets('a creator sees results and edits their own survey as a member',
      (tester) async {
    http.Request? edited;
    var form = Map<String, dynamic>.from(_form);
    final client = MockClient((request) async {
      if (request.method == 'PUT') {
        edited = request;
        form = {...form, 'title': jsonDecode(request.body)['title']};
        return _json({'id': form['id']});
      }
      return _json({
        'form': form,
        'participants': [
          {'id': 'recipient-one', 'name': 'משתתף', 'response_status': null},
        ],
        'results': [],
      });
    });
    await http.runWithClient(() async {
      await _open(
          tester,
          const EducationFormDetailsScreen(
              token: 'token', formId: 'own-form', isAdmin: false));
      expect(
          tester
              .widget<EducationFormDetailsScreen>(
                  find.byType(EducationFormDetailsScreen))
              .isAdmin,
          isFalse);
      expect(find.text('שלח תשובות'), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      await _tap(tester, find.byType(PopupMenuButton<String>));
      expect(find.text('ערוך סקר'), findsOneWidget);
      expect(find.text('מחק סקר'), findsOneWidget);
      await _tap(tester, find.text('ערוך סקר'));
      final creator = tester.widget<CreateEducationFormScreen>(
          find.byType(CreateEducationFormScreen));
      expect(creator.initialForm!['id'], 'own-form');
      expect(creator.initialForm!['my_role'], 'member');
      final title = find.byWidgetPredicate((widget) =>
          widget is TextField && widget.decoration?.labelText == 'כותרת *');
      await tester.enterText(title, 'הסקר שלי מעודכן');
      await _tap(tester, find.text('שמור שינויים'));
      expect(edited!.url.path, endsWith('/education-forms/own-form'));
      expect(
          jsonDecode(edited!.body)['expectedUpdatedAt'], _form['updated_at']);
      await _close(tester);
    }, () => client);
  });

  testWidgets(
      'server denies management of another creator form despite stale admin hint',
      (tester) async {
    final client = MockClient((request) async => _json({
          'form': {
            ..._form,
            'id': 'other-form',
            'created_by': 'other-user',
            'isCreator': false,
            'canManage': false,
            'my_role': 'member',
          },
          'participants': null,
          'results': null,
        }));
    await http.runWithClient(() async {
      await _open(
          tester,
          const EducationFormDetailsScreen(
              token: 'token', formId: 'other-form', isAdmin: true));
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.text('שלח תשובות'), findsOneWidget);
      expect(find.text('מצב משתתפים'), findsNothing);
      expect(find.text('פרסם שוב בשיחת הקבוצה'), findsNothing);
      await _close(tester);
    }, () => client);
  });

  testWidgets('restricted creator can edit but cannot duplicate or send a form',
      (tester) async {
    final client = MockClient((request) async => _json({
          'form': {..._form, 'canSend': false},
          'participants': [
            {'id': 'recipient-one', 'name': 'משתתף', 'response_status': null},
          ],
          'results': [],
        }));
    await http.runWithClient(() async {
      await _open(
          tester,
          const EducationFormDetailsScreen(
              token: 'token', formId: 'own-form', isAdmin: false));
      await _tap(tester, find.byType(PopupMenuButton<String>));
      final duplicate = find.ancestor(
          of: find.text('שכפל סקר'),
          matching: find.byType(PopupMenuItem<String>));
      expect(tester.widget<PopupMenuItem<String>>(duplicate).enabled, isFalse);
      final edit = find.ancestor(
          of: find.text('ערוך סקר'),
          matching: find.byType(PopupMenuItem<String>));
      expect(tester.widget<PopupMenuItem<String>>(edit).enabled, isTrue);
      await tester.tap(find.text('שכפל סקר'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateEducationFormScreen), findsNothing);
      Navigator.of(tester.element(find.byType(PopupMenuButton<String>))).pop();
      await tester.pumpAndSettle();
      for (final label in [
        'פרסם שוב בשיחת הקבוצה',
        'שלח לנמענים מתוך רשימה',
      ]) {
        await _reveal(tester, find.text(label));
        final button = find.ancestor(
            of: find.text(label), matching: find.byType(OutlinedButton));
        expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      }
      await _close(tester);
    }, () => client);
  });

  for (final type in ['survey', 'approval', 'signature']) {
    testWidgets('sender recipient can answer $type alongside form management',
        (tester) async {
      http.Request? submitted;
      var form = <String, dynamic>{
        ..._form,
        'form_type': type,
        'isRecipient': true,
        'canRespond': true,
        'current_user_name': 'השם שלי',
        if (type != 'survey') 'questions': [],
      };
      final client = MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/respond')) {
          submitted = request;
          form = {
            ...form,
            'my_response_status': jsonDecode(request.body)['status'],
          };
          return _json({'saved': true});
        }
        return _json({
          'form': form,
          'participants': [
            {'id': 'member-one', 'name': 'השם שלי', 'response_status': null},
            {'id': 'recipient-one', 'name': 'משתתף', 'response_status': null},
          ],
          'results': [],
        });
      });
      await http.runWithClient(() async {
        await _open(
            tester,
            const EducationFormDetailsScreen(
                token: 'token', formId: 'own-form', isAdmin: false));
        expect(find.text('המענה שלי'), findsOneWidget);
        expect(find.byType(PopupMenuButton<String>), findsOneWidget);
        if (type == 'survey') {
          final ownQuestion =
              find.byKey(const ValueKey('survey-response-question-0'));
          await _tap(tester,
              find.descendant(of: ownQuestion, matching: find.text('בוקר')));
          await _tap(tester, find.text('שלח תשובות'));
          expect(jsonDecode(submitted!.body)['answers'], {'0': 'בוקר'});
        } else if (type == 'approval') {
          await _tap(tester, find.text('מאשר/ת'));
          expect(jsonDecode(submitted!.body)['status'], 'approved');
        } else {
          final name = find.byWidgetPredicate((widget) =>
              widget is TextField &&
              widget.decoration?.labelText == 'שם מלא של החותם');
          await _reveal(tester, name);
          expect(tester.widget<TextField>(name).controller!.text, 'השם שלי');
          final canvas =
              find.byKey(const ValueKey('education-signature-canvas'));
          await _reveal(tester, canvas);
          final gesture = await tester.startGesture(tester.getCenter(canvas));
          await gesture.moveBy(const Offset(22, 0));
          await gesture.moveBy(const Offset(15, 12));
          await gesture.moveBy(const Offset(15, -8));
          await gesture.up();
          await tester.pumpAndSettle();
          await _tap(tester, find.text('אני מאשר/ת וחותם/ת'));
          expect(jsonDecode(submitted!.body)['signerName'], 'השם שלי');
          expect(jsonDecode(submitted!.body)['signatureData'],
              contains(isA<Map>()));
        }
        expect(submitted!.url.path, endsWith('/own-form/respond'));
        expect(jsonDecode(submitted!.body)['expectedUpdatedAt'],
            _form['updated_at']);
        expect(find.byType(EducationFormDetailsScreen), findsNothing);
        await _open(
            tester,
            const EducationFormDetailsScreen(
                token: 'token', formId: 'own-form', isAdmin: false));
        await _reveal(tester, find.text('מצב משתתפים'));
        expect(find.text('מצב משתתפים'), findsOneWidget);
        await _reveal(tester, find.textContaining('תשובתך:'));
        expect(find.textContaining('תשובתך:'), findsOneWidget);
        expect(find.byType(PopupMenuButton<String>), findsOneWidget);
        await _close(tester);
      }, () => client);
    });
  }

  for (final canManage in [true, false]) {
    testWidgets('explicitly excluded sender has no response ($canManage)',
        (tester) async {
      final client = MockClient((request) async => _json({
            'form': {
              ..._form,
              'isRecipient': false,
              'canRespond': false,
              'canManage': canManage,
            },
            'participants': canManage ? [] : null,
            'results': canManage ? [] : null,
          }));
      await http.runWithClient(() async {
        await _open(
            tester,
            const EducationFormDetailsScreen(
                token: 'token', formId: 'own-form', isAdmin: false));
        expect(find.text('שלח תשובות'), findsNothing);
        expect(find.text('המענה שלי'), findsNothing);
        expect(find.byType(RadioListTile<String>), findsNothing);
        expect(find.byType(PopupMenuButton<String>),
            canManage ? findsOneWidget : findsNothing);
        await _close(tester);
      }, () => client);
    });
  }

  testWidgets('anonymous sender answer remains separate from aggregate results',
      (tester) async {
    final client = MockClient((request) async => _json({
          'form': {
            ..._form,
            'anonymous': true,
            'isRecipient': true,
            'my_answers': {'0': 'בוקר'},
          },
          'participants': [
            {'id': 'member-one', 'name': 'אני', 'response_status': null},
          ],
          'results': [
            {
              'answers': {'0': 'ערב'}
            },
            {
              'answers': {'0': 'ערב'}
            },
          ],
        }));
    await http.runWithClient(() async {
      await _open(
          tester,
          const EducationFormDetailsScreen(
              token: 'token', formId: 'own-form', isAdmin: false));
      final personalQuestion =
          find.byKey(const ValueKey('survey-response-question-0'));
      final personalChoices = find.descendant(
          of: personalQuestion, matching: find.byType(RadioGroup<String>));
      expect(tester.widget<RadioGroup<String>>(personalChoices).groupValue,
          'בוקר');
      expect(find.text('סקר אנונימי'), findsOneWidget);
      final aggregate = find.byKey(const ValueKey('survey-result-question-0'));
      await _reveal(tester, aggregate);
      expect(find.descendant(of: aggregate, matching: find.text('0')),
          findsOneWidget);
      expect(find.descendant(of: aggregate, matching: find.text('2')),
          findsOneWidget);
      expect(find.descendant(of: aggregate, matching: find.text('אני')),
          findsNothing);
      await _reveal(tester, personalQuestion);
      expect(tester.widget<RadioGroup<String>>(personalChoices).groupValue,
          'בוקר');
      await _tap(tester,
          find.descendant(of: personalQuestion, matching: find.text('ערב')));
      expect(
          tester.widget<RadioGroup<String>>(personalChoices).groupValue, 'ערב');
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
          tester.widget<RadioGroup<String>>(personalChoices).groupValue, 'ערב');
      await _close(tester);
    }, () => client);
  });

  for (final permission in [
    ('member', 'member', 'admin', true),
    ('admin', 'pending', 'all', true),
    ('member', 'member', 'all', false),
  ]) {
    testWidgets(
        'form creation obeys role, membership, and text filter $permission',
        (tester) async {
      await _withGroup(tester,
          group: {
            'id': 'group-one',
            'name': 'קבוצה',
            'role': permission.$1,
            'status': permission.$2,
            'send_permission': permission.$3,
            'member_count': 1,
          },
          textAllowed: permission.$4, action: (serverGroup, requests) async {
        final attach = find.byIcon(Icons.attach_file);
        if (attach.evaluate().isNotEmpty) {
          await tester.tap(attach);
          await tester.pumpAndSettle();
        }
        final entry = find.text('אישור, חתימה או סקר');
        if (entry.evaluate().isNotEmpty) {
          final tile =
              find.ancestor(of: entry, matching: find.byType(ListTile));
          expect(tester.widget<ListTile>(tile).onTap, isNull);
        }
        expect(find.byType(CreateEducationFormScreen), findsNothing);
        expect(
            requests.where((request) =>
                request.method == 'POST' &&
                request.url.path.contains('/education-')),
            isEmpty);
      });
    });
  }

  testWidgets('losing admin role while form menu is open blocks stale creation',
      (tester) async {
    await _withGroup(tester, group: {
      'id': 'group-one',
      'name': 'קבוצה',
      'role': 'admin',
      'status': 'member',
      'send_permission': 'admin',
      'member_count': 1,
    }, action: (serverGroup, requests) async {
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pumpAndSettle();
      await tester.tap(find.text('אישור, חתימה או סקר'));
      await tester.pumpAndSettle();
      expect(find.text('סקר'), findsOneWidget);
      serverGroup['role'] = 'member';
      await tester.tap(find.text('סקר'));
      await tester.pumpAndSettle();
      expect(find.byType(CreateEducationFormScreen), findsNothing);
      expect(
          requests.where((request) =>
              request.method == 'POST' &&
              request.url.path.contains('/education-')),
          isEmpty);
    });
  });
}
