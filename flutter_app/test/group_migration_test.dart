import 'dart:async';
import 'dart:convert';

import 'package:betshuva/group_invite_intent.dart';
import 'package:betshuva/group_invite_share.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _group = {
  'id': 'migration-group',
  'name': 'משפחת אליהו',
  'status': 'member',
  'role': 'admin',
  'member_count': 1,
  'send_permission': 'all',
};
const _me = {'id': 'migration-user', 'name': 'משתמש בדיקה'};
const _filter = {
  'text': true,
  'video': false,
  'nonHumanImages': true,
  'men': true,
  'women': false,
  'children': false,
};
final _invite = 'A' * 43;
final _newInvite = 'B' * 43;
String _link(String token) =>
    'https://betshuva.com/betshuva-app/group-invite.html?groupInvite=$token';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _withWidget(
  WidgetTester tester,
  Widget widget,
  Future<void> Function() check,
  Future<http.Response> Function(http.Request) handler, {
  Size size = const Size(1200, 2400),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: Directionality(textDirection: TextDirection.rtl, child: widget),
      ));
      await tester.pumpAndSettle();
      await check();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      debugDefaultTargetPlatformOverride = null;
    }
  }, () => MockClient(handler));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
      'migration creates a shared group without selecting people and still requires filter approval',
      (tester) async {
    final requests = <http.Request>[];
    final created = <Map<String, dynamic>>[];
    await _withWidget(
      tester,
      const CreateGroupScreen(token: 'test-token', whatsappMigration: true),
      () async {
        expect(find.text('בחירת חברים'), findsNothing);
        expect(find.byType(TextField), findsNWidgets(2));
        final phone = find.widgetWithText(
            CheckboxListTile, 'הצג את מספר הטלפון שלי למשתתפי הקבוצה');
        expect(tester.widget<CheckboxListTile>(phone).value, false);
        final name = find.byWidgetPredicate((widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'שם הקבוצה *');
        await tester.ensureVisible(name);
        await tester.enterText(name, _group['name']! as String);

        final create = find.text('צור קבוצה וקישור הזמנה');
        await tester.ensureVisible(create);
        await tester.tap(create);
        await tester.pumpAndSettle();
        expect(created, isEmpty);
        expect(find.text('יש להגדיר ולאשר את סינון הקבוצה לפני השמירה'),
            findsOneWidget);

        final approval = find.widgetWithText(
            CheckboxListTile, 'בדקתי ואני מאשר את סינון הקבוצה');
        await tester.ensureVisible(approval);
        await tester.tap(approval);
        await tester.pump();
        final video = find.widgetWithText(SwitchListTile, 'וידאו');
        await tester.ensureVisible(video);
        expect(tester.widget<SwitchListTile>(video).value, false);
        // Returning to the original settings still requires a new approval.
        await tester.tap(video);
        await tester.pump();
        await tester.tap(video);
        await tester.pump();
        expect(tester.widget<CheckboxListTile>(approval).value, false);
        await tester.ensureVisible(create);
        await tester.tap(create);
        await tester.pumpAndSettle();
        expect(created, isEmpty);
        await tester.ensureVisible(approval);
        await tester.tap(approval);
        await tester.pump();
        await tester.ensureVisible(create);
        await tester.tap(create);
        await tester.pumpAndSettle();

        expect(created, hasLength(1));
        expect(created.single['name'], _group['name']);
        expect(created.single['is_self'], false);
        expect(created.single['share_phone'], false);
        expect(created.single['content_filter'], _filter);
        expect(created.single['send_permission'], 'all');
        expect(created.single['is_broadcast'], false);
        expect(requests.where((r) => r.url.path.endsWith('/users/directory')),
            isEmpty);
        expect(requests.where((r) => r.url.path.endsWith('/members')), isEmpty);
        expect(find.byType(GroupInviteShareScreen), findsOneWidget);
        expect(find.text(_link(_invite)), findsOneWidget);
        final linkRequest = requests.singleWhere(
            (r) => r.url.path.endsWith('/migration-group/invite-link'));
        expect(linkRequest.method, 'POST');
        expect(jsonDecode(linkRequest.body), {'reset': false});
      },
      (request) async {
        requests.add(request);
        if (request.url.path.endsWith('/filter-settings')) {
          return _json(_filter);
        }
        if (request.method == 'POST' && request.url.path.endsWith('/groups')) {
          created.add(jsonDecode(request.body) as Map<String, dynamic>);
          return _json(_group);
        }
        if (request.url.path.endsWith('/invite-link')) {
          return _json({'url': _link(_invite)});
        }
        return _json({});
      },
    );
  });

  testWidgets('sharing copies a complete WhatsApp message or only the link',
      (tester) async {
    final clipboard = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    final requests = <http.Request>[];
    await _withWidget(
      tester,
      const GroupInviteShareScreen(
          api: 'https://api.test/api', token: 'test-token', group: _group),
      () async {
        final copyMessage = find.text('העתק הודעת הזמנה');
        await tester.ensureVisible(copyMessage);
        await tester.tap(copyMessage);
        await tester.pumpAndSettle();
        expect(clipboard.single, contains(_group['name']! as String));
        expect(clipboard.single, contains('אפשר להתחיל ישר מהדפדפן'));
        expect(clipboard.single, endsWith(_link(_invite)));
        final copyLink = find.text('העתק רק את הקישור');
        await tester.ensureVisible(copyLink);
        await tester.tap(copyLink);
        await tester.pumpAndSettle();
        expect(clipboard.last, _link(_invite));
        expect(requests, hasLength(1));
        expect(requests.single.headers['Authorization'], 'Bearer test-token');
        expect(requests.single.url.path,
            '/api/groups/migration-group/invite-link');
      },
      (request) async {
        requests.add(request);
        return _json({'url': _link(_invite)});
      },
      size: const Size(390, 844),
    );
  });

  testWidgets(
      'renewal failure hides the stale link and a retry loads the current link',
      (tester) async {
    final resets = <bool>[];
    await _withWidget(
      tester,
      const GroupInviteShareScreen(
          api: 'https://api.test/api', token: 'test-token', group: _group),
      () async {
        final renew = find.text('חדש קישור הזמנה');
        await tester.ensureVisible(renew);
        await tester.tap(renew);
        await tester.pumpAndSettle();
        expect(
            find.text(
                'הקישור הקודם יפסיק לפעול. חברים שכבר הצטרפו יישארו בקבוצה.'),
            findsOneWidget);
        await tester.tap(find.text('חדש קישור'));
        await tester.pumpAndSettle();
        expect(resets, [false, true]);
        expect(find.text('החיבור נותק'), findsOneWidget);
        expect(find.text(_link(_invite)), findsNothing);
        expect(find.byKey(const ValueKey('share-group-in-whatsapp')),
            findsNothing);
        await tester.tap(find.text('נסה שוב'));
        await tester.pumpAndSettle();
        expect(find.text(_link(_newInvite)), findsOneWidget);
        expect(find.byKey(const ValueKey('share-group-in-whatsapp')),
            findsOneWidget);
      },
      (request) async {
        resets.add((jsonDecode(request.body) as Map)['reset'] == true);
        if (resets.length == 2) return _json({'error': 'החיבור נותק'}, 503);
        return _json({'url': _link(resets.length == 1 ? _invite : _newInvite)});
      },
    );
  });

  testWidgets('untrusted server URL cannot be copied or shared',
      (tester) async {
    await _withWidget(
      tester,
      const GroupInviteShareScreen(
          api: 'https://api.test/api', token: 'test-token', group: _group),
      () async {
        expect(find.text('השרת לא החזיר קישור הזמנה תקין'), findsOneWidget);
        expect(find.text('העתק הודעת הזמנה'), findsNothing);
        expect(find.byKey(const ValueKey('share-group-in-whatsapp')),
            findsNothing);
      },
      (_) async => _json({'url': 'https://outside.test/?groupInvite=$_invite'}),
    );
  });

  Future<http.Response> shellResponse(http.Request request,
      Future<http.Response> Function(http.Request) join) async {
    final path = request.url.path;
    if (path.endsWith('/group-invites/$_invite/join')) return join(request);
    if (path.endsWith('/registration-status')) {
      return _json({'birthDateMissing': false});
    }
    if (path.endsWith('/profile')) return _json(_me);
    if (path.endsWith('/users') ||
        path.endsWith('/message-requests') ||
        path.endsWith('/phone-sharing/requests') ||
        path.endsWith('/messages') ||
        path.contains('/messages/')) {
      return _json([]);
    }
    if (path.endsWith('/groups/migration-group')) {
      return _json({
        ..._group,
        'members': [
          {..._me, 'role': 'admin'}
        ]
      });
    }
    if (path.endsWith('/groups')) return _json([_group]);
    if (path.endsWith('/filter-settings')) return _json(_filter);
    if (path.endsWith('/receiving-filter')) return _json({'filter': _filter});
    return _json({});
  }

  void disconnectSocket(WidgetTester tester) {
    tester
        .widget<ConversationsScreen>(
            find.byType(ConversationsScreen, skipOffstage: false))
        .socket
        ?.disconnect();
  }

  for (final width in [390.0, 1400.0]) {
    testWidgets(
        'a saved invitation opens its group once after entering the home screen at width $width',
        (tester) async {
      const store = GroupInviteIntentStore();
      await store.captureFromUri(
          Uri.parse('https://betshuva.com/?groupInvite=$_invite'));
      var joins = 0;
      await _withWidget(
        tester,
        const MainShell(token: 'test-token'),
        () async {
          disconnectSocket(tester);
          expect(joins, 1);
          expect(find.byType(GroupChatScreen), findsOneWidget);
          expect(
              tester
                  .widget<GroupChatScreen>(find.byType(GroupChatScreen))
                  .group['id'],
              _group['id']);
          expect(await store.read(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await tester.pumpWidget(
              const MaterialApp(home: MainShell(token: 'test-token')));
          await tester.pumpAndSettle();
          disconnectSocket(tester);
          expect(tester.view.physicalSize, Size(width, 1000));
          expect(joins, 1);
          expect(find.byType(GroupChatScreen), findsNothing);
        },
        (request) => shellResponse(request, (_) async {
          joins++;
          return _json({'group': _group});
        }),
        size: Size(width, 1000),
      );
    });
  }

  testWidgets(
      'temporary join failure retains the invite until a successful retry',
      (tester) async {
    const store = GroupInviteIntentStore();
    await store.captureFromUri(
        Uri.parse('https://betshuva.com/?groupInvite=$_invite'));
    var joins = 0;
    await _withWidget(
      tester,
      const MainShell(token: 'test-token'),
      () async {
        disconnectSocket(tester);
        expect(joins, 1);
        expect(await store.read(), _invite);
        expect(find.byType(GroupChatScreen), findsNothing);
        await tester.tap(find.text('נסה שוב'));
        await tester.pumpAndSettle();
        expect(joins, 2);
        expect(await store.read(), isNull);
        expect(find.byType(GroupChatScreen), findsOneWidget);
      },
      (request) => shellResponse(request, (_) async {
        joins++;
        return joins == 1 ? _json({}, 503) : _json({'group': _group});
      }),
      size: const Size(1400, 1000),
    );
  });

  testWidgets(
      'successful join opens the group while the home refresh is pending',
      (tester) async {
    const store = GroupInviteIntentStore();
    await store.captureFromUri(
        Uri.parse('https://betshuva.com/?groupInvite=$_invite'));
    final pendingUsers = Completer<http.Response>();
    var userReads = 0;
    var joins = 0;
    await _withWidget(
      tester,
      const MainShell(token: 'test-token'),
      () async {
        try {
          disconnectSocket(tester);
          expect(userReads, greaterThanOrEqualTo(2));
          expect(pendingUsers.isCompleted, false);
          expect(joins, 1);
          expect(await store.read(), isNull);
          expect(find.byType(GroupChatScreen), findsOneWidget);
          expect(
              tester
                  .widget<GroupChatScreen>(find.byType(GroupChatScreen))
                  .group['id'],
              _group['id']);
        } finally {
          pendingUsers.complete(_json([]));
          await tester.pumpAndSettle();
        }
      },
      (request) async {
        if (request.url.path.endsWith('/users')) {
          userReads++;
          if (userReads == 2) return pendingUsers.future;
          return _json([]);
        }
        return shellResponse(request, (_) async {
          joins++;
          return _json({'group': _group});
        });
      },
      size: const Size(1400, 1000),
    );
  });
}
