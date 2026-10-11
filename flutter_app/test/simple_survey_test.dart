import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:betshuva/simple_survey_editor.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

Finder _field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label);
Finder _question(int index) =>
    find.byKey(ValueKey('survey-question-text-$index'));
Finder _option(int question, int option) =>
    find.byKey(ValueKey('survey-option-$question-$option'));
http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _openEditor(WidgetTester tester,
    {Map<String, dynamic>? initialForm, bool compact = false}) async {
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansHebrew'),
      builder: (context, child) => Directionality(
          textDirection: TextDirection.rtl,
          child: compact
              ? MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                      viewInsets: const EdgeInsets.only(bottom: 280),
                      textScaler: const TextScaler.linear(1.3)),
                  child: child!)
              : child!),
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => CreateEducationFormScreen(
                              token: 'token',
                              groupId: 'group-one',
                              groupName: 'קבוצה',
                              initialType: 'survey',
                              lockType: true,
                              initialForm: initialForm))),
                  child: const Text('פתח'))))));
  await tester.tap(find.text('פתח'));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, Finder field, String value) async {
  await _reveal(tester, field);
  await tester.enterText(field, value);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
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

String _text(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

final _savedDraft = <String, dynamic>{
  'id': 'draft-one',
  'title': 'טיול שמור',
  'description': 'בוחרים יעד',
  'anonymous': false,
  'updated_at': '2026-10-11T10:00:00Z',
  'questions': [
    {
      'text': 'לאן נוסעים?',
      'options': ['צפון', 'דרום']
    }
  ],
};

void main() {
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  test('copied survey title fits 160 characters without splitting emoji', () {
    final longTitle =
        '${List.filled(151, 'א').join()}🌿${List.filled(40, 'ב').join()}';
    final copy = surveyCopyTitle(longTitle);
    expect(copy.length, 160);
    expect(copy, '${List.filled(151, 'א').join()}🌿 (עותק)');
    final familyTitle =
        '${List.filled(151, 'א').join()}👨‍👩‍👧‍👦${List.filled(40, 'ב').join()}';
    final familyCopy = surveyCopyTitle(familyTitle);
    expect(familyCopy.length, lessThanOrEqualTo(160));
    expect(familyCopy, '${List.filled(151, 'א').join()} (עותק)');
    expect(surveyCopyTitle('  טיול  '), 'טיול (עותק)');
  });

  testWidgets('new survey begins with editable question and two answers inline',
      (tester) async {
    await _openEditor(tester);
    expect(_field('תיאור קצר (לא חובה)'), findsOneWidget);
    expect(_question(0), findsOneWidget);
    expect(_text(tester, _question(0)), isEmpty);
    expect(_text(tester, _option(0, 0)), isEmpty);
    expect(_text(tester, _option(0, 1)), isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('מועד סיום'), findsNothing);
    await _reveal(tester, find.text('שמור טיוטה'));
    expect(find.text('שמור טיוטה'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'question duplication and deletion retain separate editable answers',
      (tester) async {
    http.Request? published;
    final client = MockClient((request) async {
      published = request;
      return _json({'id': 'new-survey'}, 201);
    });
    await http.runWithClient(() async {
      await _openEditor(tester);
      await _enter(tester, _field('כותרת *'), 'סקר פשוט');
      await _enter(tester, _question(0), 'מה נבחר?');
      await _enter(tester, _option(0, 0), 'אפשרות א');
      await _enter(tester, _option(0, 1), 'אפשרות ב');
      await _tap(tester, find.text('הוסף תשובה'));
      await _enter(tester, _option(0, 2), 'אפשרות ג');
      final originalCard = find.byKey(const ValueKey('survey-question-0'));
      await _tap(
          tester,
          find
              .descendant(
                  of: originalCard, matching: find.byTooltip('מחק תשובה'))
              .at(1));
      expect(_text(tester, _option(0, 1)), 'אפשרות ג');
      await _tap(tester, find.byTooltip('שכפל שאלה'));
      await _enter(tester, _question(1), 'מה נבחר אחר כך?');
      await _enter(tester, _option(1, 0), 'אפשרות ד');
      await _reveal(tester, _question(0));
      expect(_text(tester, _question(0)), 'מה נבחר?');
      expect(_text(tester, _option(0, 0)), 'אפשרות א');
      await _tap(
          tester,
          find.descendant(
              of: originalCard, matching: find.byTooltip('מחק שאלה')));
      expect(_text(tester, _question(0)), 'מה נבחר אחר כך?');
      expect(_question(1), findsNothing);
      await _tap(tester, find.text('פרסם בקבוצה'));
      expect(published!.method, 'POST');
      expect(
          published!.url.path, endsWith('/groups/group-one/education-forms'));
      expect(jsonDecode(published!.body)['questions'], [
        {
          'text': 'מה נבחר אחר כך?',
          'options': ['אפשרות ד', 'אפשרות ג']
        }
      ]);
      expect(jsonDecode(published!.body)['dueAt'], isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets('duplicate answer text blocks publishing until corrected',
      (tester) async {
    final sent = <http.Request>[];
    final client = MockClient((request) async {
      sent.add(request);
      return _json({'id': 'new-survey'}, 201);
    });
    await http.runWithClient(() async {
      await _openEditor(tester);
      await _enter(tester, _field('כותרת *'), 'סקר');
      await _enter(tester, _question(0), 'לאן?');
      await _enter(tester, _option(0, 0), 'ירושלים');
      await _enter(tester, _option(0, 1), 'ירושלים');
      await _tap(tester, find.text('פרסם בקבוצה'));
      expect(sent, isEmpty);
      expect(find.text('התשובות בשאלה 1 צריכות להיות שונות'), findsOneWidget);
      await _enter(tester, _option(0, 1), 'חיפה');
      await _tap(tester, find.text('פרסם בקבוצה'));
      expect(sent, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets(
      'saving an unfinished survey keeps draft identity without publishing',
      (tester) async {
    final sent = <http.Request>[];
    final client = MockClient((request) async {
      sent.add(request);
      return _json({..._savedDraft, 'questions': []},
          request.method == 'POST' ? 201 : 200);
    });
    await http.runWithClient(() async {
      await _openEditor(tester);
      await _enter(tester, _field('כותרת *'), 'טיוטה לא גמורה');
      await _enter(tester, _question(0), 'לאן?');
      await _enter(tester, _option(0, 0), 'צפון');
      await _tap(tester, find.text('שמור טיוטה'));
      expect(sent, hasLength(1));
      expect(sent.single.method, 'POST');
      expect(sent.single.url.path,
          endsWith('/groups/group-one/education-survey-drafts'));
      expect(jsonDecode(sent.single.body)['title'], 'טיוטה לא גמורה');
      expect(find.byType(CreateEducationFormScreen), findsOneWidget);
      await _enter(tester, _option(0, 1), 'דרום');
      await _tap(tester, find.text('שמור טיוטה'));
      expect(sent, hasLength(2));
      expect(sent.last.method, 'PUT');
      expect(
          sent.last.url.path, endsWith('/education-survey-drafts/draft-one'));
      expect(
          sent.any((request) => request.url.path.endsWith('/education-forms')),
          isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets(
      'saved draft reloads inline and publishes only after explicit action',
      (tester) async {
    final sent = <http.Request>[];
    final client = MockClient((request) async {
      sent.add(request);
      if (request.method == 'POST') return _json({'id': 'published'}, 201);
      if (request.url.path.endsWith('/education-survey-drafts')) {
        return _json({
          'drafts': [_savedDraft]
        });
      }
      return _json({'forms': []});
    });
    await http.runWithClient(() async {
      await _openEditor(tester);
      await _tap(tester, find.text('סקרים שמורים'));
      await _enter(tester, _field('חיפוש בסקרים שמורים'), 'טיול');
      await _tap(tester, find.text('טיול שמור'));
      expect(_text(tester, _field('כותרת *')), 'טיול שמור');
      expect(_text(tester, _question(0)), 'לאן נוסעים?');
      expect(_text(tester, _option(0, 0)), 'צפון');
      expect(sent.where((request) => request.method != 'GET'), isEmpty);
      await _enter(tester, _question(0), 'לאן ניסע ביחד?');
      await _tap(tester, find.text('פרסם בקבוצה'));
      final posted = sent.where((request) => request.method == 'POST').single;
      expect(posted.url.path, endsWith('/groups/group-one/education-forms'));
      final body = jsonDecode(posted.body);
      expect(body['questions'], [
        {
          'text': 'לאן ניסע ביחד?',
          'options': ['צפון', 'דרום']
        }
      ]);
      expect(body.containsKey('expectedUpdatedAt'), isFalse);
      expect(body['dueAt'], isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets('survey fits a narrow viewport while the keyboard is open',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _openEditor(tester, compact: true);
    await _enter(tester, _field('כותרת *'), 'סקר בטלפון');
    await _enter(tester, _question(0), 'מה רוצים?');
    await _enter(tester, _option(0, 0), 'טיול');
    await _enter(tester, _option(0, 1), 'מפגש');
    await _tap(tester, find.text('הוסף שאלה'));
    await _enter(tester, _question(1), 'מתי נפגשים?');
    expect(_question(1), findsOneWidget);
    await _reveal(tester, find.text('שמור טיוטה'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('duplicating a saved draft creates a new draft on explicit save',
      (tester) async {
    final sent = <http.Request>[];
    final client = MockClient((request) async {
      sent.add(request);
      if (request.method == 'POST') return _json({'id': 'draft-copy'}, 201);
      if (request.url.path.endsWith('/education-survey-drafts')) {
        return _json({
          'drafts': [_savedDraft]
        });
      }
      return _json({'forms': []});
    });
    await http.runWithClient(() async {
      await _openEditor(tester);
      await _tap(tester, find.text('סקרים שמורים'));
      await _tap(tester, find.byType(PopupMenuButton<String>));
      await _tap(tester, find.text('שכפל טיוטה'));
      expect(_text(tester, _field('כותרת *')), 'טיול שמור (עותק)');
      expect(sent.where((request) => request.method != 'GET'), isEmpty);
      await _tap(tester, find.text('שמור טיוטה'));
      final saved = sent.where((request) => request.method == 'POST').single;
      expect(saved.url.path,
          endsWith('/groups/group-one/education-survey-drafts'));
      expect(jsonDecode(saved.body)['questions'], _savedDraft['questions']);
      expect(sent.any((request) => request.method == 'PUT'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets('saved surveys search fits a narrow viewport with keyboard',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/education-survey-drafts')) {
        return _json({
          'drafts': [_savedDraft]
        });
      }
      return _json({'forms': []});
    });
    await http.runWithClient(() async {
      await _openEditor(tester, compact: true);
      await _tap(tester, find.text('סקרים שמורים'));
      await _enter(tester, _field('חיפוש בסקרים שמורים'), 'טיול');
      expect(find.text('טיול שמור'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('טיול שמור'));
      expect(_text(tester, _field('כותרת *')), 'טיול שמור');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets(
      'draft deletion requires confirmation and removes the library row',
      (tester) async {
    final deleted = <http.Request>[];
    final client = MockClient((request) async {
      if (request.method == 'DELETE') {
        deleted.add(request);
        return _json({'deleted': true});
      }
      if (request.url.path.endsWith('/education-survey-drafts')) {
        return _json({
          'drafts': [_savedDraft]
        });
      }
      return _json({'forms': []});
    });
    await http.runWithClient(() async {
      await _openEditor(tester);
      await _tap(tester, find.text('סקרים שמורים'));
      await _tap(tester, find.byType(PopupMenuButton<String>));
      await _tap(tester, find.text('מחק טיוטה'));
      await _tap(tester, find.text('ביטול'));
      expect(deleted, isEmpty);
      expect(find.text('טיול שמור'), findsOneWidget);
      await _tap(tester, find.byType(PopupMenuButton<String>));
      await _tap(tester, find.text('מחק טיוטה'));
      await _tap(tester, find.text('מחק'));
      expect(deleted.single.url.path,
          endsWith('/education-survey-drafts/draft-one'));
      expect(find.text('טיול שמור'), findsNothing);
      expect(find.text('אין סקרים שמורים שמתאימים לחיפוש'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets('duplicating a published survey stays editable until published',
      (tester) async {
    final sent = <http.Request>[];
    final client = MockClient((request) async {
      sent.add(request);
      if (request.method == 'POST') return _json({'id': 'survey-copy'}, 201);
      return _json({
        'form': {
          ..._savedDraft,
          'id': 'survey-one',
          'form_type': 'survey',
          'status': 'open',
          'group_id': 'group-one',
          'group_name': 'קבוצה',
          'due_at': '2026-11-20T18:00:00Z',
        },
        'participants': [],
        'results': [],
      });
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) =>
              Directionality(textDirection: TextDirection.rtl, child: child!),
          home: const EducationFormDetailsScreen(
              token: 'token', formId: 'survey-one', isAdmin: true)));
      await tester.pumpAndSettle();
      await _tap(tester, find.byType(PopupMenuButton<String>));
      await _tap(tester, find.text('שכפל סקר'));
      expect(_text(tester, _field('כותרת *')), 'טיול שמור (עותק)');
      expect(find.textContaining('מועד סיום'), findsNothing);
      expect(sent.where((request) => request.method != 'GET'), isEmpty);
      await _enter(tester, _field('כותרת *'), 'טיול חדש');
      await _tap(tester, find.text('פרסם בקבוצה'));
      final published =
          sent.where((request) => request.method == 'POST').single;
      expect(published.url.path, endsWith('/groups/group-one/education-forms'));
      final body = jsonDecode(published.body);
      expect(body['title'], 'טיול חדש');
      expect(body['questions'], _savedDraft['questions']);
      expect(body['dueAt'], isNull);
      expect(body.containsKey('expectedUpdatedAt'), isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });

  testWidgets(
      'deleting a survey hides stale in-flight responses and stops refresh',
      (tester) async {
    final stale = Completer<http.Response>();
    var reads = 0;
    final payload = {
      'form': {
        ..._savedDraft,
        'id': 'survey-one',
        'form_type': 'survey',
        'status': 'open',
        'group_id': 'group-one',
        'group_name': 'קבוצה',
      },
      'participants': [],
      'results': [],
    };
    final client = MockClient((request) async {
      reads++;
      if (reads == 1) return _json(payload);
      return stale.future;
    });
    final socket = io.io('http://localhost:1',
        io.OptionBuilder().disableAutoConnect().enableForceNew().build());
    addTearDown(() {
      socket.connected = false;
      socket.dispose();
    });
    void receive(String action) {
      socket.connected = true;
      socket.onevent({
        'data': [
          'education:updated',
          {'formId': 'survey-one', 'action': action}
        ]
      });
      socket.connected = false;
    }

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) =>
              Directionality(textDirection: TextDirection.rtl, child: child!),
          home: EducationFormDetailsScreen(
              token: 'token',
              formId: 'survey-one',
              isAdmin: true,
              socket: socket)));
      await tester.pumpAndSettle();
      expect(find.text('טיול שמור'), findsWidgets);
      receive('edited');
      await tester.pump();
      expect(reads, 2);
      receive('deleted');
      await tester.pumpAndSettle();
      expect(find.text('הסקר נמחק'), findsOneWidget);
      expect(find.text('טיול שמור'), findsNothing);
      stale.complete(_json(payload));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('הסקר נמחק'), findsOneWidget);
      expect(find.text('טיול שמור'), findsNothing);
      expect(reads, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, () => client);
  });
}
