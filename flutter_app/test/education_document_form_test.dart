import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _datedForm = <String, dynamic>{
  'id': 'document-one',
  'form_type': 'approval',
  'title': 'אישור טיול',
  'description': 'הסבר להורים על הטיול',
  'due_at': '2026-11-20T18:00:00Z',
  'updated_at': '2026-10-11T10:00:00Z',
  'file_url': 'https://storage.test/document.pdf',
  'file_name': 'מסמך מקורי.pdf',
  'questions': <dynamic>[],
};

Finder _field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _openEditor(WidgetTester tester,
    {String type = 'approval',
    Map<String, dynamic>? initialForm,
    Map<String, dynamic>? templateForm,
    bool compact = false,
    bool lockType = true}) async {
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
                              initialType: type,
                              lockType: lockType,
                              initialForm: initialForm,
                              templateForm: templateForm))),
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

Future<void> _disposeEditor(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  for (final type in ['approval', 'signature']) {
    testWidgets(
        'new $type copied from a dated form publishes without a deadline',
        (tester) async {
      http.Request? published;
      final client = MockClient((request) async {
        published = request;
        return _json({'id': 'new-document'}, 201);
      });
      await http.runWithClient(() async {
        await _openEditor(tester,
            type: type, templateForm: {..._datedForm, 'form_type': type});
        expect(find.textContaining('מועד סיום'), findsNothing);
        expect(find.byIcon(Icons.event_outlined), findsNothing);
        await _tap(tester, find.text('פרסם בקבוצה'));
        expect(published!.method, 'POST');
        expect(
            published!.url.path, endsWith('/groups/group-one/education-forms'));
        final body = jsonDecode(published!.body);
        expect(body['formType'], type);
        expect(body['title'], _datedForm['title']);
        expect(body['dueAt'], isNull);
        expect(body['fileUrl'], _datedForm['file_url']);
        expect(body['fileName'], _datedForm['file_name']);
        expect(body.containsKey('expectedUpdatedAt'), isFalse);
        await _disposeEditor(tester);
      }, () => client);
    });

    testWidgets(
        'editing published $type preserves its deadline and document URL',
        (tester) async {
      http.Request? saved;
      final client = MockClient((request) async {
        saved = request;
        return _json({'id': 'document-one'});
      });
      await http.runWithClient(() async {
        await _openEditor(tester,
            type: type, initialForm: {..._datedForm, 'form_type': type});
        expect(find.textContaining('מועד סיום'), findsNothing);
        await tester.enterText(_field('כותרת *'), 'אישור מעודכן');
        await _reveal(tester, find.byType(TextFormField));
        await tester.enterText(
            find.byType(TextFormField), 'מסמך חדש להצגה.pdf');
        await _tap(tester, find.text('שמור שינויים'));
        expect(saved!.method, 'PUT');
        expect(saved!.url.path, endsWith('/education-forms/document-one'));
        final body = jsonDecode(saved!.body);
        expect(body['title'], 'אישור מעודכן');
        expect(body['expectedUpdatedAt'], _datedForm['updated_at']);
        expect(DateTime.parse(body['dueAt']),
            DateTime.parse(_datedForm['due_at'] as String));
        expect(body['fileUrl'], _datedForm['file_url']);
        expect(body['fileName'], 'מסמך חדש להצגה.pdf');
        await _disposeEditor(tester);
      }, () => client);
    });

    testWidgets('$type fields stay centered and readable on desktop',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _openEditor(tester, type: type);
      final titleRect = tester.getRect(_field('כותרת *'));
      expect(titleRect.width, inInclusiveRange(600, 760));
      expect(titleRect.center.dx, closeTo(720, 1));
      expect(Directionality.of(tester.element(_field('כותרת *'))),
          TextDirection.rtl);
      expect(find.textContaining('מועד סיום'), findsNothing);
      await _disposeEditor(tester);
    });

    testWidgets('$type works at 360 pixels with enlarged text and a keyboard',
        (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _openEditor(tester,
          type: type,
          compact: true,
          templateForm: {..._datedForm, 'form_type': type});
      await _reveal(tester, _field('כותרת *'));
      await tester.enterText(_field('כותרת *'), 'אישור בטלפון');
      await _reveal(tester, _field('הסבר להורים'));
      await tester.enterText(_field('הסבר להורים'), 'הסבר להורים בעברית');
      await _reveal(tester, find.byType(TextFormField));
      await tester.enterText(find.byType(TextFormField), 'מסמך בטלפון.pdf');
      await _reveal(tester, find.text('פרסם בקבוצה'));
      final actionRect = tester.getRect(find.text('פרסם בקבוצה'));
      expect(actionRect.left, greaterThanOrEqualTo(0));
      expect(actionRect.right, lessThanOrEqualTo(360));
      expect(actionRect.bottom, lessThanOrEqualTo(520));
      expect(find.byType(AlertDialog), findsNothing);
      await _disposeEditor(tester);
    });
  }

  testWidgets('loading an existing dated approval creates an undated copy',
      (tester) async {
    http.Request? published;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        published = request;
        return _json({'id': 'approval-copy'}, 201);
      }
      return _json({
        'forms': [_datedForm]
      });
    });
    await http.runWithClient(() async {
      await _openEditor(tester);
      await _tap(tester, find.text('טען מטופס קיים'));
      await tester.enterText(_field('חיפוש בטפסים קיימים'), 'טיול');
      await tester.pumpAndSettle();
      await _tap(tester, find.text('אישור טיול'));
      expect(tester.widget<TextField>(_field('כותרת *')).controller!.text,
          _datedForm['title']);
      expect(find.textContaining('מועד סיום'), findsNothing);
      await _tap(tester, find.text('פרסם בקבוצה'));
      expect(published!.method, 'POST');
      final body = jsonDecode(published!.body);
      expect(body['dueAt'], isNull);
      expect(body['fileUrl'], _datedForm['file_url']);
      expect(body.containsKey('expectedUpdatedAt'), isFalse);
      await _disposeEditor(tester);
    }, () => client);
  });

  testWidgets('signature validates title and document before making a request',
      (tester) async {
    final sent = <http.Request>[];
    final client = MockClient((request) async {
      sent.add(request);
      return _json({'id': 'signature-one'}, 201);
    });
    await http.runWithClient(() async {
      await _openEditor(tester, type: 'signature');
      await _tap(tester, find.text('פרסם בקבוצה'));
      expect(find.text('יש להזין כותרת'), findsOneWidget);
      expect(sent, isEmpty);
      await _reveal(tester, _field('כותרת *'));
      await tester.enterText(_field('כותרת *'), 'חתימה על הסכם');
      await _tap(tester, find.text('פרסם בקבוצה'));
      expect(find.text('במסמך לחתימה חובה לצרף מסמך'), findsOneWidget);
      expect(sent, isEmpty);
      expect(find.text('יש להזין כותרת'), findsNothing);
      await _disposeEditor(tester);
    }, () => client);
  });

  testWidgets(
      'publishing freezes fields, attachment and toolbar until complete',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final response = Completer<http.Response>();
    final client = MockClient((request) => response.future);
    await http.runWithClient(() async {
      await _openEditor(tester,
          type: 'signature',
          lockType: false,
          templateForm: {..._datedForm, 'form_type': 'signature'});
      await tester.tap(find.text('פרסם בקבוצה'));
      await tester.pump();
      expect(tester.widget<TextField>(_field('כותרת *')).enabled, isFalse);
      expect(tester.widget<TextField>(_field('הסבר להורים')).enabled, isFalse);
      expect(tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
          isFalse);
      expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
      final removeFile = find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'הסר קובץ');
      expect(tester.widget<IconButton>(removeFile).onPressed, isNull);
      for (final label in ['טען מטופס קיים', 'נמענים: כל חברי הקבוצה']) {
        final button = find.ancestor(
            of: find.text(label), matching: find.byType(TextButton));
        expect(tester.widget<TextButton>(button).onPressed, isNull);
      }
      expect(
          tester
              .widget<SegmentedButton<String>>(
                  find.byType(SegmentedButton<String>))
              .onSelectionChanged,
          isNull);
      response.complete(_json({'id': 'signature-one'}, 201));
      await tester.pumpAndSettle();
      expect(find.byType(CreateEducationFormScreen), findsNothing);
      await _disposeEditor(tester);
    }, () => client);
  });
}
