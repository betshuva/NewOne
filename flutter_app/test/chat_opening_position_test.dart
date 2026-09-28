import 'dart:async';
import 'dart:convert';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final group in [false, true]) {
    for (final unread in [false, true]) {
      testWidgets(
          '${group ? 'group' : 'private'} opens at ${unread ? 'unread' : 'latest'} after stale cache',
          (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final cacheKey =
            group ? 'cache_group_msgs_viewer_peer' : 'cache_msgs_viewer_peer';
        SharedPreferences.setMockInitialValues({
          cacheKey: jsonEncode([
            {
              'id': 'cached',
              'text': 'הודעה שמורה ישנה',
              'isUnread': true,
              'isMe': false,
              'from': 'peer',
              'senderName': 'חבר',
              'isFile': false,
              'createdAt': '2026-09-27T09:00:00Z',
              'time': '09:00',
              'status': 'sent'
            },
          ])
        });
        final messages = List.generate(
            100,
            (i) => <String, dynamic>{
                  'id': 'message-$i',
                  'sender_id': i == 0 ? 'viewer' : 'peer',
                  'recipient_id': 'viewer',
                  'sender_name': 'חבר',
                  'type': 'text',
                  'body': 'הודעה מספר $i',
                  'created_at':
                      DateTime.utc(2026, 9, 27, 10, i).toIso8601String(),
                  'is_read': i == 0 || (unread && i >= 20) ? 0 : 1,
                });
        final firstResponse = Completer<http.Response>();
        final requests = <http.Request>[];
        var loads = 0;
        http.Response json(Object data) => http.Response(jsonEncode(data), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
        await http.runWithClient(() async {
          await tester.pumpWidget(MaterialApp(
              home: Directionality(
            textDirection: TextDirection.rtl,
            child: group
                ? GroupChatScreen(
                    token: 'test',
                    socket: null,
                    me: const {'id': 'viewer', 'name': 'אני'},
                    group: {
                      'id': 'peer',
                      'name': 'חבר',
                      'status': 'member',
                      'role': 'member'
                    },
                    embedded: true)
                : const ChatScreen(
                    token: 'test',
                    socket: null,
                    me: {'id': 'viewer', 'name': 'אני'},
                    recipient: {'id': 'peer', 'name': 'חבר'},
                    embedded: true),
          )));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pumpAndSettle();
          firstResponse.complete(json(messages));
          await tester.pumpAndSettle();
          final target = find.text('הודעה מספר ${unread ? 20 : 99}');
          expect(target.hitTestable(), findsOneWidget);
          if (unread) {
            expect(find.text('הודעות שלא נקראו').hitTestable(), findsOneWidget);
          }
          expect(
              requests
                  .firstWhere((r) =>
                      r.method == 'GET' &&
                      r.url.path
                          .endsWith(group ? '/messages' : '/messages/peer'))
                  .url
                  .queryParameters['initialUnread'],
              '1');
          // Server read acknowledgements must not change the opening position.
          for (final m in messages) {
            m['is_read'] = 1;
          }
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
          expect(target.hitTestable(), findsOneWidget);
          expect(loads, greaterThan(1));
          expect(
              requests.any(
                  (r) => r.url.queryParameters.containsKey('historySince')),
              isTrue);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
        },
            () => MockClient((request) async {
                  requests.add(request);
                  if (request.method == 'GET' &&
                      request.url.path.endsWith(
                          group ? '/groups/peer/messages' : '/messages/peer')) {
                    loads++;
                    if (loads == 1) return firstResponse.future;
                    return json(messages);
                  }
                  if (request.url.path.endsWith('/groups') ||
                      request.url.path.endsWith('/users')) {
                    return json([]);
                  }
                  if (request.url.path.endsWith('/groups/peer')) {
                    return json({'members': []});
                  }
                  return json({});
                }));
      });
    }
  }
}
