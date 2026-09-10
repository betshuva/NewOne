import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _me = {'id': 'cleanup-owner', 'name': 'משתמש ניקוי'};
const _friend = {
  'id': 'cleanup-friend',
  'name': 'חבר לניקוי',
  'phone': '0501234567',
  'saved': true,
};
const _other = {'id': 'other-friend', 'name': 'חבר נוסף', 'saved': true};
const _group = {
  'id': 'cleanup-group',
  'name': 'קבוצת ניקוי',
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

String _targetId(String kind) =>
    (kind == 'chat' ? _friend['id'] : _group['id'])! as String;
String _targetName(String kind) =>
    (kind == 'chat' ? _friend['name'] : _group['name'])! as String;
Type _screenType(String kind) => kind == 'chat' ? ChatScreen : GroupChatScreen;
String _messageText(String kind) => 'היסטוריה קודמת של $kind';

class _Backend {
  final requests = <http.Request>[];
  final hidden = {'chat': false, 'group': false};
  final cleared = {'chat': false, 'group': false};

  Map<String, dynamic> item(String kind) => {
        ...(kind == 'chat' ? _friend : _group),
        'conversation_hidden': hidden[kind],
        if (cleared[kind] != true) ...{
          'last_message': _messageText(kind),
          'last_message_type': 'text',
          'last_message_at': '2026-09-09T12:00:00Z',
          'last_message_sender_name': _friend['name'],
        },
      };

  Iterable<http.Request> calls(String suffix) =>
      requests.where((request) => request.url.path.endsWith(suffix));

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/registration-status')) {
      return _json({'birthDateMissing': false});
    }
    expect(request.method == 'DELETE', isFalse,
        reason:
            'Conversation cleanup must not remove friendship or membership');
    expect(request.method == 'POST' && path.endsWith('/messages'), isFalse,
        reason: 'Opening and clearing a conversation must not send a message');
    for (final kind in ['chat', 'group']) {
      final target = _targetId(kind);
      if (path.endsWith('/conversations/$kind/$target/clear')) {
        expect(request.method, 'POST');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        cleared[kind] = true;
        hidden[kind] = body['deleteConversation'] == true;
        return _json({
          'ok': true,
          'hidden': hidden[kind],
          'clearedAt': '2026-09-09T13:00:00Z',
          'clearedMessages': 1,
          'media': {},
        });
      }
      if (path.endsWith('/conversations/$kind/$target/open')) {
        expect(request.method, 'POST');
        hidden[kind] = false;
        return _json({
          'ok': true,
          'hidden': false,
          'clearedAt': '2026-09-09T13:00:00Z',
        });
      }
      final messagesPath =
          kind == 'chat' ? '/messages/$target' : '/groups/$target/messages';
      if (path.endsWith(messagesPath)) {
        expect(request.method, 'GET');
        return _json(cleared[kind] == true
            ? []
            : [
                {
                  'id': '$kind-old-message',
                  'sender_id': _friend['id'],
                  'receiver_id': _me['id'],
                  'sender_name': _friend['name'],
                  'body': _messageText(kind),
                  'type': 'text',
                  'created_at': '2026-09-09T12:00:00Z',
                  'status': 'sent',
                  'is_read': true,
                }
              ]);
      }
    }
    if (path.endsWith('/profile')) return _json(_me);
    if (path.endsWith('/users')) return _json([item('chat'), _other]);
    if (path.endsWith('/users/directory') || path.endsWith('/users/search')) {
      return _json([item('chat')]);
    }
    if (path.endsWith('/groups/${_group['id']}')) {
      return _json({
        ...item('group'),
        'members': [
          {..._me, 'role': 'admin'},
          {...item('chat'), 'role': 'member'},
        ],
      });
    }
    if (path.endsWith('/groups')) return _json([item('group')]);
    if (path.endsWith('/unread')) return _json({});
    if (path.endsWith('/message-requests') ||
        path.endsWith('/messages') ||
        (request.method == 'GET' && path.contains('/messages/'))) {
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
    if (path.endsWith('/receiving-filter')) return _json({'filter': _filter});
    return _json({});
  }
}

Future<void> _withShell(
  WidgetTester tester,
  Future<void> Function(_Backend backend) check,
) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final backend = _Backend();
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
      await check(backend);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      debugDefaultTargetPlatformOverride = null;
    }
  }, () => MockClient(backend.respond));
}

Future<void> _openConversation(WidgetTester tester, String kind) async {
  await tester.tap(_inConversations(find.text(_targetName(kind))));
  await tester.pumpAndSettle();
  expect(find.byType(_screenType(kind)), findsOneWidget);
}

Future<void> _cleanup(WidgetTester tester, String kind,
    {required bool deleteConversation}) async {
  await tester.tap(find.descendant(
    of: find.byType(_screenType(kind)),
    matching:
        find.byTooltip(kind == 'chat' ? 'אפשרויות שיחה' : 'אפשרויות קבוצה'),
  ));
  await tester.pumpAndSettle();
  final menuAction =
      find.text(deleteConversation ? 'מחיקת שיחה' : 'ניקוי שיחה');
  await tester.ensureVisible(menuAction);
  await tester.tap(menuAction);
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
  expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isFalse);
  await tester.tap(find.text(deleteConversation ? 'מחק שיחה' : 'נקה שיחה'));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsNothing);
}

Future<void> _selectTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
    of: find.byType(BottomNavigationBar),
    matching: find.text(label),
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

  for (final kind in ['chat', 'group']) {
    testWidgets('desktop $kind clear retains the row and selected empty pane',
        (tester) async {
      await _withShell(tester, (backend) async {
        await _openConversation(tester, kind);
        expect(
            find.descendant(
              of: find.byType(_screenType(kind)),
              matching: find.text(_messageText(kind)),
            ),
            findsOneWidget);
        await _cleanup(tester, kind, deleteConversation: false);

        expect(find.byType(_screenType(kind)), findsOneWidget);
        expect(_inConversations(find.text(_targetName(kind))), findsOneWidget);
        expect(find.text(_messageText(kind)), findsNothing);
        final cleanup = backend
            .calls('/conversations/$kind/${_targetId(kind)}/clear')
            .single;
        expect(jsonDecode(cleanup.body),
            {'deleteConversation': false, 'deleteMedia': false});
        expect(backend.calls('/conversations/$kind/${_targetId(kind)}/open'),
            isEmpty);

        // Remounting the pane must not restore the history from local cache.
        await tester
            .tap(_inConversations(find.text(_other['name']! as String)));
        await tester.pumpAndSettle();
        await _openConversation(tester, kind);
        expect(find.text(_messageText(kind)), findsNothing);
        expect(find.byType(BottomNavigationBar), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    });

    testWidgets('desktop $kind delete hides conversation and can reopen it',
        (tester) async {
      await _withShell(tester, (backend) async {
        await _openConversation(tester, kind);
        await _cleanup(tester, kind, deleteConversation: true);

        expect(find.byType(_screenType(kind)), findsNothing);
        expect(_inConversations(find.text(_targetName(kind))), findsNothing);
        expect(_inConversations(find.text(_other['name']! as String)),
            findsOneWidget);
        expect(find.text(_messageText(kind)), findsNothing);
        final cleanup = backend
            .calls('/conversations/$kind/${_targetId(kind)}/clear')
            .single;
        expect(jsonDecode(cleanup.body),
            {'deleteConversation': true, 'deleteMedia': false});

        final conversations = tester
            .widget<ConversationsScreen>(find.byType(ConversationsScreen));
        final savedContact = conversations.users
            .singleWhere((user) => user['id'] == _friend['id']);
        expect(savedContact['saved'], isTrue);
        if (kind == 'chat') {
          expect(savedContact['conversation_hidden'], isTrue);
          await tester.tap(_inConversations(find.byIcon(Icons.search)));
          await tester.pumpAndSettle();
          final search = _inConversations(find.byType(TextField));
          await tester.enterText(search, _friend['name']! as String);
          await tester.pumpAndSettle();
          final hiddenFriend = _inConversations(find.byWidgetPredicate(
              (widget) => widget is Text && widget.data == _friend['name']));
          expect(hiddenFriend, findsOneWidget,
              reason: 'Saved hidden contacts must remain available to reopen');
          await tester.tap(hiddenFriend);
          await tester.pumpAndSettle();
          await tester.enterText(search, '');
          await tester.pumpAndSettle();
          expect(backend.calls('/contacts/save/${_friend['id']}'), isEmpty);
        } else {
          await _selectTab(tester, 'קבוצות');
          expect(_inConversations(find.text(_targetName(kind))), findsOneWidget,
              reason: 'Deleting the conversation must retain group membership');
          await _openConversation(tester, kind);
          await _selectTab(tester, 'כל השיחות');
        }

        expect(backend.calls('/conversations/$kind/${_targetId(kind)}/open'),
            hasLength(1));
        expect(_inConversations(find.text(_targetName(kind))), findsOneWidget);
        expect(find.byType(_screenType(kind)), findsOneWidget);
        expect(find.text(_messageText(kind)), findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
