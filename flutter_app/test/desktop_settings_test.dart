import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _me = {'id': 'settings-user', 'name': 'משתמש הגדרות'};
const _first = {'id': 'first-contact', 'name': 'חבר ראשון'};
const _second = {'id': 'second-contact', 'name': 'חבר שני'};
const _group = {
  'id': 'settings-group',
  'name': 'קבוצת ההגדרות',
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

Finder _inConversations(Finder finder) => find.descendant(
      of: find.byType(ConversationsScreen),
      matching: finder,
    );

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(_inConversations(find.byTooltip('תפריט')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('הגדרות').last);
  await tester.pumpAndSettle();
  expect(find.byType(SettingsScreen), findsOneWidget);
}

Future<void> _closeSettings(WidgetTester tester) async {
  await tester.tap(find.descendant(
    of: find.byType(SettingsScreen),
    matching: find.byTooltip('חזרה'),
  ));
  await tester.pumpAndSettle();
}

void _expectLeftPane(WidgetTester tester, Finder screen) {
  final pane = tester.getRect(screen);
  final conversations = tester.getRect(find.byType(ConversationsScreen));
  expect(pane.left, closeTo(0, .1));
  expect(pane.right, lessThanOrEqualTo(conversations.left));
  expect(conversations.right, closeTo(1400, .1));
  expect(find.byType(BottomNavigationBar), findsOneWidget);
}

Future<void> _withShell(
  WidgetTester tester,
  Future<void> Function() check, {
  Size size = const Size(1400, 1000),
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
      // Keep socket reconnection timers out of these navigation checks.
      tester
          .widget<ConversationsScreen>(find.byType(ConversationsScreen))
          .socket
          ?.disconnect();
      await check();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      debugDefaultTargetPlatformOverride = null;
    }
  },
      () => MockClient((request) async {
            final path = request.url.path;
            if (path.endsWith('/registration-status')) {
              return _json({'birthDateMissing': false});
            }
            if (path.endsWith('/profile')) return _json(_me);
            if (path.endsWith('/users')) return _json([_first, _second]);
            if (path.endsWith('/groups/settings-group')) {
              return _json({
                ..._group,
                'members': [
                  {..._me, 'role': 'admin'},
                  {..._first, 'role': 'member'},
                ],
              });
            }
            if (path.endsWith('/groups')) return _json([_group]);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  for (final selectedGroup in [false, true]) {
    testWidgets(
        'desktop settings and subpages stay left; back restores ${selectedGroup ? 'group' : 'contact'}',
        (tester) async {
      await _withShell(tester, () async {
        if (selectedGroup) {
          await tester.tap(find.descendant(
            of: find.byType(BottomNavigationBar),
            matching: find.text('קבוצות'),
          ));
          await tester.pumpAndSettle();
          await tester
              .tap(_inConversations(find.text(_group['name']! as String)));
        } else {
          await tester.tap(_inConversations(find.text(_first['name']!)));
        }
        await tester.pumpAndSettle();
        expect(find.byType(selectedGroup ? GroupChatScreen : ChatScreen),
            findsOneWidget);

        await _openSettings(tester);
        _expectLeftPane(tester, find.byType(SettingsScreen));
        await tester.tap(find.text('סוגי תוכן מותרים'));
        await tester.pumpAndSettle();
        final contentSettings = find.byType(ContentFilterSettingsScreen);
        expect(contentSettings, findsOneWidget);
        _expectLeftPane(tester, contentSettings);
        await tester.tap(find.descendant(
          of: contentSettings,
          matching: find.byType(BackButton),
        ));
        await tester.pumpAndSettle();
        expect(contentSettings, findsNothing);
        _expectLeftPane(tester, find.byType(SettingsScreen));

        await _closeSettings(tester);
        expect(find.byType(SettingsScreen), findsNothing);
        if (selectedGroup) {
          expect(
              tester
                  .widget<GroupChatScreen>(find.byType(GroupChatScreen))
                  .group['id'],
              _group['id']);
        } else {
          expect(
              tester
                  .widget<ChatScreen>(find.byType(ChatScreen))
                  .recipient['id'],
              _first['id']);
        }
      });
    });
  }

  testWidgets(
      'right contacts, groups and bottom navigation close desktop settings',
      (tester) async {
    await _withShell(tester, () async {
      await _openSettings(tester);
      await tester.tap(_inConversations(find.text(_second['name']!)));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(tester.widget<ChatScreen>(find.byType(ChatScreen)).recipient['id'],
          _second['id']);

      await _openSettings(tester);
      await tester.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('קבוצות'),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(_inConversations(find.text(_group['name']! as String)),
          findsOneWidget);

      await _openSettings(tester);
      await tester.tap(_inConversations(find.text(_group['name']! as String)));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(
          tester
              .widget<GroupChatScreen>(find.byType(GroupChatScreen))
              .group['id'],
          _group['id']);
    });
  });

  testWidgets(
      'mobile settings remain full-screen and back returns conversations',
      (tester) async {
    await _withShell(tester, () async {
      await _openSettings(tester);
      expect(find.byType(ConversationsScreen), findsNothing);
      expect(find.byType(BottomNavigationBar), findsNothing);
      expect(
          tester.getRect(find.byType(SettingsScreen)).width, closeTo(430, .1));
      await _closeSettings(tester);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.byType(ConversationsScreen), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsOneWidget);
    }, size: const Size(430, 1000));
  });
}
