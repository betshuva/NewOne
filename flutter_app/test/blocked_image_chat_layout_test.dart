import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('private filter card and its contents align right in the chat',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    const filter = {
      'text': true,
      'video': true,
      'nonHumanImages': true,
      'men': true,
      'women': false,
      'children': true,
    };

    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: ChatScreen(
            token: 'test-token',
            socket: null,
            me: {'id': 'viewer', 'name': 'אני'},
            recipient: {'id': 'friend', 'name': 'מור אליהו'},
            embedded: true,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final card = find.byKey(const ValueKey('private-contact-filter-entry'));
      expect(card, findsOneWidget);
      final cardRect = tester.getRect(card);
      expect(cardRect.right, greaterThanOrEqualTo(1170));
      expect(cardRect.left, greaterThan(600));

      final logo = find.descendant(
        of: card,
        matching: find.byWidgetPredicate((widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/guide/safe-information-ai.png'),
      );
      expect(logo, findsOneWidget);
      expect(tester.getRect(logo).right, greaterThan(cardRect.right - 40));
      expect(find.text('אני מוכן לקבל ממור אליהו'), findsOneWidget);

      final labels = find.descendant(of: card, matching: find.byType(Text));
      for (final element in labels.evaluate()) {
        if (element.findAncestorWidgetOfExactType<UserAvatar>() != null) {
          continue;
        }
        final paragraph = element.renderObject! as RenderParagraph;
        expect(
          paragraph.textAlign == TextAlign.right ||
              (paragraph.textAlign == TextAlign.start &&
                  paragraph.textDirection == TextDirection.rtl) ||
              (paragraph.textAlign == TextAlign.end &&
                  paragraph.textDirection == TextDirection.ltr),
          isTrue,
          reason: 'All private filter card labels must be aligned right',
        );
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              Object body = {};
              final path = request.url.path;
              if (request.method == 'GET' &&
                  path.endsWith('/messages/friend')) {
                body = [
                  {
                    'id': 'private-filter-entry',
                    'sender_id': 'viewer',
                    'type': 'private_filter',
                    'private_filter': filter,
                    'created_at': '2026-09-17T00:00:00Z',
                  }
                ];
              } else if (path.endsWith('/filter-settings')) {
                body = {
                  'filter': filter,
                  'personalFilter': filter,
                  'requiresChoice': false,
                };
              } else if (path.endsWith('/receiving-filter')) {
                body = {'filter': filter};
              }
              return http.Response(jsonEncode(body), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
  });

  for (final isGroup in [false, true]) {
    testWidgets(
        '${isGroup ? 'group' : 'private'} blocked image keeps details in menu and existing actions available',
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
      final details = find.byKey(const ValueKey('blocked-image-details'));
      final marker = find.byKey(const ValueKey('blocked-image-marker'));

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

        expect(preview, findsOneWidget);
        expect(marker, findsOneWidget);
        expect(find.byIcon(Icons.gpp_bad_outlined), findsOneWidget);
        expect(find.byIcon(Icons.zoom_in), findsNothing);
        expect(find.descendant(of: preview, matching: find.byType(Text)),
            findsNothing);
        expect(details, findsNothing);
        expect(find.textContaining(reason), findsNothing);
        expect(find.text(filename), findsNothing);
        expect(tester.getRect(preview).right, greaterThan(1100));
        expect(tester.getRect(menu).right,
            lessThanOrEqualTo(tester.getRect(preview).left));

        await tester.tap(menu);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('פרטי החסימה'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(details, findsOneWidget);
        expect(find.textContaining(reason), findsOneWidget);
        expect(find.text(filename), findsOneWidget);
        expect(
            find.text(isGroup ? 'נמען: קבוצת קבוצת בדיקה' : 'נמען: מור אליהו'),
            findsOneWidget);
        expect(
            find.text(isGroup
                ? 'התמונה מוצגת רק לך ולא נשלחה לשאר חברי הקבוצה'
                : 'התמונה מוצגת רק לך ולא נשלחה'),
            findsOneWidget);
        await tester.tap(find.text('סגירה'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.textContaining(reason), findsNothing);

        await tester.tap(menu);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('אפשרויות נוספות'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(find.text('העבר'), findsOneWidget);
        expect(find.text('בחר כמה פריטים'), findsOneWidget);
        expect(find.text('מחק אצלי'), findsOneWidget);
        expect(details, findsNothing);
        expect(
            requests.where((request) =>
                request.method == 'POST' &&
                (request.url.path.endsWith('/messages') ||
                    request.url.path.endsWith('/upload'))),
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
                    {
                      'id': 'blocked-image',
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
