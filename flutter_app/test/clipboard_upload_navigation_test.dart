import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'own_media_filter_test.dart' as fixtures;
import 'upload_navigation_test.dart' as navigation;

void main() {
  for (final group in [false, true]) {
    testWidgets(
        'pasted image is nonmodal and sends after navigation group=$group',
        (tester) async {
      fixtures.size(tester);
      SharedPreferences.setMockInitialValues({});
      const channel = MethodChannel('com.betshuva.app/media');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pasteImage');
        return {
          'bytes': fixtures.png,
          'fileName': 'clipboard-test.png',
          'mimeType': 'image/png'
        };
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
      });
      final response = Completer<http.Response>();
      final target = group ? 'group' : 'friend';
      var uploads = 0, sends = 0;
      await http.runWithClient(() async {
        await tester.pumpWidget(navigation.conversation(group, target));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.attach_file));
        await tester.pumpAndSettle();
        await tester.tap(find.text('הדבק תמונה'));
        await navigation.until(tester, () => uploads == 1);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(AlertDialog), findsNothing);
        await tester.pump();
        await tester.tap(find.byType(TextField).last);
        await tester.pump();
        expect(
            tester
                .widget<EditableText>(find.byType(EditableText).last)
                .focusNode
                .hasFocus,
            isTrue);
        expect(find.text('סריקה והעלאה'), findsNothing);
        expect(find.textContaining('מעלה ואחר כך סורק'), findsOneWidget);
        await tester.pumpWidget(navigation.conversation(group, 'other'));
        await tester.pumpAndSettle();
        expect(sends, 0);
        response.complete(fixtures.json(
            {'url': '/uploads/clipboard-test.png', 'status': 'approved'}));
        await navigation.until(tester, () => sends == 1);
        await tester.pumpAndSettle();
        expect(uploads, 1);
        expect(sends, 1);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
          () => MockClient((request) async {
                final path = request.url.path;
                if (request.method == 'GET' &&
                    (path.endsWith('/messages') ||
                        path.contains('/messages/'))) {
                  return fixtures.json([]);
                }
                if (path.endsWith('/upload')) {
                  uploads++;
                  final body = latin1.decode(request.bodyBytes);
                  expect(body, contains('name="clipboardPaste"\r\n\r\ntrue'));
                  expect(
                      body,
                      contains(
                          'name="${group ? 'groupId' : 'toUserId'}"\r\n\r\n$target'));
                  return response.future;
                }
                if (request.method == 'POST' && path.endsWith('/messages')) {
                  final body = jsonDecode(request.body) as Map;
                  expect(body['fileName'], 'clipboard-test.png');
                  expect(body['fileType'], 'image');
                  if (group) {
                    expect(path, endsWith('/groups/$target/messages'));
                  } else {
                    expect(body['toUserId'], target);
                  }
                  sends++;
                  return fixtures
                      .json({'id': 'clipboard-message', 'status': 'sent'});
                }
                return fixtures.defaultResponse(request);
              }));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
