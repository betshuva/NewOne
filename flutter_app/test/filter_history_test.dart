import 'dart:async';
import 'dart:convert';
import 'package:betshuva/filter_history.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response json(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
const allowed = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true
};
const _receivedImageId = 'd121cb79-7fa9-45b1-aa50-832306b2834a';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in ['hide', 'delete', 'keep']) {
    testWidgets(
        '$action retries only after explicit choice and preserves payload',
        (tester) async {
      final requests = <Map<String, dynamic>>[];
      final notifications = <String>[];
      final subscription =
          receivingFilterChanges.stream.listen(notifications.add);
      addTearDown(subscription.cancel);
      http.Response? result;
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
            home: Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () async {
                          result = await saveReceivingFilter(
                              context: context,
                              api: 'https://example.test/api',
                              token: 'token',
                              path: '/contacts/friend/filter-settings',
                              body: {
                                'filter': {...allowed, 'men': false},
                                'sharePhone': false
                              });
                        },
                        child: const Text('save'))))));
        await tester.tap(find.text('save'));
        await tester.pumpAndSettle();
        expect(requests, hasLength(1));
        expect(notifications, isEmpty);
        expect(find.textContaining('נמצאו 3 תמונות'), findsOneWidget);
        await tester.tap(find.byKey(ValueKey('existing-media-$action')));
        await tester.pumpAndSettle();
        expect(requests, hasLength(2));
        expect(requests.last['existingMediaAction'], action);
        expect(requests.last['filter'], {...allowed, 'men': false});
        expect(requests.last['sharePhone'], false);
        expect(
            (requests.last['filter'] as Map).containsKey('existingMediaAction'),
            false);
        expect(notifications, ['token']);
        expect(result?.statusCode, 200);
      },
          () => MockClient((request) async {
                requests
                    .add(Map<String, dynamic>.from(jsonDecode(request.body)));
                return requests.length == 1
                    ? json({
                        'code': 'EXISTING_MEDIA_CHOICE_REQUIRED',
                        'affectedCount': 3
                      }, 409)
                    : json({
                        'filter': {...allowed, 'men': false}
                      });
              }));
    });
  }

  testWidgets('cancelling historical media choice does not retry or invalidate',
      (tester) async {
    var requests = 0;
    var completed = false;
    final notifications = <String>[];
    final subscription =
        receivingFilterChanges.stream.listen(notifications.add);
    addTearDown(subscription.cancel);
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        final result = await saveReceivingFilter(
                            context: context,
                            api: 'https://example.test/api',
                            token: 'token',
                            path: '/filter-settings',
                            body: {...allowed, 'men': false});
                        expect(result, null);
                        completed = true;
                      },
                      child: const Text('save'))))));
      await tester.tap(find.text('save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ביטול השינוי'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(completed, true);
      expect(notifications, isEmpty);
    },
        () => MockClient((request) async {
              requests++;
              return json({
                'code': 'EXISTING_MEDIA_CHOICE_REQUIRED',
                'affectedCount': 1
              }, 409);
            }));
  });

  testWidgets(
      'hidden placeholder reports visibility and restores only its message',
      (tester) async {
    final requests = <http.Request>[];
    var restored = false;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: FilterHiddenImage(
                  api: 'https://example.test/api',
                  token: 'token',
                  messageId: _receivedImageId,
                  onRestored: () async {
                    restored = true;
                  }))));
      await tester.pumpAndSettle();
      expect(
          requests.where((r) => r.url.path.endsWith('/filter-display-events')),
          hasLength(1));
      final event = jsonDecode(requests.first.body) as Map;
      expect(event['event'], 'hidden');
      expect(event['messageId'], _receivedImageId);
      expect(DateTime.tryParse(event['clientTime'] as String), isNotNull);
      await tester.tap(find.text('להחזיר את התמונה הזו'));
      await tester.pumpAndSettle();
      final restore = requests
          .where((r) => r.url.path.endsWith('/filter-visibility'))
          .single;
      expect(restore.url.path,
          '/api/messages/$_receivedImageId/filter-visibility');
      expect(jsonDecode(restore.body), {'action': 'restore'});
      expect(restored, true);
    },
        () => MockClient((request) async {
              requests.add(request);
              return json({});
            }));
  });

  for (final fixture in [
    (
      name: 'pending synthetic scan',
      id: 'scan_$_receivedImageId',
      hiddenReason: 'moderation',
      status: 'pending_scan',
      reason: null,
      purged: false,
      expected: 'התמונה ממתינה לסריקה ולאישור',
    ),
    (
      name: 'pending status overrides content-filter metadata',
      id: _receivedImageId,
      hiddenReason: 'content_filter',
      status: 'pending',
      reason: null,
      purged: false,
      expected: 'התמונה ממתינה לסריקה ולאישור',
    ),
    (
      name: 'rejected synthetic scan displays the real scan reason',
      id: 'scan_$_receivedImageId',
      hiddenReason: 'moderation',
      status: 'rejected_scan',
      reason: '  התמונה נחסמה בשל תוכן אלים  ',
      purged: false,
      expected: 'התמונה נחסמה בבדיקת הבטיחות\nהתמונה נחסמה בשל תוכן אלים',
    ),
    (
      name:
          'rejected persisted image cannot restore through stale filter metadata',
      id: _receivedImageId,
      hiddenReason: 'content_filter',
      status: 'rejected',
      reason: 'תוצאת בדיקת הבטיחות',
      purged: false,
      expected: 'התמונה נחסמה בבדיקת הבטיחות\nתוצאת בדיקת הבטיחות',
    ),
    (
      name: 'purged image cannot restore even with approved filter metadata',
      id: _receivedImageId,
      hiddenReason: 'content_filter',
      status: 'approved',
      reason: null,
      purged: true,
      expected: 'התמונה נמחקה ואינה זמינה עוד',
    ),
    (
      name: 'missing metadata does not pretend to be a filter preference',
      id: _receivedImageId,
      hiddenReason: null,
      status: null,
      reason: null,
      purged: false,
      expected: 'התמונה אינה זמינה כעת',
    ),
    (
      name: 'unknown moderation state remains unavailable',
      id: _receivedImageId,
      hiddenReason: 'moderation',
      status: 'sent',
      reason: null,
      purged: false,
      expected: 'התמונה אינה זמינה כעת',
    ),
    (
      name: 'approved synthetic ID cannot offer historical filter restore',
      id: 'scan_$_receivedImageId',
      hiddenReason: 'content_filter',
      status: 'approved',
      reason: null,
      purged: false,
      expected: 'התמונה אינה זמינה כעת',
    ),
  ]) {
    testWidgets(fixture.name, (tester) async {
      final requests = <http.Request>[];
      var restored = false;
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: FilterHiddenImage(
              api: 'https://example.test/api',
              token: 'token',
              messageId: fixture.id,
              hiddenReason: fixture.hiddenReason,
              status: fixture.status,
              reason: fixture.reason,
              contentPurged: fixture.purged,
              onRestored: () async {
                restored = true;
              },
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(find.text(fixture.expected), findsOneWidget);
        expect(find.text('התמונה מוסתרת לפי בחירת הסינון שלך'), findsNothing);
        expect(find.text('להחזיר את התמונה הזו'), findsNothing);
        expect(find.byType(TextButton), findsNothing);
        expect(restored, isFalse);
        expect(requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
          () => MockClient((request) async {
                requests.add(request);
                return json({});
              }));
    });
  }

  testWidgets(
      'placeholder reports only actual content-filter visibility after state change',
      (tester) async {
    final requests = <http.Request>[];
    Widget placeholder(String hiddenReason, String status) => MaterialApp(
          home: Scaffold(
            body: FilterHiddenImage(
              key: const ValueKey('same-image'),
              api: 'https://example.test/api',
              token: 'token',
              messageId: _receivedImageId,
              hiddenReason: hiddenReason,
              status: status,
              onRestored: () async {},
            ),
          ),
        );
    await http.runWithClient(() async {
      await tester.pumpWidget(placeholder('moderation', 'pending'));
      await tester.pumpAndSettle();
      expect(find.text('התמונה ממתינה לסריקה ולאישור'), findsOneWidget);
      expect(requests, isEmpty);

      await tester.pumpWidget(placeholder('content_filter', 'approved'));
      await tester.pumpAndSettle();
      expect(find.text('התמונה מוסתרת לפי בחירת הסינון שלך'), findsOneWidget);
      expect(find.text('להחזיר את התמונה הזו'), findsOneWidget);
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/api/filter-display-events');
      expect(jsonDecode(requests.single.body)['messageId'], _receivedImageId);
      expect(jsonDecode(requests.single.body)['event'], 'hidden');

      await tester.pumpWidget(placeholder('content_filter', 'approved'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      await tester.pumpWidget(placeholder('moderation', 'rejected'));
      await tester.pumpAndSettle();
      expect(find.text('התמונה נחסמה בבדיקת הבטיחות'), findsOneWidget);
      expect(find.text('להחזיר את התמונה הזו'), findsNothing);
      expect(requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              requests.add(request);
              return json({});
            }));
  });

  testWidgets('cancelling the history choice aborts the first message send',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final sent = <http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
          home: ChatScreen(
              token: 'token',
              me: {'id': 'viewer'},
              recipient: {'id': 'friend', 'name': 'חבר'},
              socket: null,
              embedded: true)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'הודעת ניסיון');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(find.text('בחירת התוכן שאקבל מחבר'), findsOneWidget);
      await tester.tap(find.textContaining('שמור והמשך').last);
      await tester.pumpAndSettle();
      expect(find.text('מה לעשות עם התמונות הקיימות?'), findsOneWidget);
      await tester.tap(find.text('ביטול השינוי'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(find.text('הודעת ניסיון'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
        () => MockClient((request) async {
              final path = request.url.path;
              if (path.endsWith('/messages') && request.method == 'POST') {
                sent.add(request);
                return json({});
              }
              if (path.endsWith('/messages/friend')) return json([]);
              if (path.endsWith('/filter-comparison')) {
                return json({
                  'personalFilter': allowed,
                  'counterpartFilterAvailable': false
                });
              }
              if (path.endsWith('/filter-settings')) {
                if (request.method == 'PUT') {
                  return json({
                    'code': 'EXISTING_MEDIA_CHOICE_REQUIRED',
                    'affectedCount': 1
                  }, 409);
                }
                return json({'filter': allowed, 'requiresChoice': true});
              }
              if (path.endsWith('/receiving-filter')) {
                return json({'filter': allowed});
              }
              return json({});
            }));
  });

  testWidgets(
      'old cached received image waits for history and current card ignores snapshot',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'cache_msgs_viewer_friend': jsonEncode([
        {
          'id': _receivedImageId,
          'from': 'friend',
          'isFile': true,
          'fileType': 'image',
          'fileUrl': 'https://example.test/old.png',
          'fileName': 'old.png',
          'text': ''
        },
      ])
    });
    final gate = Completer<void>();
    final requestedMedia = <String>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
          home: ChatScreen(
              token: 'token',
              socket: null,
              me: {'id': 'viewer'},
              recipient: {'id': 'friend', 'name': 'חבר'},
              embedded: true)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(requestedMedia, isEmpty);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('חסום: גברים, נשים'), findsOneWidget);
      expect(find.text('חסום: ללא'), findsNothing);
      expect(find.text('התמונה מוסתרת לפי בחירת הסינון שלך'), findsOneWidget);
      expect(requestedMedia, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              final path = request.url.path;
              if (path == '/old.png') {
                requestedMedia.add(path);
                return http.Response('', 404);
              }
              if (path.endsWith('/messages/friend')) {
                await gate.future;
                return json([
                  {
                    'id': 'private',
                    'type': 'private_filter',
                    'private_filter': allowed,
                    'created_at': '2026-09-17T00:00:00Z'
                  },
                  {
                    'id': _receivedImageId,
                    'sender_id': 'friend',
                    'type': 'image',
                    'filter_hidden': true,
                    'hidden_reason': 'content_filter',
                    'file_url': null,
                    'created_at': '2026-09-17T00:01:00Z'
                  },
                ]);
              }
              if (path.endsWith('/filter-settings')) {
                return json({
                  'filter': {...allowed, 'men': false, 'women': false},
                  'requiresChoice': false
                });
              }
              if (path.endsWith('/receiving-filter')) {
                return json({'filter': allowed});
              }
              return json({});
            }));
  });
}
