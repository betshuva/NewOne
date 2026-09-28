import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final isGroup in [false, true]) {
    testWidgets(
        '${isGroup ? 'group' : 'private'} retained images support selecting and deselecting multiple items',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      const reason = 'תמונות גברים חסומות בהגדרות הנמען';
      const filename = 'blocked-photo.png';
      const imageUrl = 'https://example.test/blocked-photo.png';
      const group = {
        'id': 'group',
        'name': 'קבוצת בדיקה',
        'status': 'member',
        'role': 'member',
        'send_permission': 'all',
      };
      const allowed = {
        'text': true,
        'video': true,
        'nonHumanImages': true,
        'men': true,
        'women': true,
        'children': true,
      };
      final requests = <http.Request>[];
      final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');
      final preview = find.byKey(const ValueKey('blocked-image-preview'));
      final menu = find.byKey(const ValueKey('blocked-image-menu'));

      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: isGroup
                ? GroupChatScreen(
                    token: 'test-token',
                    socket: null,
                    me: const {'id': 'viewer', 'name': 'אני'},
                    group: group,
                    embedded: true,
                  )
                : const ChatScreen(
                    token: 'test-token',
                    socket: null,
                    me: {'id': 'viewer', 'name': 'אני'},
                    recipient: {'id': 'friend', 'name': 'מור אליהו'},
                    embedded: true,
                  ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(preview, findsNWidgets(2));
        await tester.tap(menu.first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('בחר כמה פריטים'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('1 פריטים נבחרו'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle), findsOneWidget);
        expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
        await tester.tapAt(tester.getCenter(preview.last));
        await tester.pump();
        expect(find.text('2 פריטים נבחרו'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
        await tester.tapAt(tester.getCenter(preview.first));
        await tester.pump();
        expect(find.text('1 פריטים נבחרו'), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        await tester.tap(find.byTooltip('ביטול הבחירה'));
        await tester.pump();
        expect(find.text('1 פריטים נבחרו'), findsNothing);
        expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
        expect(
            requests.where((r) =>
                r.method == 'POST' &&
                (r.url.path.endsWith('/messages') ||
                    r.url.path.endsWith('/upload'))),
            isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      },
          () => MockClient((request) async {
                requests.add(request);
                final path = request.url.path;
                if (path.endsWith('/blocked-photo.png')) {
                  return http.Response.bytes(png, 200,
                      headers: {'content-type': 'image/png'});
                }
                Object body = {};
                if (request.method == 'GET' &&
                    path.endsWith(isGroup
                        ? '/groups/group/messages'
                        : '/messages/friend')) {
                  body = [
                    for (var i = 0; i < 2; i++)
                      {
                        'id': 'blocked-image-$i',
                        'sender_id': 'viewer',
                        'sender_name': 'אני',
                        'type': 'image',
                        'file_url': imageUrl,
                        'file_name': filename,
                        'message_status': 'rejected_scan',
                        'scan_reason': reason,
                        'forward_allowed': true,
                        'created_at': '2026-09-17T00:01:00Z',
                      }
                  ];
                } else if (path.endsWith('/groups')) {
                  body = [group];
                } else if (path.endsWith('/groups/group')) {
                  body = {
                    'members': [
                      {'id': 'viewer', 'name': 'אני', 'role': 'member'}
                    ]
                  };
                } else if (path.endsWith('/filter-settings')) {
                  body = {
                    'filter': allowed,
                    'personalFilter': allowed,
                    'requiresChoice': false,
                  };
                } else if (path.endsWith('/receiving-filter')) {
                  body = {'filter': allowed};
                }
                return http.Response(jsonEncode(body), 200, headers: {
                  'content-type': 'application/json; charset=utf-8'
                });
              }));
    });
  }
}
