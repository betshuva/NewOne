import 'package:betshuva/app_screenshot.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

void main() {
  testWidgets(
      'closing an embedded chat preserves other socket listeners and '
      'clears the screenshot destination after leaving the conversation',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final socket = io.io(
      'http://localhost:1',
      io.OptionBuilder().disableAutoConnect().enableForceNew().build(),
    );
    final previousDestination = appScreenshotDestination.value;
    const groupDestination = AppScreenshotDestination.group('test-group');
    appScreenshotDestination.value = groupDestination;
    addTearDown(() {
      socket.connected = false;
      socket.dispose();
      appScreenshotDestination.value = previousDestination;
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
      expect(appScreenshotDestination.value.kind, 'user');
      expect(appScreenshotDestination.value.id, 'test-recipient');
      expect(sentMessages, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(appScreenshotDestination.value.kind, 'user');
      expect(appScreenshotDestination.value.id, kSystemGuideId);

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
