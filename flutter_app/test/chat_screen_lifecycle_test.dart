import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

void main() {
  testWidgets(
      'closing an embedded chat preserves other socket listeners without '
      'sending messages', (tester) async {
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
      'chat:message',
      'messages:read',
      'messages:delivered',
      'message:delivered',
      'message:deleted',
      'message:edited',
      'scan:rejected',
      'scan:cancelled',
      'message:rejected',
      'chat:typing',
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
          child: ChatScreen(
            token: 'test-token',
            me: const {'id': 'test-user'},
            recipient: const {'id': 'test-recipient', 'name': 'חבר לבדיקה'},
            socket: socket,
            embedded: true,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(sentMessages, isEmpty);

      final indicator = find.byKey(const ValueKey('private-typing-indicator'));
      final input = find.byType(EditableText).first;
      final indicatorRect = tester.getRect(indicator);
      final inputRect = tester.getRect(input);
      final histories = find.byType(Scrollable);
      List<Rect> historyRects() => [
            for (final element in histories.evaluate())
              tester.getRect(find.byElementPredicate((e) => e == element))
          ];
      final originalHistoryRects = historyRects();
      bool isTyping() => tester.widget<SizedBox>(indicator).child != null;
      void receiveTyping() {
        socket.connected = true;
        socket.onevent({
          'data': [
            'chat:typing',
            {'fromUserId': 'test-recipient'}
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
      // Deliver local events through the socket's receive path without a
      // connection. Home and group listeners must survive the chat disposal.
      socket.connected = true;
      for (final event in events) {
        socket.onevent({
          'data': [event, <String, dynamic>{}],
        });
        socket.off(event, otherHandlers[event]);
        expect(socket.hasListeners(event), isFalse,
            reason: 'The disposed chat must remove its own $event listener');
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
              if (request.url.path.contains('/messages/')) {
                return http.Response('[]', 200);
              }
              if (request.url.path.endsWith('/filter-settings')) {
                return http.Response(
                    '{"filter":{"text":true},"requiresChoice":false}', 200);
              }
              if (request.url.path.endsWith('/receiving-filter')) {
                return http.Response('{"filter":{"text":true}}', 200);
              }
              return http.Response('{}', 200);
            }));
  });
}
