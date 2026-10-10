import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

void main() {
  testWidgets('leaving the groups tab preserves other socket listeners',
      (tester) async {
    final socket = io.io(
      'http://localhost:1',
      io.OptionBuilder().disableAutoConnect().enableForceNew().build(),
    );
    addTearDown(() {
      socket.connected = false;
      socket.dispose();
    });

    const events = ['group:message', 'group:invited', 'group:deleted'];
    final received = <String>[];
    final otherHandlers = <String, void Function(dynamic)>{};
    for (final event in events) {
      otherHandlers[event] = (_) => received.add(event);
      socket.on(event, otherHandlers[event]!);
    }
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: GroupsScreen(
            token: 'test-token',
            me: const {'id': 'test-user'},
            socket: socket,
            groupTypingNames: const {},
            currentMainNavigationIndex: 2,
            onMainNavigationSelected: (_) {},
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(GroupsScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      socket.connected = true;
      for (final event in events) {
        socket.onevent({
          'data': [event, <String, dynamic>{}],
        });
        socket.off(event, otherHandlers[event]);
        expect(socket.hasListeners(event), isFalse,
            reason: 'The groups tab must remove its own $event listener');
      }
      socket.connected = false;
      expect(received, orderedEquals(events));
      expect(tester.takeException(), isNull);
    }, () => MockClient((_) async => http.Response('[]', 200)));
  });

  testWidgets(
      'closing a group preserves Home and private chat socket listeners',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final socket = io.io(
      'http://localhost:1',
      io.OptionBuilder().disableAutoConnect().enableForceNew().build(),
    );
    addTearDown(() {
      socket.connected = false;
      socket.dispose();
    });

    const events = [
      'group:message',
      'group:viewed',
      'group:member_joined',
      'group:deleted',
      'message:edited',
      'message:deleted',
      'scan:rejected',
      'scan:cancelled',
      'education:updated',
      'message:rejected',
      'group:typing',
    ];
    final received = <String>[];
    final otherHandlers = <String, void Function(dynamic)>{};
    for (final event in events) {
      otherHandlers[event] = (_) => received.add(event);
      socket.on(event, otherHandlers[event]!);
    }
    final sentMessages = <http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: GroupChatScreen(
            token: 'test-token',
            me: const {'id': 'test-user'},
            group: {'id': 'test-group', 'name': 'קבוצה לבדיקה'},
            socket: socket,
            embedded: true,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(GroupChatScreen), findsOneWidget);
      expect(sentMessages, isEmpty);

      final indicator = find.byKey(const ValueKey('group-typing-indicator'));
      final input = find.byType(EditableText).first;
      final indicatorRect = tester.getRect(indicator);
      final inputRect = tester.getRect(input);
      final histories = find.byType(Scrollable);
      List<Rect> historyRects() => [
            for (final element in histories.evaluate())
              tester.getRect(find.byElementPredicate((e) => e == element))
          ];
      final originalHistoryRects = historyRects();
      bool isTyping() => find
          .descendant(of: indicator, matching: find.text('חבר מקליד...'))
          .evaluate()
          .isNotEmpty;
      void receiveTyping() {
        socket.connected = true;
        socket.onevent({
          'data': [
            'group:typing',
            {'groupId': 'test-group', 'fromName': 'חבר'}
          ]
        });
        socket.connected = false;
      }

      void expectStableLayout() {
        expect(tester.getRect(indicator), indicatorRect);
        expect(tester.getRect(input), inputRect);
        expect(historyRects(), originalHistoryRects);
      }

      expect(isTyping(), isFalse);
      receiveTyping();
      await tester.pump();
      expect(isTyping(), isTrue);
      expectStableLayout();
      await tester.pump(const Duration(seconds: 2));
      receiveTyping();
      await tester.pump(const Duration(milliseconds: 1200));
      // The first event's timeout must not hide ongoing typing.
      expect(isTyping(), isTrue);
      expectStableLayout();
      await tester.pump(const Duration(milliseconds: 1900));
      expect(isTyping(), isFalse);
      expectStableLayout();
      // Closing with an active typing timeout must clean it up.
      receiveTyping();
      await tester.pump();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));

      received.clear();
      // Inject local receive events without opening a network connection.
      // Removing the group must leave every other screen's callback intact.
      socket.connected = true;
      for (final event in events) {
        socket.onevent({
          'data': [event, <String, dynamic>{}],
        });
        socket.off(event, otherHandlers[event]);
        expect(socket.hasListeners(event), isFalse,
            reason: 'The disposed group must remove its own $event listener');
      }
      socket.connected = false;
      expect(received, orderedEquals(events));
      expect(sentMessages, isEmpty);
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              if (request.method == 'POST' &&
                  request.url.path.endsWith('/messages')) {
                sentMessages.add(request);
              }
              if (request.url.path.endsWith('/messages') ||
                  request.url.path.endsWith('/groups')) {
                return http.Response('[]', 200);
              }
              if (request.url.path.endsWith('/groups/test-group')) {
                return http.Response('{"members":[]}', 200);
              }
              if (request.url.path.endsWith('/filter-settings')) {
                return http.Response('{"filter":{"text":true}}', 200);
              }
              return http.Response('{}', 200);
            }));
  });
}
