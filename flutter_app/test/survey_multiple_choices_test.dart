import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:betshuva/simple_survey_editor.dart';
import 'package:betshuva/survey_answers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final _questions = <Map<String, dynamic>>[
  {
    'text': 'אילו פעילויות תרצו?',
    'options': ['טיול', 'סדנה', 'ארוחה'],
    'allowMultiple': true,
  },
  {
    'text': 'מתי ניפגש?',
    'options': ['בוקר', 'ערב'],
  },
];

final _form = <String, dynamic>{
  'id': 'survey-one',
  'group_id': 'group-one',
  'group_name': 'קבוצה',
  'form_type': 'survey',
  'title': 'סקר פעילויות',
  'description': '',
  'status': 'open',
  'anonymous': false,
  'updated_at': '2026-10-11T10:00:00Z',
  'questions': _questions,
};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Finder _field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label);

Finder _multiple(int question) =>
    find.byKey(ValueKey('survey-multiple-$question'));

Finder _choice(String title, {bool multiple = true}) =>
    find.byWidgetPredicate((widget) =>
        (multiple &&
            widget is CheckboxListTile &&
            widget.title is Text &&
            (widget.title as Text).data == title) ||
        (!multiple &&
            widget is RadioListTile<String> &&
            widget.title is Text &&
            (widget.title as Text).data == title));

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

void main() {
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  test(
      'legacy questions stay single choice and copies preserve multiple choice',
      () {
    final legacy = SurveyQuestionDraft(_questions[1]);
    final multiple = SurveyQuestionDraft(_questions[0]);
    final copy = SurveyQuestionDraft(multiple.toJson());
    addTearDown(legacy.dispose);
    addTearDown(multiple.dispose);
    addTearDown(copy.dispose);
    expect(legacy.allowMultiple, isFalse);
    expect(legacy.toJson(), _questions[1]);
    expect(multiple.allowMultiple, isTrue);
    expect(copy.allowMultiple, isTrue);
    copy.allowMultiple = false;
    copy.options.first.text = 'אפשרות חדשה';
    expect(multiple.toJson(), _questions[0]);
    expect(copy.toJson().containsKey('allowMultiple'), isFalse);
  });

  test('result and PDF counts combine legacy answers with multiple selections',
      () {
    final results = <Map<String, dynamic>>[
      {
        'answers': {
          '0': ['טיול', 'סדנה', 'סדנה', 'אפשרות שכבר נמחקה'],
          '1': 'בוקר',
        },
      },
      {
        'answers': {'0': 'סדנה', '1': 'ערב'},
      },
      {
        'answers': {'0': [], '1': null},
      },
      {'answers': null},
    ];
    expect(surveyAnswerCounts(_questions[0], results, 0),
        {'טיול': 1, 'סדנה': 2, 'ארוחה': 0});
    expect(
        surveyAnswerCounts(_questions[1], results, 1), {'בוקר': 1, 'ערב': 1});
    expect(surveyAnswerLabel(['טיול', 'סדנה']), 'טיול · סדנה');
    expect(surveyAnswerLabel('בוקר'), 'בוקר');
    expect(surveyAnswerLabel(null), isEmpty);
    expect(surveySelectedAnswers([null, '', 3, 'טיול']), ['טיול']);
  });

  testWidgets('each question has an independent switch preserved on edit',
      (tester) async {
    http.Request? saved;
    final client = MockClient((request) async {
      saved = request;
      return _json({'id': 'survey-one'});
    });
    await http.runWithClient(() async {
      await _open(
          tester,
          CreateEducationFormScreen(
              token: 'token',
              groupId: 'group-one',
              groupName: 'קבוצה',
              initialType: 'survey',
              lockType: true,
              initialForm: _form));
      await _reveal(tester, _multiple(0));
      expect(tester.widget<SwitchListTile>(_multiple(0)).value, isTrue);
      expect(find.text('לאפשר מספר בחירות?'), findsWidgets);
      await _tap(tester, _multiple(1));
      expect(tester.widget<SwitchListTile>(_multiple(1)).value, isTrue);
      await _reveal(tester, _multiple(0));
      expect(tester.widget<SwitchListTile>(_multiple(0)).value, isTrue);
      await _tap(tester, _multiple(1));
      await _tap(tester, find.text('שמור שינויים'));
      final body = jsonDecode(saved!.body);
      expect(saved!.method, 'PUT');
      expect(body['questions'], _questions);
      expect(body['expectedUpdatedAt'], _form['updated_at']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets('question cloning keeps multiple choices independently',
      (tester) async {
    http.Request? saved;
    final client = MockClient((request) async {
      saved = request;
      return _json({'id': 'survey-one'});
    });
    await http.runWithClient(() async {
      await _open(
          tester,
          CreateEducationFormScreen(
              token: 'token',
              groupId: 'group-one',
              groupName: 'קבוצה',
              initialType: 'survey',
              lockType: true,
              initialForm: _form));
      final first = find.byKey(const ValueKey('survey-question-0'));
      await _tap(tester,
          find.descendant(of: first, matching: find.byTooltip('שכפל שאלה')));
      await _reveal(tester, _multiple(1));
      expect(tester.widget<SwitchListTile>(_multiple(1)).value, isTrue);
      await _tap(tester, _multiple(1));
      await _reveal(tester, _multiple(0));
      expect(tester.widget<SwitchListTile>(_multiple(0)).value, isTrue);
      await _tap(tester, find.text('שמור שינויים'));
      final questions = jsonDecode(saved!.body)['questions'] as List;
      expect(questions, [
        _questions[0],
        {
          'text': _questions[0]['text'],
          'options': _questions[0]['options'],
        },
        _questions[1],
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets('saved and duplicated surveys retain question choice modes',
      (tester) async {
    final saved = <http.Request>[];
    final client = MockClient((request) async {
      saved.add(request);
      return _json({'id': 'draft-${saved.length}'}, 201);
    });
    await http.runWithClient(() async {
      await _open(
          tester,
          CreateEducationFormScreen(
              token: 'token',
              groupId: 'group-one',
              groupName: 'קבוצה',
              initialType: 'survey',
              lockType: true,
              templateForm: _form));
      await _tap(tester, find.text('שמור טיוטה'));
      expect(saved, hasLength(1));
      expect(jsonDecode(saved.first.body)['questions'], _questions);
      await _tap(tester, find.text('שכפל סקר'));
      expect(tester.widget<TextField>(_field('כותרת *')).controller!.text,
          'סקר פעילויות (עותק)');
      await _reveal(tester, _multiple(0));
      expect(tester.widget<SwitchListTile>(_multiple(0)).value, isTrue);
      await _reveal(tester, _multiple(1));
      expect(tester.widget<SwitchListTile>(_multiple(1)).value, isFalse);
      await _tap(tester, find.text('שמור טיוטה'));
      expect(saved, hasLength(2));
      expect(saved.every((request) => request.method == 'POST'), isTrue);
      expect(saved.last.url.path,
          endsWith('/groups/group-one/education-survey-drafts'));
      expect(jsonDecode(saved.last.body)['questions'], _questions);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets(
      'mixed survey submits multiple answers and a legacy single answer',
      (tester) async {
    http.Request? submitted;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        submitted = request;
        return _json({'saved': true});
      }
      return _json({'form': _form, 'participants': [], 'results': []});
    });
    await http.runWithClient(() async {
      await _open(
          tester,
          const EducationFormDetailsScreen(
              token: 'token', formId: 'survey-one', isAdmin: false));
      expect(find.byType(CheckboxListTile), findsNWidgets(3));
      expect(find.byType(RadioListTile<String>), findsNWidgets(2));
      await _tap(tester, _choice('טיול'));
      await _tap(tester, _choice('סדנה'));
      await _tap(tester, _choice('ערב', multiple: false));
      await _reveal(tester, _choice('טיול'));
      expect(tester.widget<CheckboxListTile>(_choice('טיול')).value, isTrue);
      expect(tester.widget<CheckboxListTile>(_choice('סדנה')).value, isTrue);
      expect(tester.widget<CheckboxListTile>(_choice('ארוחה')).value, isFalse);
      await _tap(tester, find.text('שלח תשובות'));
      expect(submitted!.url.path, endsWith('/survey-one/respond'));
      expect(jsonDecode(submitted!.body)['answers'], {
        '0': ['טיול', 'סדנה'],
        '1': 'ערב',
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets('restored selections cannot submit after all choices are cleared',
      (tester) async {
    final submitted = <http.Request>[];
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        submitted.add(request);
        return _json({'saved': true});
      }
      return _json({
        'form': {
          ..._form,
          'my_answers': {
            '0': ['טיול', 'סדנה'],
            '1': 'בוקר',
          },
        },
        'participants': [],
        'results': [],
      });
    });
    await http.runWithClient(() async {
      await _open(
          tester,
          const EducationFormDetailsScreen(
              token: 'token', formId: 'survey-one', isAdmin: false));
      expect(tester.widget<CheckboxListTile>(_choice('טיול')).value, isTrue);
      expect(tester.widget<CheckboxListTile>(_choice('סדנה')).value, isTrue);
      await _tap(tester, _choice('טיול'));
      await _tap(tester, _choice('סדנה'));
      await _tap(tester, find.text('שלח תשובות'));
      expect(submitted, isEmpty);
      expect(find.text('יש לענות על כל שאלות הסקר'), findsOneWidget);
      await _tap(tester, _choice('ארוחה'));
      await _tap(tester, find.text('שלח תשובות'));
      expect(submitted, hasLength(1));
      expect(jsonDecode(submitted.single.body)['answers'], {
        '0': ['ארוחה'],
        '1': 'בוקר',
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets('results count each selected option and retain legacy answers',
      (tester) async {
    final client = MockClient((request) async => _json({
          'form': _form,
          'participants': [],
          'results': [
            {
              'answers': {
                '0': ['טיול', 'סדנה'],
                '1': 'בוקר',
              },
            },
            {
              'answers': {
                '0': ['סדנה', 'ארוחה'],
                '1': 'ערב',
              },
            },
            {
              'answers': {'0': 'סדנה', '1': 'ערב'},
            },
          ],
        }));
    await http.runWithClient(() async {
      await _open(
          tester,
          const EducationFormDetailsScreen(
              token: 'token', formId: 'survey-one', isAdmin: true));
      for (final expected in {
        'טיול': '1',
        'סדנה': '3',
        'ארוחה': '1',
        'בוקר': '1',
        'ערב': '2'
      }.entries) {
        await _reveal(tester, find.text(expected.key));
        final row = find
            .ancestor(of: find.text(expected.key), matching: find.byType(Row))
            .first;
        expect(find.descendant(of: row, matching: find.text(expected.value)),
            findsOneWidget);
      }
      expect(find.text('[טיול, סדנה]'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });
}
