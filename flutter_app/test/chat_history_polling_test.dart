import 'dart:async';
import 'dart:convert';

import 'package:betshuva/filter_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import 'own_media_filter_test.dart' as fixtures;

Map<String, dynamic> _text(String body) => {
      'id': body,
      'sender_id': 'friend',
      'sender_name': 'חבר',
      'type': 'text',
      'body': body,
      'created_at': '2026-09-17T00:02:00Z',
      'is_read': true,
    };

void _seedVisualCache(bool group) {
  SharedPreferences.setMockInitialValues({
    group ? 'cache_group_msgs_viewer_group' : 'cache_msgs_viewer_friend':
        jsonEncode([
      {
        'id': 'own-image',
        'from': 'viewer',
        'isMe': true,
        'isFile': true,
        'fileType': 'image',
        'fileUrl': fixtures.url,
        'fileName': 'own-image.png',
        'text': '',
        'status': 'sent',
      },
    ]),
  });
}

void main() {
  for (final group in [false, true]) {
    final scope = group ? 'group' : 'private';

    testWidgets('$scope slow initial history survives repeated poll ticks',
        (tester) async {
      fixtures.size(tester);
      _seedVisualCache(group);
      final response = Completer<http.Response>();
      var historyCalls = 0;
      final visualRequests = <Uri>[];

      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(group));
        await tester.pump(const Duration(milliseconds: 100));
        expect(historyCalls, 1);
        expect(fixtures.image(group), findsNothing);
        // Both the 4-second and 8-second polls run while the request is held.
        await tester.pump(const Duration(seconds: 9));
        expect(historyCalls, 1);
        expect(visualRequests, isEmpty,
            reason: 'Native cached images still require fresh visibility');
        response.complete(fixtures.json([
          fixtures.ownImage(true),
          _text('היסטוריה איטית שהגיעה'),
        ]));
        await tester.pumpAndSettle();
        expect(find.text('היסטוריה איטית שהגיעה'), findsOneWidget);
        expect(fixtures.image(group), findsNothing);
        expect(visualRequests, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
          () => MockClient((request) async {
                if (fixtures.isHistory(request, group)) {
                  historyCalls++;
                  return response.future;
                }
                if (request.url.toString() == fixtures.url) {
                  visualRequests.add(request.url);
                }
                return fixtures.defaultResponse(request);
              }));
    });

    testWidgets('$scope new filter generation bypasses an older slow request',
        (tester) async {
      fixtures.size(tester);
      _seedVisualCache(group);
      final oldResponse = Completer<http.Response>();
      final currentResponse = Completer<http.Response>();
      var historyCalls = 0;
      final visualRequests = <Uri>[];

      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(group));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(seconds: 5));
        expect(historyCalls, 1);
        receivingFilterChanges.add('token');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(historyCalls, 2,
            reason: 'New policy must not wait for an obsolete response');
        oldResponse.complete(fixtures.json([
          fixtures.ownImage(false),
          _text('תוכן מדור סינון ישן'),
        ]));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('תוכן מדור סינון ישן'), findsNothing);
        expect(fixtures.image(group), findsNothing);
        expect(visualRequests, isEmpty);
        // Completing the obsolete request must not clear the current gate.
        await tester.pump(const Duration(seconds: 5));
        expect(historyCalls, 2);
        currentResponse.complete(fixtures.json([
          fixtures.ownImage(true),
          _text('תוכן מדור סינון עדכני'),
        ]));
        await tester.pumpAndSettle();
        expect(find.text('תוכן מדור סינון עדכני'), findsOneWidget);
        expect(find.text('תוכן מדור סינון ישן'), findsNothing);
        expect(fixtures.image(group), findsNothing);
        expect(visualRequests, isEmpty);
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getString(group
            ? 'cache_group_msgs_viewer_group'
            : 'cache_msgs_viewer_friend');
        expect(saved, isNot(contains('תוכן מדור סינון ישן')));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
          () => MockClient((request) async {
                if (fixtures.isHistory(request, group)) {
                  historyCalls++;
                  return historyCalls == 1
                      ? oldResponse.future
                      : currentResponse.future;
                }
                if (request.url.toString() == fixtures.url) {
                  visualRequests.add(request.url);
                }
                return fixtures.defaultResponse(request);
              }));
    });

    testWidgets('$scope socket media update starts a fresh history request',
        (tester) async {
      fixtures.size(tester);
      _seedVisualCache(group);
      final oldResponse = Completer<http.Response>();
      final currentResponse = Completer<http.Response>();
      final socket = io.io('http://localhost:1',
          io.OptionBuilder().disableAutoConnect().enableForceNew().build());
      addTearDown(() {
        socket.connected = false;
        socket.dispose();
      });
      var historyCalls = 0;
      final visualRequests = <Uri>[];

      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(group, socket: socket));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(seconds: 5));
        expect(historyCalls, 1);
        socket.connected = true;
        socket.onevent({
          'data': [
            group ? 'group:message' : 'chat:message',
            {
              'id': 'own-image',
              'fromUserId': 'viewer',
              'toUserId': group ? null : 'friend',
              'groupId': group ? 'group' : null,
              'fileType': 'image',
              'fileUrl': fixtures.url,
              'fileName': 'own-image.png',
            },
          ],
        });
        socket.connected = false;
        await tester.pump(const Duration(milliseconds: 100));
        expect(historyCalls, 2,
            reason: 'A media update needs a request made after the event');
        oldResponse.complete(fixtures.json([
          fixtures.ownImage(false),
          _text('היסטוריה לפני הודעת המדיה'),
        ]));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(seconds: 5));
        expect(historyCalls, 2);
        expect(find.text('היסטוריה לפני הודעת המדיה'), findsNothing);
        expect(fixtures.image(group), findsNothing);
        expect(visualRequests, isEmpty);
        currentResponse.complete(fixtures.json([
          fixtures.ownImage(true),
          _text('סנכרון אחרי הודעת המדיה'),
        ]));
        await tester.pumpAndSettle();
        expect(find.text('סנכרון אחרי הודעת המדיה'), findsOneWidget);
        expect(fixtures.image(group), findsNothing);
        expect(visualRequests, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
          () => MockClient((request) async {
                if (fixtures.isHistory(request, group)) {
                  historyCalls++;
                  return historyCalls == 1
                      ? oldResponse.future
                      : currentResponse.future;
                }
                if (request.url.toString() == fixtures.url) {
                  visualRequests.add(request.url);
                }
                return fixtures.defaultResponse(request);
              }));
    });

    testWidgets('$scope failed history releases the next poll for retry',
        (tester) async {
      fixtures.size(tester);
      SharedPreferences.setMockInitialValues({});
      final firstResponse = Completer<http.Response>();
      var historyCalls = 0;

      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(group));
        await tester.pump(const Duration(milliseconds: 100));
        expect(historyCalls, 1);
        await tester.pump(const Duration(seconds: 5));
        expect(historyCalls, 1);
        firstResponse.completeError(http.ClientException('synthetic failure'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(historyCalls, 2);
        expect(find.text('היסטוריה אחרי ניסיון נוסף'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
          () => MockClient((request) async {
                if (fixtures.isHistory(request, group)) {
                  historyCalls++;
                  if (historyCalls == 1) return firstResponse.future;
                  return fixtures.json([_text('היסטוריה אחרי ניסיון נוסף')]);
                }
                return fixtures.defaultResponse(request);
              }));
    });

    testWidgets('$scope timed-out history permits retry and ignores late media',
        (tester) async {
      fixtures.size(tester);
      _seedVisualCache(group);
      final lateResponse = Completer<http.Response>();
      var historyCalls = 0;
      final visualRequests = <Uri>[];

      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(group));
        await tester.pump(const Duration(milliseconds: 100));
        expect(historyCalls, 1);
        await tester.pump(const Duration(seconds: 21));
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(historyCalls, 2);
        expect(find.text('היסטוריה אחרי פסק זמן'), findsOneWidget);
        lateResponse.complete(fixtures.json([fixtures.ownImage(false)]));
        await tester.pump(const Duration(milliseconds: 100));
        expect(fixtures.image(group), findsNothing);
        expect(visualRequests, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
          () => MockClient((request) async {
                if (fixtures.isHistory(request, group)) {
                  historyCalls++;
                  if (historyCalls == 1) return lateResponse.future;
                  return fixtures.json([_text('היסטוריה אחרי פסק זמן')]);
                }
                if (request.url.toString() == fixtures.url) {
                  visualRequests.add(request.url);
                }
                return fixtures.defaultResponse(request);
              }));
    });

    testWidgets('$scope pending history is ignored after disposal',
        (tester) async {
      fixtures.size(tester);
      SharedPreferences.setMockInitialValues({});
      final response = Completer<http.Response>();
      var historyCalls = 0;

      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(group));
        await tester.pump(const Duration(milliseconds: 100));
        expect(historyCalls, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        response.complete(fixtures.json([_text('תגובה אחרי סגירת השיחה')]));
        await tester.pump(const Duration(seconds: 5));
        expect(historyCalls, 1);
        expect(find.text('תגובה אחרי סגירת השיחה'), findsNothing);
        expect(tester.takeException(), isNull);
      },
          () => MockClient((request) async {
                if (fixtures.isHistory(request, group)) {
                  historyCalls++;
                  return response.future;
                }
                return fixtures.defaultResponse(request);
              }));
    });
  }
}
