import 'dart:convert';

import 'package:betshuva/filter_history.dart';
import 'package:betshuva/inline_custom_emoji.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _me = {'id': 'edited-filter-viewer', 'name': 'משתמש בדיקה'};
const _peer = {'id': 'edited-filter-friend', 'name': 'חבר בדיקה'};
const _group = {
  'id': 'edited-filter-group',
  'name': 'קבוצת בדיקה',
  'status': 'member',
  'role': 'member',
  'send_permission': 'all',
};
const _messageId = 'c93a97f4-d8b6-4ff1-8d43-a2d8f52d0793';
const _original = 'תוכן מקורי עם אימוג׳י 👩🏽‍🔧';
const _updated = 'הודעה מעודכנת ומותרת';
const _filter = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true,
};

class _PlainEmojiAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == 'assets/twemoji/emoji_allowlist.json') {
      return ByteData.sublistView(Uint8List.fromList(utf8.encode('[]')));
    }
    return rootBundle.load(key);
  }
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _EditedChat {
  _EditedChat({required this.group});

  final bool group;
  final requests = <http.Request>[];
  final socket = io.io(
    'http://localhost:1',
    io.OptionBuilder().disableAutoConnect().enableForceNew().build(),
  );

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' &&
        path.endsWith(group
            ? '/groups/${_group['id']}/messages'
            : '/messages/${_peer['id']}')) {
      return _json([
        {
          'id': _messageId,
          'sender_id': _peer['id'],
          'sender_name': _peer['name'],
          'recipient_id': _me['id'],
          if (group) 'group_id': _group['id'],
          'body': _original,
          'type': 'text',
          'created_at': '2026-10-13T10:00:00Z',
          'message_status': 'read',
          'is_read': true,
        }
      ]);
    }
    if (path.endsWith('/groups')) return _json([_group]);
    if (path.endsWith('/groups/${_group['id']}')) {
      return _json({
        'members': [
          {..._me, 'role': 'member'},
          {..._peer, 'role': 'member'},
        ],
        'pending_invite_ids': [],
      });
    }
    if (path.endsWith('/filter-settings') ||
        path.endsWith('/receiving-filter')) {
      return _json({
        'filter': _filter,
        'personalFilter': _filter,
        'requiresChoice': false,
      });
    }
    return _json({});
  });

  Widget app() => MaterialApp(
        home: DefaultAssetBundle(
          bundle: _PlainEmojiAssets(),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: group
                ? GroupChatScreen(
                    group: _group,
                    token: 'edited-filter-test-token',
                    me: _me,
                    socket: socket,
                    embedded: true,
                  )
                : ChatScreen(
                    token: 'edited-filter-test-token',
                    me: _me,
                    recipient: _peer,
                    socket: socket,
                    embedded: true,
                  ),
          ),
        ),
      );

  void edit(dynamic payload) {
    socket.connected = true;
    socket.onevent({
      'data': ['message:edited', payload],
    });
    socket.connected = false;
  }

  Map<String, dynamic> event(Map<String, dynamic> changes) => {
        'id': _messageId,
        if (group) 'groupId': _group['id'],
        ...changes,
      };
}

Finder _message(String body) => find.byWidgetPredicate(
    (widget) => widget is InlineEmojiText && widget.text == body);

void main() {
  for (final group in [false, true]) {
    testWidgets(
        '${group ? 'group' : 'private'} socket redacted edit clears stale Unicode and a later allowed edit restores content',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final chat = _EditedChat(group: group);
      await http.runWithClient(() async {
        try {
          await tester.pumpWidget(chat.app());
          await tester.pumpAndSettle();
          expect(_message(_original), findsOneWidget);
          expect(find.byType(FilterHiddenImage), findsNothing);

          chat.edit('malformed socket payload');
          chat.edit(chat.event({'id': 'unrelated-message', 'body': null}));
          if (group) {
            chat.edit(chat.event({
              'groupId': 'another-group',
              'body': null,
              'filter_hidden': true,
            }));
          }
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(_message(_original), findsOneWidget);

          chat.edit(chat.event({
            'body': null,
            'filter_hidden': true,
            'filter_kept': false,
            'hidden_reason': 'content_filter',
            'moderation_status': 'approved',
            'scan_reason': 'הכיתוב חסום בהגדרות הנמען',
          }));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(_message(_original), findsNothing);
          final hiddenFinder = find.byKey(const ValueKey('hidden-$_messageId'));
          expect(hiddenFinder, findsOneWidget);
          final hidden = tester.widget<FilterHiddenImage>(hiddenFinder);
          expect(hidden.hiddenReason, 'content_filter');
          expect(hidden.status, 'approved');
          expect(hidden.reason, 'הכיתוב חסום בהגדרות הנמען');

          // Removing the hiding flag without a body must not resurrect the
          // pre-edit text or its Unicode sequence from the old message map.
          chat.edit(chat.event({'filter_hidden': false, 'filter_kept': false}));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(FilterHiddenImage), findsNothing);
          expect(_message(_original), findsNothing);

          chat.edit(chat.event({
            'body': _updated,
            'filter_hidden': false,
            'filter_kept': false,
            'hidden_reason': null,
          }));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(_message(_updated), findsOneWidget);
          expect(_message(_original), findsNothing);
          expect(find.byType(FilterHiddenImage), findsNothing);
          expect(
              chat.requests.where((request) =>
                  request.method == 'POST' &&
                  request.url.path.endsWith('/messages')),
              isEmpty);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
          chat.socket.connected = false;
          chat.socket.dispose();
          chat.client.close();
        }
      }, () => chat.client);
      expect(tester.takeException(), isNull);
    });
  }
}
