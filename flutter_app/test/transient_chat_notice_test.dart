import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart' show ChatScreen, GroupChatScreen;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _reason = 'שירות הסינון אינו זמין. ההודעה לא נשלחה';
const _cancelled = 'הסריקה בוטלה לאחר המתנה ממושכת';
const _filterFailure = 'לא ניתן לטעון כעת את נתוני הסינון';
const _group = {
  'id': 'notice-group',
  'name': 'קבוצת בדיקה',
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

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

class _NoticeChat {
  _NoticeChat({required this.group});

  final bool group;
  bool filterComparisonFails = true;
  Completer<http.Response>? filterGate;
  final requests = <http.Request>[];
  final socket = io.io(
    'http://localhost:1',
    io.OptionBuilder().disableAutoConnect().enableForceNew().build(),
  );

  int get comparisons => requests
      .where((request) => request.url.path.endsWith('/filter-comparison'))
      .length;

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/filter-comparison')) {
      if (filterGate != null) return filterGate!.future;
      return filterComparisonFails
          ? _json({'error': 'fixture service unavailable'}, 503)
          : _json({
              'recipientFilter': _allowed,
              'personalFilter': _allowed,
              'counterpartFilterAvailable': true,
            });
    }
    if (request.method == 'GET' &&
        path.endsWith(group
            ? '/groups/${_group['id']}/messages'
            : '/messages/notice-friend')) {
      return _json([]);
    }
    if (path.endsWith('/groups')) return _json([_group]);
    if (path.endsWith('/groups/${_group['id']}')) {
      return _json({
        'members': [
          {'id': 'notice-viewer', 'name': 'אני', 'role': 'member'},
        ],
        'pending_invite_ids': [],
      });
    }
    if (path.endsWith('/filter-settings') ||
        path.endsWith('/receiving-filter')) {
      return _json({
        'filter': _allowed,
        'personalFilter': _allowed,
        'requiresChoice': false,
      });
    }
    if (path.endsWith('/filter-pin') || path.endsWith('/filter-pin/enter')) {
      return _json({'configured': false, 'unlocked': true});
    }
    return _json({});
  });

  Widget app() => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
          child: child!,
        ),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: group
              ? GroupChatScreen(
                  token: 'notice-test-token',
                  me: const {'id': 'notice-viewer', 'name': 'אני'},
                  group: _group,
                  socket: socket,
                  embedded: true,
                )
              : ChatScreen(
                  token: 'notice-test-token',
                  me: const {'id': 'notice-viewer', 'name': 'אני'},
                  recipient: const {
                    'id': 'notice-friend',
                    'name': 'חבר לבדיקה',
                  },
                  socket: socket,
                  embedded: true,
                ),
        ),
      );

  void receive(String event, String reason) {
    socket.connected = true;
    socket.onevent({
      'data': [
        event,
        {
          if (group) 'groupId': _group['id'],
          if (!group) 'toUserId': 'notice-friend',
          if (event == 'scan:cancelled') 'fileUrl': '/fixture/cancelled.png',
          'fileType': 'image',
          'reason': reason,
          if (event == 'message:rejected') 'code': 'EMOJI_SCAN_PENDING',
        },
      ],
    });
    socket.connected = false;
  }
}

Future<void> _withChat(WidgetTester tester, _NoticeChat chat,
    Future<void> Function() check) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(chat.app());
      await tester.pumpAndSettle();
      expect(
          MediaQuery.accessibleNavigationOf(
              tester.element(find.byType(Scaffold).first)),
          isTrue);
      await check();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (chat.filterGate != null && !chat.filterGate!.isCompleted) {
        chat.filterGate!.complete(_json({}, 503));
      }
      await tester.pump(const Duration(seconds: 1));
      chat.socket.connected = false;
      chat.socket.dispose();
      chat.client.close();
    }
  }, () => chat.client);
  expect(tester.takeException(), isNull);
}

Finder _notice(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

Future<void> _expectExpiry(
    WidgetTester tester, String text, int seconds) async {
  expect(_notice(text), findsOneWidget);
  await tester.pump(Duration(milliseconds: seconds * 1000 - 500));
  expect(_notice(text), findsOneWidget);
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pumpAndSettle();
  expect(find.byType(SnackBar), findsNothing);
}

void main() {
  for (final group in [false, true]) {
    final scope = group ? 'group' : 'private';

    testWidgets(
        '$scope rejected message warning expires after five seconds with accessibility enabled',
        (tester) async {
      final chat = _NoticeChat(group: group);
      await _withChat(tester, chat, () async {
        chat.receive('message:rejected', _reason);
        await tester.pumpAndSettle();
        await _expectExpiry(tester, _reason, 5);
      });
    });

    testWidgets(
        '$scope cancelled scan notice expires after four seconds with accessibility enabled',
        (tester) async {
      final chat = _NoticeChat(group: group);
      await _withChat(tester, chat, () async {
        chat.receive('scan:cancelled', _cancelled);
        await tester.pumpAndSettle();
        await _expectExpiry(tester, _cancelled, 4);
      });
    });

    testWidgets(
        '$scope repeated warnings replace the queue and close manually without a backlog',
        (tester) async {
      final chat = _NoticeChat(group: group);
      await _withChat(tester, chat, () async {
        chat.receive('message:rejected', 'התראה ראשונה');
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        chat.receive('scan:cancelled', 'התראה שנייה');
        await tester.pumpAndSettle();
        expect(_notice('התראה ראשונה'), findsNothing);
        expect(_notice('התראה שנייה'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        chat.receive('message:rejected', 'התראה אחרונה');
        await tester.pumpAndSettle();
        expect(_notice('התראה שנייה'), findsNothing);
        await _expectExpiry(tester, 'התראה אחרונה', 5);
        await tester.pump(const Duration(seconds: 6));
        expect(find.byType(SnackBar), findsNothing);

        // Several socket results may arrive before Flutter paints a frame.
        // Closing the newest warning must not expose an older queued one.
        chat.receive('message:rejected', 'התראה מהירה ישנה');
        chat.receive('scan:cancelled', 'התראה מהירה נוספת');
        chat.receive('message:rejected', 'סגירה ידנית');
        await tester.pumpAndSettle();
        expect(_notice('התראה מהירה ישנה'), findsNothing);
        expect(_notice('התראה מהירה נוספת'), findsNothing);
        expect(_notice('סגירה ידנית'), findsOneWidget);
        final close = find.descendant(
            of: find.byType(SnackBar), matching: find.byType(IconButton));
        expect(close, findsOneWidget);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);
        await tester.pump(const Duration(seconds: 6));
        expect(find.byType(SnackBar), findsNothing);
      });
    });
  }

  testWidgets(
      'private failed filter status retains a working retry and its action notice still expires',
      (tester) async {
    final chat = _NoticeChat(group: false);
    await _withChat(tester, chat, () async {
      await tester.tap(find.byIcon(Icons.shield_outlined));
      await tester.pumpAndSettle();
      expect(chat.comparisons, 1);
      expect(_notice(_filterFailure), findsOneWidget);
      final retry = find.descendant(
          of: find.byType(SnackBar), matching: find.text('נסה שוב'));
      expect(retry, findsOneWidget);
      chat.filterComparisonFails = false;
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(chat.comparisons, 2);
      expect(find.text('מצב הסינון מול חבר לבדיקה'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pumpAndSettle();

      chat.filterComparisonFails = true;
      await tester.tap(find.byIcon(Icons.shield_outlined));
      await tester.pumpAndSettle();
      expect(chat.comparisons, 3);
      await _expectExpiry(tester, _filterFailure, 4);
    });
  });

  testWidgets(
      'a filter failure completed after leaving the actual private chat shows no stale notice',
      (tester) async {
    final chat = _NoticeChat(group: false)
      ..filterGate = Completer<http.Response>();
    await _withChat(tester, chat, () async {
      await tester.tap(find.byIcon(Icons.shield_outlined));
      await tester.pump();
      expect(chat.comparisons, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      chat.filterGate!.complete(_json({}, 503));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
