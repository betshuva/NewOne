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

const _groupId = 'test-group';
const _me = {'id': 'current-user', 'name': 'המשתמש הנוכחי'};
const _member = {'id': 'other-member', 'name': 'חבר לבדיקה', 'role': 'member'};
const _memberPhotoUrl = 'https://example.test/group-member-avatar.png';
const _filter = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true,
};

Map<String, dynamic> _group() => {
      'id': _groupId,
      'name': 'קבוצה לבדיקה',
      'role': 'admin',
      'status': 'member',
      'member_count': 2,
      'send_permission': 'all',
    };

http.Response _json(Object data, [int status = 200]) => http.Response(
      jsonEncode(data),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

bool _isSave(http.Request request) =>
    request.method == 'POST' &&
    request.url.path.endsWith('/contacts/save/${_member['id']}');

bool _isPrivateLoad(http.Request request) =>
    request.method == 'GET' &&
    request.url.path.endsWith('/messages/${_member['id']}');

Finder _input(String hint) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.hintText == hint,
    );

Finder _memberName() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(_member['name']!),
    );

Finder _overviewAvatar(String name) => find.descendant(
      of: find.byType(ContentFilterSettingsScreen),
      matching: find.byWidgetPredicate(
        (widget) => widget is UserAvatar && widget.name == name,
      ),
    );

Future<void> _tapOverviewAvatar(WidgetTester tester, String name) =>
    tester.tapAt(tester.getCenter(_overviewAvatar(name)));

Future<void> _openGroupDetails(WidgetTester tester) async {
  await tester.tap(find.byTooltip('פרטי הקבוצה'));
  await tester.pumpAndSettle();
  expect(find.byType(ContentFilterSettingsScreen), findsOneWidget);
}

Future<void> _openMembers(WidgetTester tester) async {
  await _openGroupDetails(tester);
  await tester.tap(find.text('ניהול'));
  await tester.pumpAndSettle();
  expect(find.text('חברים בקבוצה (2)'), findsOneWidget);
}

Future<void> _withGroup(
  WidgetTester tester,
  Future<void> Function(List<http.Request> requests) check, {
  Size screenSize = const Size(1400, 1000),
  bool mainShell = false,
  String groupRole = 'admin',
  bool memberPhoto = false,
  Future<http.Response> Function(http.Request request)? saveContact,
}) async {
  if (mainShell) {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = screenSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final member = {
    ..._member,
    if (memberPhoto) 'profile_pic_url': _memberPhotoUrl,
  };
  if (memberPhoto) {
    // Prime the image cache so the real photo-avatar gesture is tested without
    // making a network request for the fixture image.
    final image = await tester.runAsync(() => createTestImage());
    PaintingBinding.instance.imageCache.putIfAbsent(
      const NetworkImage(_memberPhotoUrl),
      () => OneFrameImageStreamCompleter(
          SynchronousFuture(ImageInfo(image: image!))),
    );
  }
  final requests = <http.Request>[];
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: mainShell
              ? const MainShell(token: 'test-token')
              : GroupChatScreen(
                  group: {..._group(), 'role': groupRole},
                  me: _me,
                  token: 'test-token',
                  socket: null,
                  embedded: true,
                ),
        ),
      ));
      await tester.pumpAndSettle();
      if (mainShell) {
        // Widget tests block network requests; disconnect the shell's socket as
        // soon as it is built so reconnection timers cannot affect navigation.
        tester
            .widget<ConversationsScreen>(find.byType(ConversationsScreen))
            .socket
            ?.disconnect();
      }
      await check(requests);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      if (mainShell) debugDefaultTargetPlatformOverride = null;
    }
  },
      () => MockClient((request) async {
            requests.add(request);
            if (_isSave(request)) {
              return saveContact != null
                  ? await saveContact(request)
                  : _json({'ok': true});
            }
            final path = request.url.path;
            if (path.endsWith('/registration-status')) {
              return _json({'birthDateMissing': false});
            }
            Object response = {};
            if (path.endsWith('/profile')) {
              response = _me;
            } else if (path.endsWith('/users')) {
              response = requests.any(_isSave) ? [member] : [];
            } else if (path.endsWith('/message-requests')) {
              response = [];
            } else if (path.endsWith('/groups/$_groupId')) {
              response = {
                ..._group(),
                'role': groupRole,
                'members': [
                  {..._me, 'role': groupRole},
                  member,
                ],
              };
            } else if (path.endsWith('/groups')) {
              response = [
                {..._group(), 'role': groupRole}
              ];
            } else if (path.endsWith('/messages') ||
                path.contains('/messages/')) {
              response = [];
            } else if (path.endsWith('/filter-settings')) {
              response = {
                'filter': _filter,
                'personalFilter': _filter,
                'generalFilter': _filter,
                'requiresChoice': false,
              };
            } else if (path.endsWith('/receiving-filter')) {
              response = {'filter': _filter};
            }
            return _json(response);
          }));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });
  for (final tapAvatar in [false, true]) {
    testWidgets(
        'one tap on member ${tapAvatar ? 'avatar' : 'name'} saves friend before opening normal chat',
        (tester) async {
      await _withGroup(tester, (requests) async {
        final groupState = tester.state(find.byType(GroupChatScreen));
        await tester.enterText(_input('הודעה לקבוצה...'), 'טיוטה לקבוצה');
        await _openMembers(tester);
        final memberTile = find.ancestor(
          of: _memberName(),
          matching: find.byType(ListTile),
        );
        if (tapAvatar) {
          await tester.tapAt(tester.getCenter(find.descendant(
            of: memberTile,
            matching: find.byType(UserAvatar),
          )));
        } else {
          await tester.tap(_memberName());
        }
        await tester.pumpAndSettle();

        final chatFinder = find.byType(ChatScreen);
        expect(chatFinder, findsOneWidget);
        expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
        expect(find.byType(ContentFilterSettingsScreen, skipOffstage: false),
            findsNothing);
        final chat = tester.widget<ChatScreen>(chatFinder);
        expect(chat.recipient['id'], _member['id']);
        expect(chat.recipient['name'], _member['name']);
        expect(chat.embedded, isFalse);
        expect(chat.autoSendInitialMessage, isFalse);
        final saved = requests.where(_isSave).toList();
        expect(saved, hasLength(1));
        expect(saved.single.headers['Authorization'], 'Bearer test-token');
        expect(jsonDecode(saved.single.body), {'source': 'in_app'});
        expect(requests.where(_isPrivateLoad), isNotEmpty);
        expect(requests.indexWhere(_isSave),
            lessThan(requests.indexWhere(_isPrivateLoad)));
        expect(requests.where((request) => request.method == 'POST'), saved);

        await tester.tap(find.descendant(
          of: chatFinder,
          matching: find.byType(BackButton),
        ));
        await tester.pumpAndSettle();
        expect(find.byType(ChatScreen), findsNothing);
        expect(find.byType(ContentFilterSettingsScreen), findsNothing);
        expect(tester.state(find.byType(GroupChatScreen)), same(groupState));
        expect(
            tester
                .widget<TextField>(_input('הודעה לקבוצה...'))
                .controller!
                .text,
            'טיוטה לקבוצה');
      }, memberPhoto: tapAvatar);
    });
  }

  testWidgets('desktop shell refreshes friends and opens its usual chat pane',
      (tester) async {
    await _withGroup(tester, (requests) async {
      expect(find.byType(GroupChatScreen), findsNothing);
      expect(
          tester
              .widget<ConversationsScreen>(find.byType(ConversationsScreen))
              .users,
          isEmpty);
      await tester.tap(find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('קבוצות'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('קבוצה לבדיקה'));
      await tester.pumpAndSettle();
      expect(find.byType(GroupChatScreen), findsOneWidget);
      await _openMembers(tester);
      await tester.tap(_memberName());
      await tester.pumpAndSettle();

      final chatFinder = find.byType(ChatScreen);
      for (var attempt = 0;
          attempt < 10 && !tester.any(chatFinder);
          attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(chatFinder, findsOneWidget);
      final chat = tester.widget<ChatScreen>(chatFinder);
      expect(chat.embedded, isTrue);
      expect(chat.autoSendInitialMessage, isFalse);
      expect(chat.recipient['id'], _member['id']);
      final conversations =
          tester.widget<ConversationsScreen>(find.byType(ConversationsScreen));
      expect(conversations.selectedUserId, _member['id']);
      expect(conversations.users.map((user) => user['id']),
          contains(_member['id']));
      expect(
          find.descendant(
              of: find.byType(ConversationsScreen),
              matching: find.text(_member['name']!)),
          findsOneWidget);
      expect(
          tester
              .widget<BottomNavigationBar>(find.byType(BottomNavigationBar))
              .currentIndex,
          0);
      expect(find.byType(GroupChatScreen, skipOffstage: false), findsNothing);
      expect(find.byType(ContentFilterSettingsScreen, skipOffstage: false),
          findsNothing);
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
      expect(tester.getTopLeft(chatFinder).dx, closeTo(0, .1));
      expect(tester.getSize(chatFinder).width, closeTo(1400 - 411, .1));
      expect(Navigator.of(tester.element(chatFinder)).canPop(), isFalse);
      final saveIndex = requests.indexWhere(_isSave);
      final refreshIndex = requests.indexWhere(
          (request) => request.url.path.endsWith('/users'), saveIndex + 1);
      expect(saveIndex, greaterThanOrEqualTo(0));
      expect(refreshIndex, greaterThan(saveIndex));
      expect(requests.indexWhere(_isPrivateLoad), greaterThan(refreshIndex));
      expect(requests.where((request) => request.method == 'POST'),
          requests.where(_isSave));
    }, mainShell: true);
  });

  testWidgets('self selection and cancelling members do not save or open chat',
      (tester) async {
    await _withGroup(tester, (requests) async {
      await _openMembers(tester);
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(_me['name']!),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('סגור'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(ContentFilterSettingsScreen), findsOneWidget);
      expect(requests.where((request) => request.method == 'POST'), isEmpty);
      expect(requests.where(_isPrivateLoad), isEmpty);
    });
  });

  testWidgets('failed friend save keeps members open and allows retry',
      (tester) async {
    var attempts = 0;
    await _withGroup(tester, (requests) async {
      await _openMembers(tester);
      await tester.tap(_memberName());
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(requests.where(_isPrivateLoad), isEmpty);
      expect(find.text('שמירת החבר נכשלה בבדיקה'), findsOneWidget);
      await tester.tap(_memberName());
      await tester.pumpAndSettle();
      expect(requests.where(_isSave), hasLength(2));
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
      expect(find.byType(ContentFilterSettingsScreen, skipOffstage: false),
          findsNothing);
    }, saveContact: (_) async {
      attempts++;
      return attempts == 1
          ? _json({'error': 'שמירת החבר נכשלה בבדיקה'}, 503)
          : _json({'ok': true});
    });
  });

  testWidgets('repeated member taps while saving make only one save request',
      (tester) async {
    final save = Completer<http.Response>();
    await _withGroup(tester, (requests) async {
      await _openMembers(tester);
      await tester.tap(_memberName());
      await tester.pump();
      await tester.tap(_memberName());
      await tester.pump();
      expect(requests.where(_isSave), hasLength(1));
      expect(requests.where(_isPrivateLoad), isEmpty);
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      save.complete(_json({'ok': true}));
      await tester.pumpAndSettle();
      expect(requests.where(_isSave), hasLength(1));
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(requests.where(_isPrivateLoad), isNotEmpty);
    }, saveContact: (_) => save.future);
  });

  testWidgets('narrow viewport opens the usual chat route after saving friend',
      (tester) async {
    await _withGroup(tester, (requests) async {
      await _openMembers(tester);
      await tester.tap(_memberName());
      await tester.pumpAndSettle();
      final chat = find.byType(ChatScreen);
      expect(chat, findsOneWidget);
      expect(tester.widget<ChatScreen>(chat).embedded, isFalse);
      expect(tester.getTopLeft(chat).dx, closeTo(0, .1));
      expect(tester.getSize(chat).width, closeTo(390, .1));
      expect(find.byType(ContentFilterSettingsScreen, skipOffstage: false),
          findsNothing);
      expect(requests.where(_isSave), hasLength(1));
      expect(requests.where((request) => request.method == 'POST'),
          requests.where(_isSave));
    }, screenSize: const Size(390, 844));
  });

  for (final role in ['admin', 'member']) {
    testWidgets(
        '$role opens normal desktop chat directly from the group overview avatar',
        (tester) async {
      await _withGroup(tester, (requests) async {
        await tester.tap(find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('קבוצות'),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('קבוצה לבדיקה'));
        await tester.pumpAndSettle();
        await _openGroupDetails(tester);
        expect(find.byType(AlertDialog), findsNothing);
        await _tapOverviewAvatar(tester, _member['name']!);
        await tester.pumpAndSettle();

        final chatFinder = find.byType(ChatScreen);
        for (var attempt = 0;
            attempt < 10 && !tester.any(chatFinder);
            attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(chatFinder, findsOneWidget);
        final chat = tester.widget<ChatScreen>(chatFinder);
        expect(chat.embedded, isTrue);
        expect(chat.recipient['id'], _member['id']);
        expect(chat.autoSendInitialMessage, isFalse);
        final conversations = tester
            .widget<ConversationsScreen>(find.byType(ConversationsScreen));
        expect(conversations.selectedUserId, _member['id']);
        expect(conversations.users.map((user) => user['id']),
            contains(_member['id']));
        expect(find.byType(ContentFilterSettingsScreen, skipOffstage: false),
            findsNothing);
        expect(find.byType(GroupChatScreen, skipOffstage: false), findsNothing);
        expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
        expect(tester.getTopLeft(chatFinder).dx, closeTo(0, .1));
        expect(tester.getSize(chatFinder).width, closeTo(1400 - 411, .1));
        expect(Navigator.of(tester.element(chatFinder)).canPop(), isFalse);
        final saved = requests.where(_isSave).toList();
        expect(saved, hasLength(1));
        expect(saved.single.headers['Authorization'], 'Bearer test-token');
        final saveIndex = requests.indexWhere(_isSave);
        final refreshIndex = requests.indexWhere(
            (request) => request.url.path.endsWith('/users'), saveIndex + 1);
        expect(refreshIndex, greaterThan(saveIndex));
        expect(requests.indexWhere(_isPrivateLoad), greaterThan(refreshIndex));
        expect(requests.where((request) => request.method == 'POST'), saved);
      }, mainShell: true, groupRole: role, memberPhoto: role == 'admin');
    });
  }

  testWidgets('own overview avatar does not save a friend or open chat',
      (tester) async {
    await _withGroup(tester, (requests) async {
      await _openGroupDetails(tester);
      await _tapOverviewAvatar(tester, _me['name']!);
      await tester.pumpAndSettle();
      expect(find.byType(ContentFilterSettingsScreen), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(requests.where((request) => request.method == 'POST'), isEmpty);
      expect(requests.where(_isPrivateLoad), isEmpty);
    });
  });

  testWidgets('overview avatar shows save failure and can be tapped to retry',
      (tester) async {
    var attempts = 0;
    await _withGroup(tester, (requests) async {
      await _openGroupDetails(tester);
      await _tapOverviewAvatar(tester, _member['name']!);
      await tester.pumpAndSettle();
      expect(find.byType(ContentFilterSettingsScreen), findsOneWidget);
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(requests.where(_isPrivateLoad), isEmpty);
      expect(find.text('שמירת החבר נכשלה בבדיקה'), findsOneWidget);
      await _tapOverviewAvatar(tester, _member['name']!);
      await tester.pumpAndSettle();
      expect(requests.where(_isSave), hasLength(2));
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.byType(ContentFilterSettingsScreen, skipOffstage: false),
          findsNothing);
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
    }, saveContact: (_) async {
      attempts++;
      return attempts == 1
          ? _json({'error': 'שמירת החבר נכשלה בבדיקה'}, 503)
          : _json({'ok': true});
    });
  });

  testWidgets('overview avatar waits for saving and ignores duplicate taps',
      (tester) async {
    final save = Completer<http.Response>();
    await _withGroup(tester, (requests) async {
      await _openGroupDetails(tester);
      await _tapOverviewAvatar(tester, _member['name']!);
      await tester.pump();
      await _tapOverviewAvatar(tester, _member['name']!);
      await tester.pump();
      expect(requests.where(_isSave), hasLength(1));
      expect(requests.where(_isPrivateLoad), isEmpty);
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(ContentFilterSettingsScreen), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(ContentFilterSettingsScreen),
              matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);
      save.complete(_json({'ok': true}));
      await tester.pumpAndSettle();
      expect(requests.where(_isSave), hasLength(1));
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(requests.where(_isPrivateLoad), isNotEmpty);
    }, saveContact: (_) => save.future);
  });

  testWidgets('narrow group overview avatar saves and opens normal chat',
      (tester) async {
    await _withGroup(tester, (requests) async {
      await _openGroupDetails(tester);
      await _tapOverviewAvatar(tester, _member['name']!);
      await tester.pumpAndSettle();
      final chat = find.byType(ChatScreen);
      expect(chat, findsOneWidget);
      expect(tester.widget<ChatScreen>(chat).embedded, isFalse);
      expect(tester.widget<ChatScreen>(chat).autoSendInitialMessage, isFalse);
      expect(tester.getSize(chat).width, closeTo(390, .1));
      expect(find.byType(ContentFilterSettingsScreen, skipOffstage: false),
          findsNothing);
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
      expect(requests.where(_isSave), hasLength(1));
      expect(requests.indexWhere(_isSave),
          lessThan(requests.indexWhere(_isPrivateLoad)));
      expect(requests.where((request) => request.method == 'POST'),
          requests.where(_isSave));
    }, screenSize: const Size(390, 844));
  });
}
