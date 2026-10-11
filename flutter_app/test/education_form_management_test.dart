import 'dart:convert';
import 'package:betshuva/education_form_tools.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _form = <String, dynamic>{
  'id': 'form-one',
  'group_id': 'group-one',
  'group_name': 'קבוצה',
  'form_type': 'survey',
  'title': 'סקר טיול',
  'description': 'תיאור הטיול',
  'status': 'open',
  'anonymous': true,
  'due_at': '2026-11-20T18:00:00Z',
  'updated_at': '2026-10-11T10:00:00Z',
  'questions': [
    {
      'text': 'מתי יוצאים?',
      'options': ['בוקר', 'ערב']
    }
  ],
};
Finder _field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label);
Future<void> _openEditor(WidgetTester tester, Widget editor) async {
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansHebrew'),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: Builder(
          builder: (ctx) => Scaffold(
              body: TextButton(
                  onPressed: () => Navigator.push(
                      ctx, MaterialPageRoute(builder: (_) => editor)),
                  child: const Text('פתח'))))));
  await tester.tap(find.text('פתח'));
  await tester.pumpAndSettle();
}

http.Response _json(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
void main() {
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });
  test('CSV import handles Hebrew, quoted names and only matches known members',
      () {
    final members = [
      {'id': '1', 'name': 'משה, כהן'},
      {'id': '2', 'name': 'שרה'},
    ];
    expect(
        matchEducationRecipients(
            '\uFEFFname,id\n"משה, כהן",1\nלא חבר,9', members),
        {'1'});
    expect(recipientListValues('"משה, כהן";שרה\r\n'), ['משה, כהן', 'שרה']);
    expect(educationFormMatches(_form, 'יוצאים'), isTrue);
  });
  testWidgets(
      'published survey edits questions and saves the same form with revision protection',
      (tester) async {
    http.Request? saved;
    final client = MockClient((req) async {
      saved = req;
      return _json({'id': 'form-one'});
    });
    await http.runWithClient(() async {
      await _openEditor(
          tester,
          CreateEducationFormScreen(
              token: 'token',
              groupId: 'group-one',
              groupName: 'קבוצה',
              initialType: 'survey',
              lockType: true,
              initialForm: _form));
      expect(tester.widget<TextField>(_field('כותרת *')).controller!.text,
          'סקר טיול');
      expect(find.textContaining('מועד סיום'), findsNothing);
      await tester.enterText(_field('כותרת *'), 'סקר מעודכן');
      final question = find.byKey(const ValueKey('survey-question-text-0'));
      await tester.ensureVisible(question);
      await tester.enterText(question, 'באיזו שעה יוצאים?');
      await tester.ensureVisible(find.text('הוסף שאלה'));
      await tester.tap(find.text('הוסף שאלה'));
      await tester.pumpAndSettle();
      await tester
          .ensureVisible(find.byKey(const ValueKey('survey-question-text-1')));
      await tester.enterText(
          find.byKey(const ValueKey('survey-question-text-1')), 'לאן יוצאים?');
      await tester
          .ensureVisible(find.byKey(const ValueKey('survey-option-1-0')));
      await tester.enterText(
          find.byKey(const ValueKey('survey-option-1-0')), 'צפון');
      await tester
          .ensureVisible(find.byKey(const ValueKey('survey-option-1-1')));
      await tester.enterText(
          find.byKey(const ValueKey('survey-option-1-1')), 'דרום');
      await tester.scrollUntilVisible(find.text('שמור שינויים'), 150,
          scrollable: find
              .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable))
              .first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('שמור שינויים'));
      await tester.pumpAndSettle();
      expect(saved!.method, 'PUT');
      expect(saved!.url.path, endsWith('/education-forms/form-one'));
      final body = jsonDecode(saved!.body);
      expect(body['expectedUpdatedAt'], _form['updated_at']);
      expect(body['title'], 'סקר מעודכן');
      expect(body['questions'], [
        {
          'text': 'באיזו שעה יוצאים?',
          'options': ['בוקר', 'ערב']
        },
        {
          'text': 'לאן יוצאים?',
          'options': ['צפון', 'דרום']
        },
      ]);
      expect(body['anonymous'], isTrue);
      expect(body['dueAt'], isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });
  testWidgets('document rename saves the original uploaded URL',
      (tester) async {
    http.Request? saved;
    final client = MockClient((req) async {
      saved = req;
      return _json({});
    });
    await http.runWithClient(() async {
      await _openEditor(
          tester,
          CreateEducationFormScreen(
              token: 'token',
              groupId: 'group-one',
              groupName: 'קבוצה',
              lockType: true,
              initialForm: {
                ..._form,
                'form_type': 'signature',
                'questions': [],
                'file_url': 'https://storage.test/doc.pdf',
                'file_name': 'ישן.pdf'
              }));
      await tester.ensureVisible(find.text('שם הקובץ להצגה'));
      await tester.enterText(find.byType(TextFormField), 'מסמך מעודכן.pdf');
      await tester.scrollUntilVisible(find.text('שמור שינויים'), 150,
          scrollable: find
              .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.text('שמור שינויים'));
      await tester.pumpAndSettle();
      final body = jsonDecode(saved!.body);
      expect(body['fileName'], 'מסמך מעודכן.pdf');
      expect(body['fileUrl'], 'https://storage.test/doc.pdf');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });
  testWidgets(
      'template search loads a copy and publishes to selected recipients',
      (tester) async {
    http.Request? saved;
    final client = MockClient((req) async {
      if (req.method == 'POST') {
        saved = req;
        return _json({}, 201);
      }
      if (req.url.path.endsWith('/education-forms'))
        return _json({
          'forms': [_form]
        });
      if (req.url.path.endsWith('/education-survey-drafts')) {
        return _json({'drafts': []});
      }
      return _json({
        'viewer_id': 'admin',
        'members': [
          {'id': 'admin', 'name': 'מנהל'},
          {'id': 'member-one', 'name': 'משה'},
          {'id': 'member-two', 'name': 'שרה'},
        ]
      });
    });
    await http.runWithClient(() async {
      await _openEditor(
          tester,
          const CreateEducationFormScreen(
              token: 'token',
              groupId: 'group-one',
              groupName: 'קבוצה',
              initialType: 'survey',
              lockType: true));
      await tester.tap(find.text('סקרים שמורים'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('חיפוש בסקרים שמורים'), 'טיול');
      await tester.pumpAndSettle();
      await tester.tap(find.text('סקר טיול'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<TextField>(
                  find.byKey(const ValueKey('survey-question-text-0')))
              .controller!
              .text,
          'מתי יוצאים?');
      await tester.tap(find.textContaining('נמענים: כל חברי הקבוצה'));
      await tester.pumpAndSettle();
      expect(find.text('מנהל'), findsNothing);
      await tester.tap(find.text('נקה'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('חיפוש חברי קבוצה'), 'שרה');
      await tester.pumpAndSettle();
      expect(find.text('משה'), findsNothing);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('בחר (1)'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('פרסם בקבוצה'), 150,
          scrollable: find
              .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.text('פרסם בקבוצה'));
      await tester.pumpAndSettle();
      expect(saved!.method, 'POST');
      final body = jsonDecode(saved!.body);
      expect(body['recipientIds'], ['member-two']);
      expect(body['title'], 'סקר טיול');
      expect(body.containsKey('expectedUpdatedAt'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });
  testWidgets('forms center searches existing survey titles and questions',
      (tester) async {
    final client = MockClient((req) async => _json({
          'forms': [
            _form,
            {
              ..._form,
              'id': 'form-two',
              'title': 'אישור לימודים',
              'questions': []
            }
          ]
        }));
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: EducationFormsScreen(
              token: 'token',
              groupId: 'group-one',
              groupName: 'קבוצה',
              isAdmin: true)));
      await tester.pumpAndSettle();
      await tester.enterText(_field('חיפוש סקרים, אישורים ומסמכים'), 'יוצאים');
      await tester.pumpAndSettle();
      expect(find.text('סקר טיול'), findsOneWidget);
      expect(find.text('אישור לימודים'), findsNothing);
      await tester.enterText(_field('חיפוש סקרים, אישורים ומסמכים'), 'לא קיים');
      await tester.pumpAndSettle();
      expect(find.text('לא נמצאו טפסים'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });
  testWidgets(
      'published form sends only to selected newly added members and opens archived responses',
      (tester) async {
    http.Request? sent;
    final client = MockClient((req) async {
      if (req.method == 'POST') {
        sent = req;
        return _json({'sent': 1});
      }
      if (req.url.path.contains('/revisions/'))
        return _json({
          'form': {..._form, 'title': 'גרסה מקורית'},
          'responses': [
            {
              'response_status': 'completed',
              'answers': {'0': 'בוקר'}
            }
          ],
        });
      if (req.url.path.endsWith('/groups/group-one'))
        return _json({
          'viewer_id': 'admin',
          'members': [
            {'id': 'admin', 'name': 'מנהל'},
            {'id': 'old', 'name': 'חבר קיים'},
            {'id': 'new', 'name': 'חבר חדש'},
          ],
        });
      return _json({
        'form': {
          ..._form,
          'new_member_count': 1,
          'revisions': [
            {
              'id': 'old-revision',
              'title': 'גרסה מקורית',
              'created_at': '2026-10-11',
              'response_count': 1
            },
          ]
        },
        'participants': [
          {'id': 'old', 'name': 'חבר קיים'}
        ],
        'results': []
      });
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
          home: EducationFormDetailsScreen(
              token: 'token', formId: 'form-one', isAdmin: true)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('שלח לנמענים מתוך רשימה'), 150,
          scrollable: find
              .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.text('שלח לנמענים מתוך רשימה'));
      await tester.pumpAndSettle();
      final choices = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(CheckboxListTile));
      expect(choices, findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.text('חבר קיים')),
          findsNothing);
      await tester.tap(choices);
      await tester.pumpAndSettle();
      await tester.tap(find.text('בחר (1)'));
      await tester.pumpAndSettle();
      expect(sent!.url.path, endsWith('/form-one/assign-new-members'));
      expect(jsonDecode(sent!.body)['recipientIds'], ['new']);
      expect(
          tester
              .widget<OutlinedButton>(find
                  .ancestor(
                      of: find.text('שלח לנמענים מתוך רשימה'),
                      matching: find.byType(OutlinedButton))
                  .first)
              .onPressed,
          isNotNull);
      await tester.scrollUntilVisible(find.text('היסטוריית עדכונים'), 150,
          scrollable: find
              .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.text('היסטוריית עדכונים'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('גרסה מקורית'));
      await tester.tap(find.text('גרסה מקורית'));
      await tester.pumpAndSettle();
      expect(find.text('תשובה אנונימית'), findsOneWidget);
      expect(find.text('הושלם • בוקר'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets(
      'recipient picker fits a narrow viewport with keyboard and enlarged text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = MockClient((req) async => _json({
          'members': [
            {'id': 'one', 'name': 'חבר חדש'}
          ],
          'viewer_id': 'admin'
        }));
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(
                  viewInsets: const EdgeInsets.only(bottom: 300),
                  textScaler: const TextScaler.linear(1.5)),
              child: child!),
          home: Builder(
              builder: (ctx) => Scaffold(
                  body: TextButton(
                      onPressed: () => showEducationRecipientsDialog(ctx,
                          api: kApi, token: 'token', groupId: 'group-one'),
                      child: const Text('נמענים'))))));
      await tester.tap(find.text('נמענים'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('חיפוש חברי קבוצה'), 'חדש');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(CheckboxListTile), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });
}
