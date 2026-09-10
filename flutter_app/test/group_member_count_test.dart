import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _groupId = 'count-test-group';
const _groupName = 'קבוצה לבדיקת מספר חברים';
const _me = {'id': 'current-user', 'name': 'המשתמש הנוכחי', 'role': 'admin'};
const _member = {'id': 'second-member', 'name': 'חבר שני', 'role': 'member'};
const _joinedMember = {
  'id': 'joined-member',
  'name': 'חבר שהצטרף',
  'role': 'member',
};
const _filter = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true,
};

http.Response _json(Object data) => http.Response(
      jsonEncode(data),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

class _GroupServer {
  List<Map<String, dynamic>> members = [_me, _member];
  bool stringCount = false;
  Completer<void>? detailGate;
  final requests = <http.Request>[];

  Map<String, dynamic> get group => {
        'id': _groupId,
        'name': _groupName,
        'role': 'admin',
        'status': 'member',
        'member_count': stringCount ? '${members.length}' : members.length,
        'send_permission': 'all',
      };

  int get detailLoads => requests
      .where((request) => request.url.path.endsWith('/groups/$_groupId'))
      .length;

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/registration-status')) {
      return _json({'birthDateMissing': false});
    }
    if (path.endsWith('/profile')) return _json(_me);
    if (path.endsWith('/users') || path.endsWith('/message-requests')) {
      return _json([]);
    }
    if (path.endsWith('/groups/$_groupId')) {
      await detailGate?.future;
      return _json({...group, 'members': members});
    }
    if (path.endsWith('/groups')) return _json([group]);
    if (path.endsWith('/messages') || path.contains('/messages/')) {
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
    if (path.endsWith('/receiving-filter')) {
      return _json({'filter': _filter});
    }
    return _json({});
  }
}

Future<void> _withGroup(
  WidgetTester tester,
  _GroupServer server,
  Future<void> Function() check, {
  bool mainShell = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  if (mainShell) {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: mainShell
              ? const MainShell(token: 'test-token')
              : GroupChatScreen(
                  group: server.group,
                  me: _me,
                  token: 'test-token',
                  socket: null,
                  embedded: true,
                ),
        ),
      ));
      await tester.pumpAndSettle();
      if (mainShell) {
        // No socket connection or message delivery is involved in these tests.
        tester
            .widget<ConversationsScreen>(find.byType(ConversationsScreen))
            .socket
            ?.disconnect();
      }
      await check();
      expect(
        server.requests.where((request) => request.method != 'GET'),
        everyElement(predicate<http.Request>((request) =>
            request.method == 'PUT' &&
            request.url.path.endsWith('/groups/$_groupId/read'))),
        reason: 'Only the mocked mark-as-read operation may write.',
      );
    } finally {
      if (server.detailGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      if (mainShell) debugDefaultTargetPlatformOverride = null;
    }
  }, () => MockClient(server.respond));
}

Finder _countWithin(Type screen, int count) => find.descendant(
      of: find.byType(screen, skipOffstage: false),
      matching: find.text('$count חברים', skipOffstage: false),
    );

Finder _avatarInSettings(String name) => find.descendant(
      of: find.byType(ContentFilterSettingsScreen, skipOffstage: false),
      matching: find.byWidgetPredicate(
        (widget) => widget is UserAvatar && widget.name == name,
        skipOffstage: false,
      ),
    );

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byTooltip('פרטי הקבוצה'));
  await tester.pumpAndSettle();
  expect(find.byType(ContentFilterSettingsScreen), findsOneWidget);
}

Future<void> _openManagement(WidgetTester tester) async {
  await tester.tap(find.text('ניהול'));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  testWidgets('settings waits for the initial members response before opening',
      (tester) async {
    final server = _GroupServer()..detailGate = Completer<void>();
    await _withGroup(tester, server, () async {
      expect(_countWithin(GroupChatScreen, 2), findsOneWidget);
      await tester.tap(find.byTooltip('פרטי הקבוצה'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(ContentFilterSettingsScreen), findsNothing);
      expect(find.text('0 חברים'), findsNothing);
      expect(server.detailLoads, 1,
          reason: 'Opening settings reuses the in-flight member request.');

      server.detailGate!.complete();
      await tester.pumpAndSettle();
      expect(_countWithin(GroupChatScreen, 2), findsOneWidget);
      expect(_countWithin(ContentFilterSettingsScreen, 2), findsOneWidget);
      expect(_avatarInSettings(_member['name']!), findsOneWidget);
    });
  });

  testWidgets('missed join refreshes open settings count and avatars',
      (tester) async {
    final server = _GroupServer();
    await _withGroup(tester, server, () async {
      await _openSettings(tester);
      expect(_countWithin(ContentFilterSettingsScreen, 2), findsOneWidget);
      expect(_avatarInSettings(_joinedMember['name']!), findsNothing);

      server.members = [_me, _member, _joinedMember];
      server.stringCount = true;
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      expect(_countWithin(GroupChatScreen, 3), findsOneWidget);
      expect(_countWithin(ContentFilterSettingsScreen, 3), findsOneWidget);
      expect(_countWithin(ContentFilterSettingsScreen, 2), findsNothing);
      expect(_avatarInSettings(_joinedMember['name']!), findsOneWidget);
    });
  });

  testWidgets('settings shows every active member beyond the first six',
      (tester) async {
    final server = _GroupServer()
      ..members = [
        _me,
        for (var index = 1; index <= 7; index++)
          {
            'id': 'member-$index',
            'name': 'חבר מספר $index',
            'role': 'member',
          },
      ];
    await _withGroup(tester, server, () async {
      await _openSettings(tester);
      expect(_countWithin(GroupChatScreen, 8), findsOneWidget);
      expect(_countWithin(ContentFilterSettingsScreen, 8), findsOneWidget);
      final lastAvatar = _avatarInSettings('חבר מספר 7');
      await tester.scrollUntilVisible(
        lastAvatar,
        100,
        scrollable: find.descendant(
          of: find.byType(ContentFilterSettingsScreen),
          matching: find.byWidgetPredicate((widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.left),
        ),
      );
      expect(lastAvatar, findsOneWidget);
      expect(_countWithin(ContentFilterSettingsScreen, 8), findsOneWidget);
      await _openManagement(tester);
      expect(find.text('חברים בקבוצה (8)'), findsOneWidget);
    });
  });

  testWidgets('missed removal updates open management, settings and group',
      (tester) async {
    final server = _GroupServer()..members = [_me, _member, _joinedMember];
    await _withGroup(tester, server, () async {
      await _openSettings(tester);
      await _openManagement(tester);
      expect(find.text('חברים בקבוצה (3)'), findsOneWidget);

      server.members = [_me, _member];
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      expect(find.text('חברים בקבוצה (2)'), findsOneWidget);
      expect(find.text('חברים בקבוצה (3)'), findsNothing);
      expect(find.text(_joinedMember['name']!), findsNothing);
      expect(_countWithin(GroupChatScreen, 2), findsOneWidget);
      expect(_countWithin(ContentFilterSettingsScreen, 2), findsOneWidget);
      expect(_avatarInSettings(_joinedMember['name']!), findsNothing);
      await tester.tap(find.text('סגור'));
      await tester.pumpAndSettle();
      expect(_countWithin(ContentFilterSettingsScreen, 2), findsOneWidget);
    });
  });

  testWidgets('opening management refreshes members before the next poll',
      (tester) async {
    final server = _GroupServer();
    await _withGroup(tester, server, () async {
      await _openSettings(tester);
      server.members = [_me, _member, _joinedMember];
      await _openManagement(tester);

      expect(find.text('חברים בקבוצה (3)'), findsOneWidget);
      expect(find.text(_joinedMember['name']!), findsOneWidget);
      expect(_countWithin(GroupChatScreen, 3), findsOneWidget);
      expect(_countWithin(ContentFilterSettingsScreen, 3), findsOneWidget);
    });
  });

  testWidgets('desktop conversation row stays in sync with the opened group',
      (tester) async {
    final server = _GroupServer();
    await _withGroup(tester, server, () async {
      expect(_countWithin(ConversationsScreen, 2), findsOneWidget);
      await tester.tap(find.text(_groupName));
      await tester.pumpAndSettle();
      expect(find.byType(GroupChatScreen), findsOneWidget);
      await _openSettings(tester);

      server.members = [_me, _member, _joinedMember];
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      expect(_countWithin(ConversationsScreen, 3), findsOneWidget);
      expect(_countWithin(GroupChatScreen, 3), findsOneWidget);
      expect(_countWithin(ContentFilterSettingsScreen, 3), findsOneWidget);
    }, mainShell: true);
  });

  testWidgets('visible group rows refresh while no group chat is open',
      (tester) async {
    final server = _GroupServer();
    await _withGroup(tester, server, () async {
      expect(find.byType(GroupChatScreen), findsNothing);
      expect(_countWithin(ConversationsScreen, 2), findsOneWidget);
      server.members = [_me, _member, _joinedMember];
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(_countWithin(ConversationsScreen, 3), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('קבוצות'),
      ));
      await tester.pumpAndSettle();
      server.members = [_me, _member];
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(_countWithin(ConversationsScreen, 2), findsOneWidget);
      expect(find.byType(GroupChatScreen), findsNothing);
    }, mainShell: true);
  });
}
