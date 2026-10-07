import 'dart:async';
import 'dart:convert';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:betshuva/direct_support_buttons.dart';

final _supportPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC');

class _SupportPhoto extends XFile {
  _SupportPhoto(super.path, {this.type = 'image/png'});
  final String? type;
  @override
  String get name => path;
  @override
  String? get mimeType => type;
  @override
  Future<Uint8List> readAsBytes() async => _supportPng;
  @override
  Future<int> length() async => _supportPng.length;
}

Future<void> _openImages(
    WidgetTester tester, http.Client client, List<XFile> images) async {
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: DirectSupportButtons(
              api: 'https://example.test/api',
              token: 'test-token',
              appVersion: 'test',
              client: client,
              pickImages: () async => images))));
  await tester.tap(find.text('בקשה לשיפור'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField), 'תיאור שנשמר עם התמונות');
  await tester.tap(find.text('הוספת תמונות'));
  await tester.pumpAndSettle();
  expect(find.byType(Image), findsNWidgets(images.length));
}

void main() {
  for (final entry in {
    403: {'reason': 'סוג התמונה חסום בהגדרות הסינון שלך'},
    429: {'error': 'נא להמתין לפני ניסיון נוסף', 'retryAfter': 30},
  }.entries) {
    testWidgets('HTTP ${entry.key} shows upload reason and preserves retry',
        (tester) async {
      final uploads = <http.Request>[];
      final issues = <http.Request>[];
      var failure = true;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/upload')) {
          uploads.add(request);
          return failure
              ? http.Response(jsonEncode(entry.value), entry.key,
                  headers: {'content-type': 'application/json; charset=utf-8'})
              : http.Response('{"url":"/uploads/retry.png"}', 200);
        }
        issues.add(request);
        return http.Response('{"id":"created"}', 201);
      });
      addTearDown(client.close);
      await _openImages(tester, client, [_SupportPhoto('retry.png')]);
      expect(uploads, isEmpty);
      await tester.tap(find.text('שליחת הפנייה'));
      await tester.pumpAndSettle();
      expect(uploads.length, 1);
      expect(issues, isEmpty);
      expect(find.textContaining('העלאת תמונה 1 נכשלה'), findsOneWidget);
      expect(
          find.textContaining(entry.value['reason']?.toString() ??
              entry.value['error']!.toString()),
          findsOneWidget);
      expect(find.text('תיאור שנשמר עם התמונות'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull);
      failure = false;
      await tester.tap(find.text('שליחת הפנייה'));
      await tester.pumpAndSettle();
      expect(uploads.length, 2);
      expect(issues.length, 1);
      expect(jsonDecode(issues.single.body)['attachmentUrls'],
          ['/uploads/retry.png']);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  testWidgets('partial multi-image failure retains progress and cached URLs',
      (tester) async {
    final uploads = <http.Request>[];
    final issues = <http.Request>[];
    final second = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/upload')) {
        uploads.add(request);
        final body = latin1.decode(request.bodyBytes);
        if (body.contains('filename="first.png"')) {
          return http.Response('{"url":"/uploads/first.png"}', 200);
        }
        if (uploads.length == 2) return second.future;
        return http.Response('{"url":"/uploads/second.png"}', 200);
      }
      issues.add(request);
      return http.Response('{"id":"created"}', 201);
    });
    addTearDown(client.close);
    await _openImages(tester, client,
        [_SupportPhoto('first.png'), _SupportPhoto('second.png')]);
    await tester.tap(find.text('שליחת הפנייה'));
    await tester.pump();
    await tester.pump();
    expect(uploads.length, 2);
    expect(find.text('צירוף תמונות: 1 מתוך 2'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(issues, isEmpty);
    second.complete(http.Response(
        '{"error":"שירות העלאת התמונות אינו זמין כרגע"}', 503,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pumpAndSettle();
    expect(find.textContaining('העלאת תמונה 2 נכשלה'), findsOneWidget);
    expect(find.textContaining('שירות העלאת התמונות אינו זמין כרגע'),
        findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    await tester.tap(find.text('שליחת הפנייה'));
    await tester.pumpAndSettle();
    expect(uploads.length, 3);
    expect(latin1.decode(uploads.last.bodyBytes),
        contains('filename="second.png"'));
    expect(
        uploads
            .where((request) => latin1
                .decode(request.bodyBytes)
                .contains('filename="first.png"'))
            .length,
        1);
    expect(jsonDecode(issues.single.body)['attachmentUrls'],
        ['/uploads/first.png', '/uploads/second.png']);
    expect(find.byType(AlertDialog), findsNothing);
  });

  for (final mime in ['', 'application/octet-stream', 'invalid mime']) {
    testWidgets('PNG with unreliable MIME "$mime" uses image/png',
        (tester) async {
      final uploads = <http.Request>[];
      final issues = <http.Request>[];
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/upload')) {
          uploads.add(request);
          return http.Response('{"url":"/uploads/pasted.png"}', 200);
        }
        issues.add(request);
        return http.Response('{"id":"created"}', 201);
      });
      addTearDown(client.close);
      await _openImages(
          tester, client, [_SupportPhoto('pasted-image', type: mime)]);
      await tester.tap(find.text('שליחת הפנייה'));
      await tester.pumpAndSettle();
      expect(uploads.length, 1);
      expect(latin1.decode(uploads.single.bodyBytes).toLowerCase(),
          contains('content-type: image/png'));
      expect(issues.length, 1);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  testWidgets('selected images preview, removal and retry preserve attachments',
      (tester) async {
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC');
    final requests = <http.Request>[];
    var fail = true;
    final client = MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/upload')) {
        if (fail) return http.Response('{}', 503);
        return http.Response('{"url":"/uploads/test.png"}', 200);
      }
      return http.Response('{"id":"created"}', 201);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DirectSupportButtons(
                api: 'https://example.test/api',
                token: 'token',
                appVersion: 'test',
                client: client,
                pickImages: () async => [
                      XFile.fromData(bytes,
                          name: 'first.png',
                          path: kIsWeb ? null : 'first.png',
                          mimeType: 'image/png'),
                      XFile.fromData(bytes,
                          name: 'second.png',
                          path: kIsWeb ? null : 'second.png',
                          mimeType: 'image/png')
                    ]))));
    await tester.tap(find.text('בקשה לשיפור'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'בקשה עם תמונות');
    await tester.runAsync(() async {
      await tester.tap(find.text('הוספת תמונות'));
      // Browser FileReader completes on the real event loop.
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.byType(Image).evaluate().length == 2) break;
      }
    });
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNWidgets(2));
    expect(requests, isEmpty);
    await tester.tap(find.byTooltip('הסרת תמונה 1'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('שליחת הפנייה'));
    await tester.pumpAndSettle();
    expect(requests.length, 1);
    expect(find.textContaining('העלאת תמונה 1 נכשלה'), findsOneWidget);
    expect(find.text('בקשה עם תמונות'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('שליחת הפנייה'));
    await tester.pumpAndSettle();
    expect(requests.length, 3);
    expect(latin1.decode(requests[1].bodyBytes),
        contains('filename="second.png"'));
    expect(latin1.decode(requests[1].bodyBytes), isNot(contains('first.png')));
    expect(jsonDecode(requests.last.body)['attachmentUrls'],
        ['/uploads/test.png']);
    expect(find.byType(AlertDialog), findsNothing);
    client.close();
  });
  for (final entry
      in {'בקשה לשיפור': 'feature', 'דיווח על תקלה': 'bug'}.entries) {
    testWidgets(
        '${entry.key} opens a form and sends only after explicit submission',
        (tester) async {
      final requests = <http.Request>[];
      final done = Completer<http.Response>();
      final client = MockClient((request) {
        requests.add(request);
        return done.future;
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: DirectSupportButtons(
                  api: 'https://example.test/api',
                  token: 'test-token',
                  appVersion: 'test',
                  client: client))));
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester.tap(find.text('שליחת הפנייה'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(find.text('יש להזין לפחות 5 תווים'), findsOneWidget);
      await tester.enterText(
          find.byType(TextFormField), 'תיאור מפורט של הבקשה');
      await tester.tap(find.text('שליחת הפנייה'));
      await tester.pump();
      expect(requests.length, 1);
      expect(requests.single.headers['authorization'], 'Bearer test-token');
      expect(jsonDecode(requests.single.body)['issueType'], entry.value);
      expect(jsonDecode(requests.single.body)['description'],
          'תיאור מפורט של הבקשה');
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      done.complete(http.Response('{"id":"created"}', 201));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('הפנייה נשלחה'), findsOneWidget);
      client.close();
    });
  }
  testWidgets('cancel never sends and a server error preserves the draft',
      (tester) async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response('{}', 503);
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DirectSupportButtons(
                api: 'https://example.test/api',
                token: 'token',
                appVersion: 'test',
                client: client))));
    await tester.tap(find.text('דיווח על תקלה'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.tap(find.text('דיווח על תקלה'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'תיאור התקלה שנשמר');
    await tester.tap(find.text('שליחת הפנייה'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('תיאור התקלה שנשמר'), findsOneWidget);
    expect(find.text('לא ניתן לשלוח את הפנייה'), findsOneWidget);
    client.close();
  });
}
