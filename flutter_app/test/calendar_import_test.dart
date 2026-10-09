import 'dart:convert';
import 'package:betshuva/calendar_import.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const draft = {
  'title': 'אירוע מהטלפון',
  'start': '2026-10-20T09:00',
  'end': '2026-10-20T10:00',
  'timezone': 'Asia/Jerusalem',
  'notes': 'תיאור מהיומן',
  'location': 'ירושלים',
  'all_day': false,
  'repeat': 'none',
  'color': 'blue',
  'reminder_minutes': 15,
  'invitees': <String>[],
};

http.Response response(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> withImport(
    WidgetTester tester,
    Future<void> Function(
            List<http.Request> requests, Future<bool> Function() result)
        check,
    {bool single = false,
    bool Function()? guard,
    bool typed = false,
    Size size = const Size(390, 844),
    http.Response? Function(http.Request)? respond}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <http.Request>[];
  late Future<bool> future;
  await http.runWithClient(() async {
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return Scaffold(
          body: FilledButton(
              key: const ValueKey('start-import'),
              onPressed: () {
                future = typed
                    ? openCalendarDraft(context,
                        api: 'https://example.test/api',
                        token: 'private-token',
                        draft: const {
                          'title': 'native-event',
                          'beginTime': 1234
                        },
                        canImport: guard)
                    : openCalendarImport(context,
                        api: 'https://example.test/api',
                        token: 'private-token',
                        rawText: 'BEGIN:VCALENDAR',
                        canImport: guard);
              },
              child: const Text('ייבוא')));
    })));
    await tester.tap(find.byKey(const ValueKey('start-import')));
    await tester.pumpAndSettle();
    try {
      await check(requests, () => future);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  },
      () => MockClient((request) async {
            requests.add(request);
            final overridden = respond?.call(request);
            if (overridden != null) return overridden;
            if (request.url.path.endsWith('/import/preview')) {
              return response({
                'drafts': [
                  {
                    'draft': draft,
                    'import_key': 'signed-preview-token',
                    'warnings': single ? ['לא ניתן לשמר את כללי החזרה.'] : [],
                    'requires_single_occurrence': single,
                  }
                ],
                'warnings': []
              });
            }
            if (request.url.path.endsWith('/settings')) {
              return response({
                'settings': {'timezone': 'Asia/Jerusalem'}
              });
            }
            if (request.method == 'POST' &&
                request.url.path.endsWith('/events')) {
              return response({
                'ids': ['new-event']
              }, 201);
            }
            return response({'error': 'unexpected request'}, 404);
          }));
}

void main() {
  testWidgets('preview and cancellation create no events', (tester) async {
    await withImport(tester, (requests, result) async {
      expect(
          find.byKey(const ValueKey('calendar-import-review')), findsOneWidget);
      expect(requests.single.url.path, endsWith('/import/preview'));
      expect(requests.single.headers['Authorization'], 'Bearer private-token');
      await tester.tap(find.text('ביטול'));
      await tester.pumpAndSettle();
      expect(await result(), false);
      expect(requests.where((r) => r.url.path.endsWith('/events')), isEmpty);
    });
  });

  testWidgets('personal imported draft is POSTed only after explicit save',
      (tester) async {
    await withImport(tester, (requests, result) async {
      await tester.tap(find.byKey(const ValueKey('calendar-import-continue')));
      await tester.pumpAndSettle();
      expect(find.text('אירוע חדש'), findsOneWidget);
      expect(find.text('הזמנת חברים'), findsNothing);
      expect(find.text('אירוע מהטלפון'), findsOneWidget);
      expect(requests.where((r) => r.url.path.endsWith('/events')), isEmpty);
      await tester.tap(find.text('שמירה'));
      await tester.pumpAndSettle();
      final saved = requests.singleWhere((r) => r.url.path.endsWith('/events'));
      expect(saved.method, 'POST');
      final body = jsonDecode(saved.body) as Map;
      expect(body['title'], draft['title']);
      expect(body['start'], draft['start']);
      expect(body['import_key'], 'signed-preview-token');
      expect(body['invitees'], isEmpty);
      expect(body.containsKey('version'), false);
      expect(await result(), true);
    });
  });

  testWidgets(
      'unsupported recurrence requires a separate single occurrence confirmation',
      (tester) async {
    await withImport(tester, (requests, result) async {
      await tester.tap(find.byKey(const ValueKey('calendar-import-continue')));
      await tester.pumpAndSettle();
      expect(find.text('ייבוא מופע אחד בלבד'), findsOneWidget);
      expect(requests.where((r) => r.url.path.endsWith('/events')), isEmpty);
      await tester
          .tap(find.byKey(const ValueKey('calendar-import-single-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('calendar-repeat')), findsNothing);
      await tester.tap(find.text('שמירה'));
      await tester.pumpAndSettle();
      final saved = jsonDecode(
              requests.singleWhere((r) => r.url.path.endsWith('/events')).body)
          as Map;
      expect(saved['repeat'], 'none');
      expect(saved['import_single_occurrence'], true);
      expect(await result(), true);
    }, single: true, size: const Size(320, 640));
  });

  testWidgets('failed save leaves the draft open for retry', (tester) async {
    var attempts = 0;
    await withImport(tester, (requests, result) async {
      await tester.tap(find.byKey(const ValueKey('calendar-import-continue')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('שמירה'));
      await tester.pumpAndSettle();
      expect(find.text('אירוע חדש'), findsOneWidget);
      expect(find.text('נסה שוב'), findsOneWidget);
      await tester.tap(find.text('שמירה'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(await result(), true);
    }, respond: (request) {
      if (request.url.path.endsWith('/events')) {
        attempts++;
        return attempts == 1
            ? response({'error': 'נסה שוב'}, 503)
            : response({
                'ids': ['new']
              }, 201);
      }
      return null;
    });
  });

  testWidgets('changing account after review prevents the pending save',
      (tester) async {
    var allowed = true;
    await withImport(tester, (requests, result) async {
      await tester.tap(find.byKey(const ValueKey('calendar-import-continue')));
      await tester.pumpAndSettle();
      allowed = false;
      await tester.tap(find.text('שמירה'));
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.url.path.endsWith('/events')), isEmpty);
      expect(await result(), false);
    }, guard: () => allowed);
  });

  testWidgets('native calendar extras use typed preview rather than chat text',
      (tester) async {
    await withImport(tester, (requests, result) async {
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['event']['beginTime'], 1234);
      expect(body.containsKey('ics'), false);
      await tester.tap(find.text('ביטול'));
      await tester.pumpAndSettle();
      expect(await result(), false);
    }, typed: true);
  });

  testWidgets(
      'web import input keeps file choice and paste inside a 320px viewport',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: FilledButton(
                    onPressed: () => openCalendarImportInput(context,
                        api: 'https://example.test/api', token: 'token'),
                    child: const Text('ייבוא'))))));
    await tester.tap(find.text('ייבוא'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('calendar-import-file')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('calendar-import-ics-text')), findsOneWidget);
    final box =
        tester.getRect(find.byKey(const ValueKey('calendar-import-input')));
    expect(box.left, greaterThanOrEqualTo(0));
    expect(box.right, lessThanOrEqualTo(320));
    await tester.tap(find.byKey(const ValueKey('calendar-import-preview')));
    await tester.pumpAndSettle();
    expect(
        find.text('יש לבחור קובץ אירוע או להדביק את תוכנו.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
  });
}
