import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _me = {'id': 'media-owner', 'name': 'משתמש מדיה'};
const _friend = {'id': 'media-friend', 'name': 'חבר ראשון'};
const _other = {'id': 'media-other', 'name': 'חבר שני'};
const _group = {
  'id': 'media-group',
  'name': 'קבוצת הטיולים',
  'role': 'admin',
  'status': 'member',
  'member_count': 2,
  'send_permission': 'all',
};
const _filter = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true,
};

http.Response _json(Object data) => http.Response(jsonEncode(data), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Finder get _entry =>
    find.byKey(const ValueKey('personal-media-conversation-entry'));

Finder _inConversations(Finder finder) => find.descendant(
      of: find.byType(ConversationsScreen),
      matching: finder,
    );

Future<void> _withShell(
  WidgetTester tester,
  Future<void> Function(List<http.Request> requests) check, {
  Size size = const Size(1400, 1000),
  bool empty = false,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <http.Request>[];
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: const Directionality(
          textDirection: TextDirection.rtl,
          child: MainShell(token: 'test-token'),
        ),
      ));
      await tester.pumpAndSettle();
      tester
          .widget<ConversationsScreen>(find.byType(ConversationsScreen))
          .socket
          ?.disconnect();
      await check(requests);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      debugDefaultTargetPlatformOverride = null;
    }
  },
      () => MockClient((request) async {
            requests.add(request);
            final path = request.url.path;
            if (path.endsWith('/registration-status')) {
              return _json({'birthDateMissing': false});
            }
            if (path.endsWith('/profile')) return _json(_me);
            if (path.endsWith('/users')) {
              return _json(empty ? [] : [_friend, _other]);
            }
            if (path.endsWith('/groups/media-group')) {
              return _json({
                ..._group,
                'members': [
                  {..._me, 'role': 'admin'},
                  {..._friend, 'role': 'member'},
                ],
              });
            }
            if (path.endsWith('/groups')) {
              return _json(empty ? [] : [_group]);
            }
            if (path.endsWith('/media-library')) {
              return _json({'items': [], 'total': 0, 'totalBytes': 0});
            }
            if (path.endsWith('/media-library/catalog')) {
              return _json({
                'summary': {
                  'totalCount': 0,
                  'totalBytes': 0,
                  'byType': {
                    for (final type in ['image', 'video', 'audio', 'document'])
                      type: {'count': 0, 'bytes': 0},
                  },
                  'deletableCount': 0,
                  'deletableBytes': 0,
                  'backedUpCount': 0,
                  'releasedCount': 0,
                },
                'destinations': [],
              });
            }
            if (path.endsWith('/message-requests') ||
                path.endsWith('/messages') ||
                path.contains('/messages/')) {
              return _json([]);
            }
            if (path.endsWith('/filter-settings')) {
              return _json({
                'filter': _filter,
                'personalFilter': _filter,
                'generalFilter': _filter,
                'requiresChoice': false,
              });
            }
            if (path.endsWith('/receiving-filter')) {
              return _json({'filter': _filter});
            }
            return _json({});
          }));
}

Future<void> _closeMedia(WidgetTester tester) async {
  await tester.tap(find.descendant(
    of: find.byType(PersonalMediaScreen),
    matching: find.byTooltip('חזרה'),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  testWidgets('personal media opens on the desktop left and returns to chat',
      (tester) async {
    await _withShell(tester, (requests) async {
      await tester.tap(_inConversations(find.text(_friend['name']!)));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      final callsBeforeMedia = requests.length;
      await tester.tap(_entry);
      await tester.pumpAndSettle();

      final media = find.byType(PersonalMediaScreen);
      expect(media, findsOneWidget);
      expect(tester.widget<PersonalMediaScreen>(media).embedded, isTrue);
      expect(tester.getRect(media).left, closeTo(0, .1));
      expect(
          tester.getRect(media).right,
          lessThanOrEqualTo(
              tester.getRect(find.byType(ConversationsScreen)).left));
      expect(find.byType(BottomNavigationBar), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      expect(
          tester
              .widget<ConversationsScreen>(find.byType(ConversationsScreen))
              .personalMediaSelected,
          isTrue);
      final openingCalls = requests.skip(callsBeforeMedia).toList();
      expect(openingCalls.any((r) => r.url.path.endsWith('/media-library')),
          isTrue);
      expect(openingCalls.every((r) => r.method == 'GET'), isTrue);
      expect(
          openingCalls.where((r) =>
              r.url.path.contains('/messages') ||
              r.url.path.contains('/pins/') ||
              r.url.path.contains('/conversations/') ||
              r.url.path.contains('/contacts/')),
          isEmpty);

      await _closeMedia(tester);
      expect(media, findsNothing);
      expect(tester.widget<ChatScreen>(find.byType(ChatScreen)).recipient['id'],
          _friend['id']);
    });
  });

  testWidgets('desktop contact, group and settings navigation closes media',
      (tester) async {
    await _withShell(tester, (_) async {
      await tester.tap(_entry);
      await tester.pumpAndSettle();
      await tester.tap(_inConversations(find.text(_other['name']!)));
      await tester.pumpAndSettle();
      expect(find.byType(PersonalMediaScreen), findsNothing);
      expect(tester.widget<ChatScreen>(find.byType(ChatScreen)).recipient['id'],
          _other['id']);

      await tester.tap(_entry);
      await tester.pumpAndSettle();
      await tester.tap(_inConversations(find.text(_group['name']! as String)));
      await tester.pumpAndSettle();
      expect(find.byType(PersonalMediaScreen), findsNothing);
      expect(
          tester
              .widget<GroupChatScreen>(find.byType(GroupChatScreen))
              .group['id'],
          _group['id']);

      await tester.tap(_entry);
      await tester.pumpAndSettle();
      await tester.tap(_inConversations(find.byTooltip('תפריט')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('הגדרות').last);
      await tester.pumpAndSettle();
      expect(find.byType(PersonalMediaScreen), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);
    });
  });

  testWidgets('personal media is searchable and absent from unread/groups',
      (tester) async {
    await _withShell(tester, (_) async {
      final users = tester
          .widget<ConversationsScreen>(find.byType(ConversationsScreen))
          .users;
      expect(users.any((u) => u['name'] == 'המדיה שלי'), isFalse);
      expect(_entry, findsOneWidget);
      await tester.tap(_inConversations(find.byIcon(Icons.search)));
      await tester.pumpAndSettle();
      final search = _inConversations(find.byType(TextField));
      await tester.enterText(search, 'המדיה שלי');
      await tester.pumpAndSettle();
      expect(_entry, findsOneWidget);
      expect(_inConversations(find.text(_friend['name']!)), findsNothing);
      expect(find.text('אין שיחות להצגה'), findsNothing);
      await tester.enterText(search, 'ראשון');
      await tester.pumpAndSettle();
      expect(_entry, findsNothing);
      expect(_inConversations(find.text(_friend['name']!)), findsOneWidget);
      await tester.enterText(search, '');
      await tester.pumpAndSettle();

      for (final label in ['לא נקרא', 'קבוצות']) {
        await tester.tap(find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text(label),
        ));
        await tester.pumpAndSettle();
        expect(_entry, findsNothing);
      }
      await tester.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('כל השיחות'),
      ));
      await tester.pumpAndSettle();
      expect(_entry, findsOneWidget);
    });
  });

  testWidgets('mobile personal media is full screen even without contacts',
      (tester) async {
    await _withShell(tester, (requests) async {
      expect(_entry, findsOneWidget);
      final callsBeforeMedia = requests.length;
      await tester.tap(_entry);
      await tester.pumpAndSettle();
      final media = find.byType(PersonalMediaScreen);
      expect(media, findsOneWidget);
      expect(tester.widget<PersonalMediaScreen>(media).embedded, isFalse);
      expect(tester.getRect(media).width, closeTo(430, .1));
      expect(find.byType(ConversationsScreen), findsNothing);
      expect(find.byType(BottomNavigationBar), findsNothing);
      expect(requests.skip(callsBeforeMedia).every((r) => r.method == 'GET'),
          isTrue);
      await _closeMedia(tester);
      expect(media, findsNothing);
      expect(find.byType(ConversationsScreen), findsOneWidget);
      expect(_entry, findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsOneWidget);
    }, size: const Size(430, 1000), empty: true);
  });

  testWidgets('desktop media still closes after resizing to mobile width',
      (tester) async {
    await _withShell(tester, (_) async {
      await tester.tap(_entry);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(430, 1000);
      await tester.pumpAndSettle();
      expect(find.byType(PersonalMediaScreen), findsOneWidget);
      expect(find.byType(ConversationsScreen), findsNothing);
      await _closeMedia(tester);
      expect(find.byType(PersonalMediaScreen), findsNothing);
      expect(find.byType(ConversationsScreen), findsOneWidget);
      expect(_entry, findsOneWidget);
    });
  });
}
