import 'dart:convert';

import 'package:betshuva/main.dart' show ChatScreen, GroupChatScreen;
import 'package:betshuva/video_thumbnail.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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

Map<String, dynamic> _message({bool stopped = false, bool redacted = true,
    String fileType = 'video', String? reasonCode,
    String reasonCodeField = 'scan_reason_code'}) => {
      'id': _id,
      'sender_id': 'viewer',
      'sender_name': 'Viewer',
      'type': fileType,
      'file_url': redacted ? null : fileType == 'video'
          ? _url : 'https://example.test/stopped-image.png',
      'file_name': redacted ? null : fileType == 'video'
          ? 'stopped-video.mp4' : 'stopped-image.png',
      'scan_file_name': fileType == 'video'
          ? 'stopped-video.mp4' : 'stopped-image.png',
      'filter_hidden': redacted,
      'hidden_reason': redacted ? 'moderation' : null,
      'message_status': 'pending_scan',
      'moderation_status': stopped ? 'stopped' : 'pending',
      if (stopped) 'scan_stopped': true,
      if (stopped) 'scan_reason': _reason,
      if (stopped) 'scan_budget': _budget,
      if (reasonCode != null) reasonCodeField: reasonCode,
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
    {bool otherDestination = false,
    String reasonCode = 'required_provider_unavailable',
    String reason = _reason}) {
  socket.connected = true;
  socket.onevent({
    'data': [
      'scan:cancelled',
      {
        'fileUrl': _url,
        'fileName': 'stopped-video.mp4',
        'fileType': 'video',
        if (group) 'groupId': otherDestination ? 'other-group' : 'group',
        if (!group) 'toUserId': otherDestination ? 'other-friend' : 'friend',
        'scanStopped': true,
        'reasonCode': reasonCode,
        'reason': reason,
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

    const notices = {
      'modesty_uncertain': 'לא ניתן לאשר את הקובץ: בדיקת הצניעות לא הוכרעה בוודאות',
      'provider_unavailable': 'הסריקה לא הושלמה: שירות הבדיקה אינו זמין',
      'provider_error': 'הסריקה לא הושלמה עקב תקלה בשירות הבדיקה',
      'uncertainty_review_limit': 'הסריקה נעצרה: מכסת בדיקות ההשלמה מוצתה',
      'uncertainty_review_disabled': 'לא ניתן לאשר את הקובץ: בדיקת הסינון לא הושלמה',
      'operation_outcome_unknown': 'הסריקה נעצרה: תוצאת בדיקה קודמת אינה ידועה',
      'budget_exhausted': 'הסריקה נעצרה: מכסת הבדיקות מוצתה',
      'deadline_exceeded': 'הסריקה נעצרה: זמן הבדיקה המרבי הסתיים',
      'untrusted_unknown_code': 'הסירטון נחסם',
    };
    for (final notice in notices.entries) {
      testWidgets('$scope web stopped notice uses fixed ${notice.key} explanation',
          (tester) async {
        final server = _Server(group, [_message()]);
        final socket = _socket();
        await http.runWithClient(() async {
          await _mount(tester, group, socket);
          server.history = [_message(stopped: true, reasonCode: notice.key)];
          _receiveStopped(socket, group,
              reasonCode: notice.key,
              reason: 'Gemini private provider response — הסריקה תתבצע שוב');
          await _pump(tester);
          expect(find.text(kIsWeb ? notice.value : 'הסירטון נחסם'), findsWidgets);
          expect(find.textContaining('private provider response'), findsNothing);
          expect(find.textContaining('Gemini'), findsNothing);
          expect(find.textContaining('תתבצע שוב'), findsNothing);
          expect(server.postedMessages, isEmpty);
          expect(find.byType(VideoThumbnail), findsNothing);
          await _unmount(tester);
        }, () => MockClient(server.respond));
      });
    }

    const imageNotices = {
      'modesty_uncertain': 'לא ניתן לאשר את הקובץ: בדיקת הצניעות לא הוכרעה בוודאות',
      'provider_error': 'הסריקה לא הושלמה עקב תקלה בשירות הבדיקה',
      'untrusted_unknown_code': 'הסריקה נעצרה והקובץ לא נשלח',
    };
    for (final notice in imageNotices.entries) {
      testWidgets('$scope stopped image history displays safe ${notice.key} notice',
          (tester) async {
        final row = _message(stopped: true, fileType: 'image',
            reasonCode: notice.key,
            reasonCodeField: notice.key == 'provider_error'
                ? 'reasonCode' : 'scan_reason_code');
        row['scan_reason'] = 'Gemini private provider response — הסריקה תתבצע שוב';
        final server = _Server(group, [row]);
        await http.runWithClient(() async {
          await _mount(tester, group, _socket(), viewport: const Size(390, 844));
          expect(find.byKey(const ValueKey('scan-stopped-$_id')), findsOneWidget);
          final label = find.text(kIsWeb ? notice.value : 'הסירטון נחסם');
          expect(label, findsOneWidget);
          expect(find.text('stopped-image.png'), findsOneWidget);
          for (final rect in [tester.getRect(label),
            tester.getRect(find.text('stopped-image.png'))]) {
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(390));
          }
          expect(find.textContaining('Gemini'), findsNothing);
          expect(find.textContaining('private provider response'), findsNothing);
          expect(find.textContaining('תתבצע שוב'), findsNothing);
          expect(find.text('הקובץ ממתין לסריקה ולאישור'), findsNothing);
          expect(find.text('התמונה מוצגת רק לך ולא נשלחה'), findsNothing);
          expect(find.byType(VideoThumbnail), findsNothing);
          expect(server.postedMessages, isEmpty);
          expect(tester.takeException(), isNull);
          await _unmount(tester);
        }, () => MockClient(server.respond));
      });
    }
  }
}
