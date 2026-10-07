import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _permissionChannel =
    MethodChannel('flutter.baseflow.com/permissions/methods');
const _contactsChannel = MethodChannel('github.com/QuisApp/flutter_contacts');
const _readPermissionChannel = MethodChannel('com.betshuva.app/contacts');
const _warningKey = ValueKey('friend-contacts-permission-action');

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _Fixture {
  int status = 0;
  int? groupedStatus;
  int requestedStatus = 0;
  int permissionChoices = 0;
  int settingsOpens = 0;
  int contactReads = 0;
  int contactsChanged = 0;
  final osCalls = <String>[];
  final requests = <http.Request>[];
  Completer<int>? permissionGate;
  Completer<List<dynamic>>? contactsGate;
  List<Map<String, dynamic>> directory = [
    {'id': 'directory-before', 'name': 'משתמש במאגר', 'saved': false},
  ];
  final contacts = [
    Contact(
        id: 'matched-phone',
        displayName: 'חבר מהטלפון',
        phones: [Phone('0502222222')]).toJson(),
    Contact(
        id: 'local-phone',
        displayName: 'חבר מקומי',
        phones: [Phone('0503333333')]).toJson(),
  ];

  List<http.Request> get directoryLoads => requests
      .where((request) => request.url.path.endsWith('/users/directory'))
      .toList();
  List<http.Request> get matches => requests
      .where((request) => request.url.path.endsWith('/contacts/match'))
      .toList();

  Future<int> _choosePermission() async {
    permissionChoices++;
    status =
        permissionGate != null ? await permissionGate!.future : requestedStatus;
    return status;
  }

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_permissionChannel, (call) async {
      osCalls.add('permission:${call.method}');
      if (call.method == 'checkPermissionStatus')
        return groupedStatus ?? status;
      if (call.method == 'requestPermissions') {
        final result = await _choosePermission();
        return {
          for (final permission in call.arguments as List) permission: result
        };
      }
      if (call.method == 'openAppSettings') {
        settingsOpens++;
        return true;
      }
      return false;
    });
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_readPermissionChannel, (call) async {
      osCalls.add('readPermission:${call.method}');
      if (call.method == 'readPermissionStatus') return status;
      if (call.method == 'markReadPermissionRequested') return null;
      throw MissingPluginException('Unexpected contacts method ${call.method}');
    });
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_contactsChannel, (call) async {
      osCalls.add('contacts:${call.method}');
      if (call.method == 'requestPermission') {
        return await _choosePermission() == 1;
      }
      if (call.method == 'select') {
        contactReads++;
        if (contactsGate != null) return await contactsGate!.future;
        return contacts;
      }
      return null;
    });
  }

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/users/directory')) return _json(directory);
    if (path.endsWith('/contacts/match')) {
      return _json([
        {
          'id': 'matched-phone-user',
          'name': 'שם השרת',
          'phone': '0502222222',
          'saved': false,
        }
      ]);
    }
    if (path.endsWith('/users/search')) {
      final query = request.url.queryParameters['q']?.toLowerCase() ?? '';
      return _json(directory
          .where(
              (entry) => entry['name'].toString().toLowerCase().contains(query))
          .toList());
    }
    if (path.endsWith('/groups')) return _json([]);
    return _json({});
  }

  void assertNoMessagesOrSavingContacts() {
    expect(
        requests.where((request) =>
            request.method != 'GET' &&
            (request.url.path.endsWith('/messages') ||
                request.url.path.contains('/contacts/save/'))),
        isEmpty);
  }

  Future<void> dispose(WidgetTester tester) async {
    if (permissionGate != null && !permissionGate!.isCompleted) {
      permissionGate!.complete(0);
    }
    if (contactsGate != null && !contactsGate!.isCompleted) {
      contactsGate!.complete([]);
    }
    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_permissionChannel, null);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_contactsChannel, null);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_readPermissionChannel, null);
  }
}

Future<void> _withFriends(
    WidgetTester tester, _Fixture fixture, Future<void> Function() check,
    {Size size = const Size(1000, 900)}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(size);
  fixture.install(tester);
  try {
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSansHebrew'),
          home: Directionality(
              textDirection: TextDirection.rtl,
              child: ConversationsScreen(
                users: const [],
                token: 'permission-session',
                me: const {'id': 'permission-owner', 'name': 'משתמש לבדיקה'},
                socket: null,
                unreadCounts: const {},
                groupUnreadCounts: const {},
                groupTypingNames: const {},
                typingUserIds: const {},
                onChatOpened: (_) {},
                onLogout: () async {},
                onSettings: () {},
                onContactsChanged: () async {
                  fixture.contactsChanged++;
                },
                onVoiceCall: (_) {},
                currentMainNavigationIndex: 0,
                onMainNavigationSelected: (_) {},
                onFilterChanged: (_) {},
              ))));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('חיפוש ושמירת חבר'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await check();
      fixture.assertNoMessagesOrSavingContacts();
      expect(tester.takeException(), isNull);
    }, () => MockClient(fixture.respond));
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.dispose(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
  }
}

Future<void> _tapWarning(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_warningKey));
  await tester.tap(find.byKey(_warningKey));
  await tester.pump();
}

Future<void> _closeDialog(WidgetTester tester) async {
  await tester.tap(find.descendant(
      of: find.byType(AlertDialog), matching: find.byIcon(Icons.close)));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsNothing);
}

void _settingsRoundTrip(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  testWidgets('granting from warning refreshes phone contacts and directory',
      (tester) async {
    final fixture = _Fixture();
    await _withFriends(tester, fixture, () async {
      expect(find.byKey(_warningKey), findsOneWidget);
      expect(find.text('משתמש במאגר'), findsOneWidget);
      expect(fixture.contactReads, 0);
      final choicesBefore = fixture.permissionChoices;
      fixture.requestedStatus = 1;
      fixture.directory = [
        {'id': 'directory-after', 'name': 'חדש במאגר', 'saved': false}
      ];
      await _tapWarning(tester);
      await tester.pumpAndSettle();
      expect(fixture.permissionChoices, choicesBefore + 1);
      expect(fixture.settingsOpens, 0);
      expect(fixture.contactReads, greaterThan(0));
      expect(fixture.directoryLoads, hasLength(2));
      expect(fixture.matches, hasLength(1));
      expect(jsonDecode(fixture.matches.single.body), {
        'phones': ['0502222222', '0503333333'],
        'emails': [],
        'source': 'phone_import',
      });
      expect(fixture.matches.single.headers['authorization'],
          'Bearer permission-session');
      expect(find.byKey(_warningKey), findsNothing);
      expect(find.text('משתמש במאגר'), findsNothing);
      expect(find.text('חדש במאגר'), findsOneWidget);
      expect(find.text('חבר מהטלפון'), findsOneWidget);
      expect(find.text('חבר מקומי'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
    }, size: const Size(390, 844));
  }, skip: kIsWeb);

  testWidgets(
      'permanent denial opens settings and resume refreshes open dialog',
      (tester) async {
    final fixture = _Fixture()
      ..status = 4
      ..requestedStatus = 4;
    await _withFriends(tester, fixture, () async {
      final choicesBefore = fixture.permissionChoices;
      await _tapWarning(tester);
      await tester.pumpAndSettle();
      expect(fixture.settingsOpens, 1);
      expect(fixture.permissionChoices, choicesBefore);
      expect(find.byKey(_warningKey), findsOneWidget);
      fixture.status = 1;
      fixture.directory = [
        {'id': 'settings-new', 'name': 'חבר לאחר הגדרות', 'saved': false}
      ];
      _settingsRoundTrip(tester);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(_warningKey), findsNothing);
      expect(find.text('חבר מהטלפון'), findsOneWidget);
      expect(find.text('חבר לאחר הגדרות'), findsOneWidget);
      expect(fixture.directoryLoads.length, greaterThanOrEqualTo(2));
      expect(fixture.settingsOpens, 1);
      expect(fixture.permissionChoices, choicesBefore);
    });
  }, skip: kIsWeb);

  testWidgets('denying another request keeps the warning actionable',
      (tester) async {
    final fixture = _Fixture();
    await _withFriends(tester, fixture, () async {
      final choicesBefore = fixture.permissionChoices;
      for (var i = 1; i <= 2; i++) {
        await _tapWarning(tester);
        await tester.pumpAndSettle();
        expect(fixture.permissionChoices, choicesBefore + i);
        expect(find.byKey(_warningKey), findsOneWidget);
        expect(find.byType(AlertDialog), findsOneWidget);
      }
      expect(fixture.contactReads, 0);
      expect(fixture.matches, isEmpty);
    });
  }, skip: kIsWeb);

  testWidgets('busy permission request ignores repeated warning taps',
      (tester) async {
    final fixture = _Fixture();
    await _withFriends(tester, fixture, () async {
      final choicesBefore = fixture.permissionChoices;
      fixture.permissionGate = Completer<int>();
      await _tapWarning(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(fixture.permissionChoices, choicesBefore + 1);
      await _tapWarning(tester);
      await _tapWarning(tester);
      expect(fixture.permissionChoices, choicesBefore + 1);
      fixture.permissionGate!.complete(1);
      await tester.pumpAndSettle();
      expect(find.byKey(_warningKey), findsNothing);
      expect(find.text('חבר מהטלפון'), findsOneWidget);
      expect(fixture.matches, hasLength(1));
    });
  }, skip: kIsWeb);

  for (final unmountScreen in [false, true]) {
    testWidgets(
        'closing pending permission does not reopen or update disposed '
        'dialog (unmountScreen=$unmountScreen)', (tester) async {
      final fixture = _Fixture();
      await _withFriends(tester, fixture, () async {
        fixture.permissionGate = Completer<int>();
        await _tapWarning(tester);
        await tester.pump(const Duration(milliseconds: 100));
        if (unmountScreen) {
          await tester.pumpWidget(
              MaterialApp(key: UniqueKey(), home: const Text('מסך אחר')));
        } else {
          await _closeDialog(tester);
        }
        fixture.permissionGate!.complete(1);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byKey(_warningKey), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }, skip: kIsWeb);
  }

  testWidgets('closing pending contact read cannot update a disposed dialog',
      (tester) async {
    final fixture = _Fixture();
    await _withFriends(tester, fixture, () async {
      fixture.requestedStatus = 1;
      fixture.contactsGate = Completer<List<dynamic>>();
      await _tapWarning(tester);
      for (var i = 0; i < 20 && fixture.contactReads == 0; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(fixture.contactReads, greaterThan(0));
      await _closeDialog(tester);
      fixture.contactsGate!.complete(fixture.contacts);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }, skip: kIsWeb);

  testWidgets('granted contacts stay cached when the friend dialog is reopened',
      (tester) async {
    final fixture = _Fixture()
      ..status = 1
      ..groupedStatus = 0
      ..requestedStatus = 1;
    await _withFriends(tester, fixture, () async {
      expect(find.byKey(_warningKey), findsNothing);
      expect(find.text('חבר מהטלפון'), findsOneWidget);
      expect(find.text('חבר מקומי'), findsOneWidget);
      expect(fixture.contactReads, 1);
      expect(fixture.matches, hasLength(1));
      final choicesBefore = fixture.permissionChoices;
      expect(choicesBefore, 0,
          reason: 'READ permission is sufficient even when WRITE is denied');
      await _closeDialog(tester);
      await tester.tap(find.byTooltip('חיפוש ושמירת חבר'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(_warningKey), findsNothing);
      expect(find.text('חבר מהטלפון'), findsOneWidget);
      expect(find.text('חבר מקומי'), findsOneWidget);
      expect(fixture.permissionChoices, choicesBefore);
      expect(fixture.contactReads, 1);
      expect(fixture.matches, hasLength(1));
      expect(fixture.directoryLoads, hasLength(2));
    });
  }, skip: kIsWeb);

  testWidgets('grant refresh preserves typed query and filters local contacts',
      (tester) async {
    final fixture = _Fixture();
    await _withFriends(tester, fixture, () async {
      final searchField = find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField));
      await tester.enterText(searchField, 'מקומי');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('חבר מקומי'), findsNothing);
      fixture.requestedStatus = 1;
      await _tapWarning(tester);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(searchField).controller!.text, 'מקומי');
      expect(find.byKey(_warningKey), findsNothing);
      expect(find.text('חבר מקומי'), findsOneWidget);
      expect(find.text('חבר מהטלפון'), findsNothing);
      expect(find.text('משתמש במאגר'), findsNothing);
      expect(fixture.matches, hasLength(1));
      expect(fixture.directoryLoads, hasLength(2));
    });
  }, skip: kIsWeb);

  testWidgets('revocation on resume clears phone names and preserves search',
      (tester) async {
    final fixture = _Fixture()
      ..status = 1
      ..groupedStatus = 0
      ..requestedStatus = 1;
    await _withFriends(tester, fixture, () async {
      final searchField = find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField));
      await tester.enterText(searchField, 'מקומי');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('חבר מקומי'), findsOneWidget);
      final choicesBefore = fixture.permissionChoices;
      fixture.status = 0;
      _settingsRoundTrip(tester);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(searchField).controller!.text, 'מקומי');
      expect(find.byKey(_warningKey), findsOneWidget);
      expect(find.text('חבר מקומי'), findsNothing);
      expect(find.text('חבר מהטלפון'), findsNothing);
      expect(fixture.permissionChoices, choicesBefore);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('device_contact_names_v1_permission-owner'),
          isFalse);
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  }, skip: kIsWeb);

  testWidgets(
      'Web friend directory has no device permission action or OS calls',
      (tester) async {
    final fixture = _Fixture();
    await _withFriends(tester, fixture, () async {
      expect(find.text('משתמש במאגר'), findsOneWidget);
      expect(find.byKey(_warningKey), findsNothing);
      expect(fixture.osCalls, isEmpty);
      expect(fixture.contactReads, 0);
      expect(fixture.matches, isEmpty);
      expect(fixture.directoryLoads, hasLength(1));
    });
  }, skip: !kIsWeb);
}
