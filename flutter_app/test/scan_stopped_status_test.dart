import 'dart:convert';

import 'package:betshuva/main.dart' show ChatScreen, GroupChatScreen;
import 'package:betshuva/video_thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _id = 'scan_stopped-video';
const _url = 'https://example.test/stopped-video.mp4';
const _reason = 'שירות הסריקה אינו זמין';
const _budget = {
  'frameCount': 1,
  'limits': {'total': 6},
  'used': {'total': 4},
};
const _group = {
  'id': 'group',
  'name': 'Group',
  'status': 'member',
  'role': 'member',
  'send_permission': 'all',
};
const _allowed = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true,
};

Map<String, dynamic> _message({bool stopped = false, bool redacted = true}) => {
      'id': _id,
      'sender_id': 'viewer',
      'sender_name': 'Viewer',
      'type': 'video',
      'file_url': redacted ? null : _url,
      'file_name': redacted ? null : 'stopped-video.mp4',
      'scan_file_name': 'stopped-video.mp4',
      'filter_hidden': redacted,
      'hidden_reason': redacted ? 'moderation' : null,
      'message_status': 'pending_scan',
      'moderation_status': stopped ? 'stopped' : 'pending',
      if (stopped) 'scan_stopped': true,
      if (stopped) 'scan_reason': _reason,
      if (stopped) 'scan_budget': _budget,
      'created_at': '2026-09-25T10:00:00Z',
    };

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _Server {
  _Server(this.group, this.history);

  final bool group;
  List<Map<String, dynamic>> history;
  int historyReads = 0;
  final postedMessages = <http.Request>[];

  Future<http.Response> respond(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' &&
        path.endsWith(group ? '/groups/group/messages' : '/messages/friend')) {
      historyReads++;
      return _json(history);
    }
    if (request.method == 'POST' && path.endsWith('/messages')) {
      postedMessages.add(request);
    }
    if (path.endsWith('/groups')) return _json([_group]);
    if (path.endsWith('/groups/group')) {
      return _json({
        'members': [
          {'id': 'viewer', 'name': 'Viewer', 'role': 'member'},
        ],
      });
    }
    if (path.endsWith('/filter-settings')) {
      return _json({
        'filter': _allowed,
        'personalFilter': _allowed,
        'requiresChoice': false,
      });
    }
    if (path.endsWith('/receiving-filter')) {
      return _json({'filter': _allowed});
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

void _receiveStopped(io.Socket socket, bool group,
    {bool otherDestination = false}) {
  socket.connected = true;
  socket.onevent({
    'data': [
      'scan:cancelled',
      {
        'fileUrl': _url,
        'fileName': 'stopped-video.mp4',
        if (group) 'groupId': otherDestination ? 'other-group' : 'group',
        if (!group) 'toUserId': otherDestination ? 'other-friend' : 'friend',
        'scanStopped': true,
        'reasonCode': 'required_provider_unavailable',
        'reason': _reason,
        'budget': _budget,
      },
    ],
  });
  socket.connected = false;
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _mount(WidgetTester tester, bool group, io.Socket socket,
    {Size viewport = const Size(1400, 1100)}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: group
        ? GroupChatScreen(
            token: 'test-token',
            me: const {'id': 'viewer', 'name': 'Viewer'},
            group: {..._group},
            socket: socket,
            embedded: true,
          )
        : ChatScreen(
            token: 'test-token',
            me: const {'id': 'viewer', 'name': 'Viewer'},
            recipient: const {'id': 'friend', 'name': 'Friend'},
            socket: socket,
            embedded: true,
          ),
  ));
  await _pump(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  expect(tester.takeException(), isNull);
}

void _expectStopped() {
  expect(find.byKey(const ValueKey('scan-stopped-$_id')), findsOneWidget);
  expect(find.text('הסירטון נחסם'), findsWidgets);
  expect(find.text('stopped-video.mp4'), findsOneWidget);
  expect(find.text('הקובץ לא נשלח'), findsNothing);
  expect(find.text('התמונה מוצגת רק לך ולא נשלחה'), findsNothing);
  expect(find.textContaining(_reason), findsNothing);
  expect(find.textContaining('בוצעו'), findsNothing);
  expect(find.byKey(const ValueKey('hidden-$_id')), findsNothing);
  expect(find.byType(VideoThumbnail), findsNothing);
  expect(find.text('הקובץ ממתין לסריקה ולאישור'), findsNothing);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final group in [false, true]) {
    final scope = group ? 'group' : 'private';

    for (final viewport in [const Size(390, 844), const Size(1400, 1100)]) {
      testWidgets('$scope stopped details fit within ${viewport.width}px viewport',
          (tester) async {
        final server = _Server(group, [_message(stopped: true)]);
        await http.runWithClient(() async {
          await _mount(tester, group, _socket(), viewport: viewport);
          _expectStopped();
          final title = tester.getRect(find.text('הסירטון נחסם'));
          final filename = tester.getRect(find.text('stopped-video.mp4'));
          for (final rect in [title, filename]) {
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(viewport.width));
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(viewport.height));
          }
          expect(filename.bottom, lessThanOrEqualTo(title.top));
          expect(tester.takeException(), isNull);
          await _unmount(tester);
        }, () => MockClient(server.respond));
      });
    }

    for (final redacted in [true, false]) {
      testWidgets('$scope stopped history clears pending display, redacted=$redacted',
          (tester) async {
        final row = _message(stopped: true, redacted: redacted);
        if (!redacted) row.remove('scan_stopped');
        final server = _Server(group, [row]);
        await http.runWithClient(() async {
          await _mount(tester, group, _socket());
          _expectStopped();
          expect(server.postedMessages, isEmpty);
          await _unmount(tester);
        }, () => MockClient(server.respond));
      });
    }

    testWidgets('$scope stopped socket refreshes redacted history immediately',
        (tester) async {
      final server = _Server(group, [_message()]);
      final socket = _socket();
      await http.runWithClient(() async {
        await _mount(tester, group, socket);
        expect(server.historyReads, 1);
        expect(find.text('סורק את הווידאו'), findsOneWidget);
        server.history = [_message(stopped: true)];
        _receiveStopped(socket, group);
        await _pump(tester);
        expect(server.historyReads, 2);
        _expectStopped();
        expect(find.textContaining(_reason), findsNothing);
        expect(server.postedMessages, isEmpty);
        await _unmount(tester);
      }, () => MockClient(server.respond));
    });

    testWidgets('$scope stopped socket ignores another destination',
        (tester) async {
      final server = _Server(group, [_message()]);
      final socket = _socket();
      await http.runWithClient(() async {
        await _mount(tester, group, socket);
        _receiveStopped(socket, group, otherDestination: true);
        await _pump(tester);
        expect(server.historyReads, 1);
        expect(find.text('סורק את הווידאו'), findsOneWidget);
        expect(find.textContaining('הסריקה נעצרה'), findsNothing);
        expect(server.postedMessages, isEmpty);
        await _unmount(tester);
      }, () => MockClient(server.respond));
    });
  }
}
