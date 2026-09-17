import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _pendingId = 'scan_4913a16e-c43c-4f79-91c0-9f3bfc2741c7';
const _approvedId = '3e8a6340-e21b-40e2-89bc-fc2421577a19';
const _imageUrl = 'https://example.test/scan-approved-image.png';
const _pendingText = 'התמונה ממתינה לסריקה ולאישור';
const _hiddenText = 'התמונה מוסתרת לפי בחירת הסינון שלך';
const _restoreText = 'להחזיר את התמונה הזו';
const _allowedFilter = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true,
};

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');

Map<String, dynamic> _pendingImage() => {
      'id': _pendingId,
      'sender_id': 'viewer',
      'sender_name': 'אני',
      'type': 'image',
      'file_url': null,
      'file_name': null,
      'filter_hidden': true,
      'hidden_reason': 'moderation',
      'message_status': 'pending_scan',
      'created_at': '2026-09-17T00:01:00Z',
    };

Map<String, dynamic> _approvedImage({bool hidden = false}) => {
      'id': _approvedId,
      'sender_id': 'viewer',
      'sender_name': 'אני',
      'type': 'image',
      'file_url': hidden ? null : _imageUrl,
      'file_name': hidden ? null : 'scan-approved-image.png',
      'filter_hidden': hidden,
      if (hidden) 'hidden_reason': 'content_filter',
      'moderation_status': 'approved',
      'message_status': 'sent',
      'created_at': '2026-09-17T00:01:00Z',
    };

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _ChatServer {
  _ChatServer(this.history);

  List<Map<String, dynamic>> history;
  int historyReads = 0;
  Completer<void>? historyGate;
  final sentMessages = <http.Request>[];

  Future<http.Response> respond(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/messages/friend')) {
      historyReads++;
      await historyGate?.future;
      return _json(history);
    }
    if (request.method == 'POST' && path.endsWith('/messages')) {
      sentMessages.add(request);
    }
    if (path.endsWith('.png')) {
      return http.Response.bytes(_png, 200,
          headers: {'content-type': 'image/png'});
    }
    if (path.endsWith('/filter-settings')) {
      return _json({
        'filter': _allowedFilter,
        'personalFilter': _allowedFilter,
        'requiresChoice': false,
      });
    }
    if (path.endsWith('/receiving-filter')) {
      return _json({'filter': _allowedFilter});
    }
    return _json({});
  }
}

io.Socket _socket() {
  final socket = io.io('http://localhost:1',
      io.OptionBuilder().disableAutoConnect().enableForceNew().build());
  addTearDown(() {
    socket.connected = false;
    socket.dispose();
  });
  return socket;
}

void _receiveApproval(io.Socket socket, {String toUserId = 'friend'}) {
  // Exercise the real receive handler without establishing any connection.
  socket.connected = true;
  socket.onevent({
    'data': [
      'chat:message',
      {
        'id': _approvedId,
        'fromUserId': 'viewer',
        'toUserId': toUserId,
        'fileType': 'image',
        'fileUrl': _imageUrl,
        'fileName': 'scan-approved-image.png',
        'createdAt': '2026-09-17T00:01:00Z',
      },
    ],
  });
  socket.connected = false;
}

Future<void> _mount(WidgetTester tester, io.Socket socket) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(MaterialApp(
    home: ChatScreen(
      token: 'test-token',
      me: const {'id': 'viewer', 'name': 'אני'},
      recipient: const {'id': 'friend', 'name': 'חבר'},
      socket: socket,
      embedded: true,
    ),
  ));
  await _pumpRefresh(tester);
}

Future<void> _pumpRefresh(WidgetTester tester) async {
  // Stay well below the four-second fallback poll: socket delivery must refresh
  // the authoritative history on its own, even for a redacted synthetic row.
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  expect(tester.takeException(), isNull);
}

Finder _approvedImageWidget() =>
    find.byKey(const ValueKey('chat-image-$_approvedId-$_imageUrl'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('own approval replaces redacted pending scan before history poll',
      (tester) async {
    final server = _ChatServer([_pendingImage()]);
    final socket = _socket();
    await http.runWithClient(() async {
      await _mount(tester, socket);
      expect(server.historyReads, 1);
      expect(find.text(_pendingText), findsOneWidget);
      expect(find.text(_hiddenText), findsNothing);
      expect(find.text(_restoreText), findsNothing);
      expect(_approvedImageWidget(), findsNothing);

      // The approved message has a new UUID, and the pending row had neither
      // URL nor filename. Only the socket destination identifies this chat.
      server.history = [_approvedImage()];
      _receiveApproval(socket);
      await _pumpRefresh(tester);

      expect(server.historyReads, 2);
      expect(_approvedImageWidget(), findsOneWidget);
      expect(find.byKey(const ValueKey('hidden-$_pendingId')), findsNothing);
      expect(find.text(_pendingText), findsNothing);
      expect(find.text(_hiddenText), findsNothing);
      expect(server.sentMessages, isEmpty);

      // Duplicate delivery must not create an extra bubble or resend content.
      _receiveApproval(socket);
      await _pumpRefresh(tester);
      expect(_approvedImageWidget(), findsOneWidget);
      expect(find.text(_pendingText), findsNothing);
      expect(server.sentMessages, isEmpty);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets('own approval for another destination does not refresh this chat',
      (tester) async {
    final server = _ChatServer([_pendingImage()]);
    final socket = _socket();
    await http.runWithClient(() async {
      await _mount(tester, socket);
      expect(server.historyReads, 1);
      _receiveApproval(socket, toUserId: 'another-friend');
      await _pumpRefresh(tester);

      expect(server.historyReads, 1);
      expect(find.text(_pendingText), findsOneWidget);
      expect(_approvedImageWidget(), findsNothing);
      expect(server.sentMessages, isEmpty);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets('approval event preserves authoritative content filter hiding',
      (tester) async {
    final server = _ChatServer([_approvedImage(hidden: true)]);
    final socket = _socket();
    await http.runWithClient(() async {
      await _mount(tester, socket);
      expect(find.text(_hiddenText), findsOneWidget);
      expect(find.text(_restoreText), findsOneWidget);
      expect(_approvedImageWidget(), findsNothing);

      final gate = Completer<void>();
      server.historyGate = gate;
      _receiveApproval(socket);
      await _pumpRefresh(tester);
      expect(server.historyReads, 2);
      expect(_approvedImageWidget(), findsNothing,
          reason: 'The socket URL cannot bypass server visibility');

      gate.complete();
      await _pumpRefresh(tester);
      expect(find.text(_hiddenText), findsOneWidget);
      expect(find.text(_restoreText), findsOneWidget);
      expect(find.text(_pendingText), findsNothing);
      expect(_approvedImageWidget(), findsNothing);
      expect(server.sentMessages, isEmpty);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });
}
