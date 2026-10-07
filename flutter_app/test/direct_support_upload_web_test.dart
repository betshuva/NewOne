@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js' as js;

import 'package:betshuva/direct_support_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/listing_upload_browser.dart';

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC');

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 250 && !done(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue, reason: 'The browser upload did not finish');
}

void main() {
  testWidgets(
      'clipboard images survive released source blobs and retry uses cached uploads',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final browser = ListingUploadBrowser()..install();
    addTearDown(browser.dispose);
    browser.complete('first.png');
    browser.failOnce('second.png', 403, {'reason': 'התמונה חסומה בסינון'});

    // The paste bridge releases its original object URLs after reading the
    // selected bytes. Track that lifecycle without keeping those URLs alive.
    js.context.callMethod('eval', [
      r'''
      (() => {
        const original = URL.revokeObjectURL, revoked = [];
        URL.revokeObjectURL = function(url) {revoked.push(url); return original.call(URL, url);};
        window.supportSourceBlobs = {json: () => JSON.stringify(revoked),
          restore: () => {URL.revokeObjectURL = original; delete window.supportSourceBlobs;}};
      })();
    '''
    ]);
    final sources = js.context['supportSourceBlobs'] as js.JsObject;
    addTearDown(() => sources.callMethod('restore'));
    final issueRequests = <http.Request>[];

    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: DirectSupportButtons(
              api: 'https://example.test/api',
              token: 'original-token',
              appVersion: 'test'),
        ),
      ));
      await tester.tap(find.text('בקשה לשיפור'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'בקשה עם שתי תמונות');
      final data = html.DataTransfer();
      for (final name in ['first.png', 'second.png']) {
        data.items!.addFile(html.File([_png], name, {'type': 'image/png'}));
      }
      final paste = html.ClipboardEvent('paste',
          {'clipboardData': data, 'bubbles': true, 'cancelable': true});
      html.document.dispatchEvent(paste);
      expect(paste.defaultPrevented, isTrue);
      await _until(tester, () => find.byType(Image).evaluate().length == 2);
      await _until(
          tester,
          () =>
              (jsonDecode(sources.callMethod('json') as String) as List)
                  .length >=
              2);
      expect(browser.requests, isEmpty);
      expect(issueRequests, isEmpty);
      await tester.tap(find.text('שליחת הפנייה'));
      await _until(tester, () => browser.requests.length == 2);
      expect(find.text('צירוף תמונות: 1 מתוך 2'), findsOneWidget);
      expect(issueRequests, isEmpty);
      browser.complete('second.png');
      await _until(
          tester,
          () =>
              find.textContaining('התמונה חסומה בסינון').evaluate().isNotEmpty);
      expect(find.textContaining('העלאת תמונה 2 נכשלה'), findsOneWidget);
      expect(find.textContaining('התמונה חסומה בסינון'), findsOneWidget);
      expect(find.text('בקשה עם שתי תמונות'), findsOneWidget);
      expect(find.byType(Image), findsNWidgets(2));
      expect(issueRequests, isEmpty);

      await tester.tap(find.text('שליחת הפנייה'));
      await _until(tester, () => issueRequests.length == 1);
      await _until(tester,
          () => find.text('שמירת הפנייה נכשלה זמנית').evaluate().isNotEmpty);
      expect(browser.requests.length, 3);
      expect(browser.records.map((record) => record['meta']['name']),
          ['first.png', 'second.png', 'second.png']);
      for (final record in browser.records) {
        expect(record['headers']['Authorization'], 'Bearer original-token');
        expect(record['meta']['size'], _png.length);
        expect(record['meta']['mime'], 'image/png');
        expect(record['meta']['fields'], isEmpty);
      }
      for (final chunk in browser.chunks) {
        expect(chunk['bytes'], _png);
      }
      // An issue-write failure retries the issue only. Both successful image
      // URLs remain cached in the draft, so no fourth upload is created.
      await tester.tap(find.text('שליחת הפנייה'));
      await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
      expect(browser.requests.length, 3);
      expect(issueRequests.length, 2);
      for (final issue in issueRequests) {
        expect(issue.headers['Authorization'], 'Bearer original-token');
        expect(jsonDecode(issue.body)['attachmentUrls'], [
          'https://example.test/first.png',
          'https://example.test/second.png'
        ]);
        expect(jsonDecode(issue.body)['clientContext']['platform'], 'web');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
        () => MockClient((request) async {
              expect(request.method, 'POST');
              expect(request.url.path, '/api/support-issues');
              issueRequests.add(request);
              return issueRequests.length == 1
                  ? http.Response('{"error":"שמירת הפנייה נכשלה זמנית"}', 503,
                      headers: {
                          'content-type': 'application/json; charset=utf-8'
                        })
                  : http.Response('{"id":"created"}', 201);
            }));
  });
}
