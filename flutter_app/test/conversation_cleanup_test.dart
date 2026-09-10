import 'dart:async';
import 'dart:convert';

import 'package:betshuva/conversation_cleanup.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _api = 'https://example.test/api';
const _token = 'cleanup-test-token';
const _me = {'id': 'cleanup-user', 'name': 'המשתמש הנוכחי'};
const _friend = {'id': 'cleanup-friend', 'name': 'חבר לבדיקה'};
const _group = {
  'id': 'cleanup-group',
  'name': 'קבוצה לבדיקה',
  'role': 'member',
  'status': 'member',
  'member_count': 2,
  'send_permission': 'all',
};
const _oldText = 'הודעה ישנה לניקוי';
const _newText = 'הודעה חדשה לאחר הניקוי';
const _clearedAt = '2026-09-09T19:00:00.000Z';
const _checkboxText = 'מחק גם קבצים מהמדיה שלי ומה־Drive';
const _filter = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true,
};

http.Response _json(Object data, [int status = 200]) => http.Response(
      jsonEncode(data),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, Object?> _success({bool hidden = false}) => {
      'ok': true,
      'hidden': hidden,
      'clearedAt': _clearedAt,
      'clearedMessages': 1,
      'media': {'deleted': 0, 'retained': 0, 'failed': 0},
    };

Map<String, Object?> _oldMessage() => {
      'id': 'old-message',
      'sender_id': _friend['id'],
      'sender_name': _friend['name'],
      'body': _oldText,
      'type': 'text',
      'created_at': '2026-09-09T18:00:00.000Z',
      'is_read': true,
    };

Finder _confirm(bool deleteConversation) => find.widgetWithText(
      FilledButton,
      deleteConversation ? 'מחק שיחה' : 'נקה שיחה',
    );

Future<void> _withDialog(
  WidgetTester tester,
  Future<void> Function(List<http.Request> requests, List<Object?> results)
      check, {
  bool deleteConversation = false,
  String kind = 'chat',
  Future<http.Response> Function(http.Request request)? response,
}) async {
  final requests = <http.Request>[];
  final results = <Object?>[];
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                results.add(await showConversationCleanupDialog(
                  context,
                  api: _api,
                  token: _token,
                  kind: kind,
                  targetId: 'test-target',
                  name: 'שיחה לבדיקה',
                  deleteConversation: deleteConversation,
                ));
              },
              child: const Text('פתח'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('פתח'));
      await tester.pumpAndSettle();
      await check(requests, results);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    }
  },
      () => MockClient((request) async {
            requests.add(request);
            return response != null
                ? await response(request)
                : _json(_success(hidden: deleteConversation));
          }));
}

class _ChatBackend {
  final requests = <http.Request>[];
  List<Map<String, Object?>> history = [_oldMessage()];
  Future<http.Response> Function()? loadHistory;
  Future<http.Response> Function(http.Request)? cleanup;

  List<http.Request> get cleanupRequests =>
      requests.where((request) => request.url.path.endsWith('/clear')).toList();

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/clear')) {
      if (cleanup != null) return cleanup!(request);
      history = [];
      final body = jsonDecode(request.body) as Map;
      return _json(_success(hidden: body['deleteConversation'] == true));
    }
    if (request.method == 'GET' &&
        (path.endsWith('/messages/${_friend['id']}') ||
            path.endsWith('/groups/${_group['id']}/messages'))) {
      return loadHistory != null ? await loadHistory!() : _json(history);
    }
    if (path.endsWith('/groups/${_group['id']}')) {
      return _json({
        ..._group,
        'members': [
          {..._me, 'role': 'member'},
          {..._friend, 'role': 'admin'},
        ],
      });
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
  }
}

Future<void> _withChat(
  WidgetTester tester,
  Future<void> Function(
          _ChatBackend backend, io.Socket socket, ValueNotifier<bool> closed)
      check, {
  bool group = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final backend = _ChatBackend();
  final closed = ValueNotifier(false);
  final socket = io.io(
    'http://localhost:1',
    io.OptionBuilder().disableAutoConnect().enableForceNew().build(),
  );
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: ValueListenableBuilder<bool>(
            valueListenable: closed,
            builder: (context, value, child) => value
                ? const Scaffold(body: Text('השיחה נסגרה'))
                : group
                    ? GroupChatScreen(
                        group: Map<String, dynamic>.from(_group),
                        me: _me,
                        token: _token,
                        socket: socket,
                        embedded: true,
                        onClose: () => closed.value = true,
                      )
                    : ChatScreen(
                        token: _token,
                        me: _me,
                        recipient: _friend,
                        socket: socket,
                        embedded: true,
                        onClose: () => closed.value = true,
                      ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(_oldText), findsOneWidget);
      await check(backend, socket, closed);
      expect(
        backend.requests.where((request) =>
            request.method == 'POST' && request.url.path.endsWith('/messages')),
        isEmpty,
        reason: 'Cleanup tests must never send chat messages',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      socket.connected = false;
      socket.dispose();
      closed.dispose();
    }
  }, () => MockClient(backend.respond));
}

Future<void> _openCleanup(
  WidgetTester tester, {
  bool group = false,
  bool deleteConversation = false,
}) async {
  await tester.tap(find.byTooltip(group ? 'אפשרויות קבוצה' : 'אפשרויות שיחה'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(deleteConversation ? 'מחיקת שיחה' : 'ניקוי שיחה'));
  await tester.pumpAndSettle();
  expect(find.byType(ConversationCleanupDialog), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });
  for (final deleting in [false, true]) {
    testWidgets(
        '${deleting ? 'delete' : 'clear'} defaults to keeping stored files',
        (tester) async {
      await _withDialog(tester, (requests, results) async {
        expect(
            tester
                .widget<CheckboxListTile>(find.byType(CheckboxListTile))
                .value,
            isFalse);
        expect(find.text(_checkboxText), findsOneWidget);
        await tester.tap(_confirm(deleting));
        await tester.pumpAndSettle();
        expect(requests, hasLength(1));
        expect(requests.single.method, 'POST');
        expect(requests.single.url.toString(),
            '$_api/conversations/chat/test-target/clear');
        expect(requests.single.headers['Authorization'], 'Bearer $_token');
        expect(jsonDecode(requests.single.body), {
          'deleteConversation': deleting,
          'deleteMedia': false,
        });
        expect(results, hasLength(1));
        expect(results.single, isNotNull);
        expect(find.byType(ConversationCleanupDialog), findsNothing);
      }, deleteConversation: deleting);
    });
  }

  testWidgets('cancel after selecting media deletion performs no request',
      (tester) async {
    await _withDialog(tester, (requests, results) async {
      await tester.tap(find.text(_checkboxText));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ביטול'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      expect(results, [null]);
    });
  });

  testWidgets('group media deletion is explicit and submits only once',
      (tester) async {
    final pending = Completer<http.Response>();
    await _withDialog(tester, (requests, results) async {
      await tester.tap(find.text(_checkboxText));
      await tester.pumpAndSettle();
      expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isTrue);
      await tester.tap(_confirm(true));
      await tester.pump();
      expect(requests, hasLength(1));
      expect(requests.single.url.path,
          '/api/conversations/group/test-target/clear');
      expect(jsonDecode(requests.single.body), {
        'deleteConversation': true,
        'deleteMedia': true,
      });
      expect(results, isEmpty);
      final buttons = tester.widgetList<ButtonStyleButton>(find.descendant(
        of: find.byType(ConversationCleanupDialog),
        matching:
            find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
      ));
      expect(buttons.where((button) => button.onPressed != null), isEmpty);
      pending.complete(_json(_success(hidden: true)));
      await tester.pumpAndSettle();
      expect(results, hasLength(1));
      expect(requests, hasLength(1));
    },
        kind: 'group',
        deleteConversation: true,
        response: (_) => pending.future);
  });

  testWidgets('server errors keep the dialog open and allow retry',
      (tester) async {
    var attempt = 0;
    await _withDialog(tester, (requests, results) async {
      await tester.tap(_confirm(false));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationCleanupDialog), findsOneWidget);
      expect(find.text('הניקוי נכשל לבדיקה'), findsOneWidget);
      expect(results, isEmpty);
      await tester.tap(_confirm(false));
      await tester.pumpAndSettle();
      expect(requests, hasLength(2));
      expect(results, hasLength(1));
    }, response: (_) async {
      attempt++;
      return attempt == 1
          ? _json({'error': 'הניקוי נכשל לבדיקה'}, 500)
          : _json(_success());
    });
  });

  for (final group in [false, true]) {
    final kind = group ? 'group' : 'chat';
    testWidgets('$kind clear removes cached history and accepts new messages',
        (tester) async {
      await _withChat(tester, (backend, socket, closed) async {
        await _openCleanup(tester, group: group);
        await tester.tap(_confirm(false));
        await tester.pumpAndSettle();
        expect(backend.cleanupRequests, hasLength(1));
        expect(
            backend.cleanupRequests.single.url.path,
            endsWith(
                '/conversations/$kind/${group ? _group['id'] : _friend['id']}/clear'));
        expect(find.text(_oldText), findsNothing);
        expect(closed.value, isFalse);
        final cacheKey = group
            ? 'cache_group_msgs_${_me['id']}_${_group['id']}'
            : 'cache_msgs_${_me['id']}_${_friend['id']}';
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(cacheKey) ?? '', isNot(contains(_oldText)));
        socket.connected = true;
        socket.onevent({
          'data': [
            group ? 'group:message' : 'chat:message',
            {
              'id': 'delayed-old-message',
              'groupId': _group['id'],
              'fromUserId': _friend['id'],
              'fromName': _friend['name'],
              'text': _oldText,
              'createdAt': '2026-09-09T18:00:00.000Z',
            },
          ],
        });
        await tester.pumpAndSettle();
        expect(find.text(_oldText), findsNothing,
            reason: 'Delayed socket delivery must respect the cleared history');
        socket.onevent({
          'data': [
            group ? 'group:message' : 'chat:message',
            {
              'id': 'new-message',
              'groupId': _group['id'],
              'fromUserId': _friend['id'],
              'fromName': _friend['name'],
              'text': _newText,
              'createdAt': '2026-09-09T19:01:00.000Z',
            },
          ],
        });
        await tester.pumpAndSettle();
        socket.connected = false;
        expect(find.text(_newText), findsOneWidget);
        expect(find.text(_oldText), findsNothing);
      }, group: group);
    });

    testWidgets('$kind delete closes the embedded conversation',
        (tester) async {
      await _withChat(tester, (backend, socket, closed) async {
        await _openCleanup(tester, group: group, deleteConversation: true);
        await tester.tap(_confirm(true));
        await tester.pumpAndSettle();
        expect(backend.cleanupRequests, hasLength(1));
        expect(jsonDecode(backend.cleanupRequests.single.body), {
          'deleteConversation': true,
          'deleteMedia': false,
        });
        expect(closed.value, isTrue);
        expect(find.text('השיחה נסגרה'), findsOneWidget);
        expect(backend.requests.where((request) => request.method == 'DELETE'),
            isEmpty,
            reason: 'Deleting a personal chat must not leave/delete its group');
      }, group: group);
    });

    testWidgets('$kind cleanup failure preserves visible and cached history',
        (tester) async {
      await _withChat(tester, (backend, socket, closed) async {
        backend.cleanup = (_) async => _json({'error': 'לא נוקה'}, 500);
        await _openCleanup(tester, group: group);
        await tester.tap(_confirm(false));
        await tester.pumpAndSettle();
        expect(find.text('לא נוקה'), findsOneWidget);
        await tester.tap(find.text('ביטול'));
        await tester.pumpAndSettle();
        expect(find.text(_oldText), findsOneWidget);
        expect(closed.value, isFalse);
        final cacheKey = group
            ? 'cache_group_msgs_${_me['id']}_${_group['id']}'
            : 'cache_msgs_${_me['id']}_${_friend['id']}';
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(cacheKey), contains(_oldText));
      }, group: group);
    });
    testWidgets('$kind history response started before clear cannot restore it',
        (tester) async {
      await _withChat(tester, (backend, socket, closed) async {
        final delayed = Completer<http.Response>();
        var pendingLoads = 0;
        backend.loadHistory = () {
          pendingLoads++;
          return delayed.future;
        };
        await tester.pump(const Duration(seconds: 4));
        expect(pendingLoads, 1);
        backend.loadHistory = null;
        await _openCleanup(tester, group: group);
        await tester.tap(_confirm(false));
        await tester.pumpAndSettle();
        expect(find.text(_oldText), findsNothing);
        delayed.complete(_json([_oldMessage()]));
        await tester.pumpAndSettle();
        expect(find.text(_oldText), findsNothing);
        final prefs = await SharedPreferences.getInstance();
        final cacheKey = group
            ? 'cache_group_msgs_${_me['id']}_${_group['id']}'
            : 'cache_msgs_${_me['id']}_${_friend['id']}';
        expect(prefs.getString(cacheKey) ?? '', isNot(contains(_oldText)));
      }, group: group);
    });

    testWidgets(
        '$kind ignores unrelated cleanup and reconciles its owner event',
        (tester) async {
      await _withChat(tester, (backend, socket, closed) async {
        final targetId = (group ? _group['id']! : _friend['id']!).toString();
        conversationChanges.add(ConversationChange(
          'another-account',
          kind,
          targetId,
          ConversationCleanupResult.fromJson(_success()),
        ));
        await tester.pumpAndSettle();
        expect(find.text(_oldText), findsOneWidget);
        socket.connected = true;
        socket.onevent({
          'data': [
            'conversation:changed',
            {..._success(), 'kind': kind, 'targetId': 'unrelated-target'},
          ],
        });
        await tester.pumpAndSettle();
        expect(find.text(_oldText), findsOneWidget);
        backend.history = [];
        socket.onevent({
          'data': [
            'conversation:changed',
            {..._success(), 'kind': kind, 'targetId': targetId},
          ],
        });
        await tester.pumpAndSettle();
        socket.connected = false;
        expect(find.text(_oldText), findsNothing);
        expect(closed.value, isFalse);
        expect(backend.cleanupRequests, isEmpty,
            reason:
                'Receiving cleanup from another session must not resubmit it');
      }, group: group);
    });

    testWidgets('$kind keeps messages received after the cleanup cutoff',
        (tester) async {
      await _withChat(tester, (backend, socket, closed) async {
        final pending = Completer<http.Response>();
        backend.cleanup = (_) => pending.future;
        await _openCleanup(tester, group: group);
        await tester.tap(_confirm(false));
        await tester.pump();
        backend.history = [
          {
            ..._oldMessage(),
            'id': 'new-while-clearing',
            'body': _newText,
            'created_at': '2026-09-09T19:01:00.000Z',
          },
        ];
        socket.connected = true;
        socket.onevent({
          'data': [
            group ? 'group:message' : 'chat:message',
            {
              'id': 'new-while-clearing',
              'groupId': _group['id'],
              'fromUserId': _friend['id'],
              'fromName': _friend['name'],
              'text': _newText,
              'createdAt': '2026-09-09T19:01:00.000Z',
            },
          ],
        });
        await tester.pump();
        pending.complete(_json(_success()));
        await tester.pumpAndSettle();
        socket.connected = false;
        expect(find.text(_oldText), findsNothing);
        expect(find.text(_newText), findsOneWidget);
        expect(closed.value, isFalse);
      }, group: group);
    });

    testWidgets('$kind disposal preserves other cleanup socket listeners',
        (tester) async {
      await _withChat(tester, (backend, socket, closed) async {
        var received = 0;
        void otherHandler(dynamic _) => received++;
        socket.on('conversation:changed', otherHandler);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(conversationChanges.hasListener, isFalse);
        socket.connected = true;
        socket.onevent({
          'data': ['conversation:changed', <String, dynamic>{}],
        });
        expect(received, 1);
        socket.off('conversation:changed', otherHandler);
        expect(socket.hasListeners('conversation:changed'), isFalse);
        socket.connected = false;
      }, group: group);
    });
  }
}
