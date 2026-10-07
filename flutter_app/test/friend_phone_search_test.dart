import 'dart:async';
import 'dart:convert';

import 'package:betshuva/device_contact_cache.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _readChannel = MethodChannel('com.betshuva.app/contacts');
const _permissionChannel =
    MethodChannel('flutter.baseflow.com/permissions/methods');
const _contactsChannel = MethodChannel('github.com/QuisApp/flutter_contacts');
const _savedId = 'saved-friend';
const _unsavedId = 'new-friend';

http.Response _json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _friend(String id, String name,
        {bool saved = false,
        String? phone = '0501234567',
        String visibility = 'known'}) =>
    {
      'id': id,
      'name': name,
      'saved': saved,
      'phone': phone,
      'phone_visibility': visibility,
      'contact_source': 'in_app'
    };

class _Fixture {
  final requests = <http.Request>[];
  final opened = <String>[];
  final selected = <Map<String, dynamic>>[];
  final pendingSearches = <String, Completer<http.Response>>{};
  final searchResults = <String, List<Map<String, dynamic>>>{};
  List<Map<String, dynamic>> directory = [];
  List<Map<String, dynamic>> defaultResults = [];
  int contactsChanged = 0;
  List<http.Request> get searches =>
      requests.where((r) => r.url.path.endsWith('/users/search')).toList();
  List<http.Request> get writes =>
      requests.where((r) => r.method != 'GET').toList();
  List<http.Request> get saves =>
      writes.where((r) => r.url.path.contains('/contacts/save/')).toList();

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_readChannel,
        (call) async => call.method == 'readPermissionStatus' ? 1 : null);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _permissionChannel,
        (call) async => call.method == 'checkPermissionStatus' ? 1 : false);
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_contactsChannel, (call) async {
      if (call.method == 'select') return [];
      if (call.method == 'requestPermission') return true;
      return null;
    });
  }

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/users/directory')) return _json(directory);
    if (path.endsWith('/users/search')) {
      final query = request.url.queryParameters['q']!;
      final pending = pendingSearches[query];
      if (pending != null) return pending.future;
      return _json(searchResults[query] ?? defaultResults);
    }
    // Preserve the old GET -> POST response projection for the regression:
    // both endpoints report whether the contact was already saved.
    if (path.endsWith('/contacts/match')) return _json(defaultResults);
    if (path.contains('/contacts/save/')) return _json({'ok': true});
    if (path.endsWith('/groups')) return _json([]);
    return _json({});
  }

  Future<void> dispose(WidgetTester tester) async {
    for (final pending in pendingSearches.values) {
      if (!pending.isCompleted) pending.complete(_json([]));
    }
    await tester.pump(const Duration(milliseconds: 100));
    for (final channel in [
      _readChannel,
      _permissionChannel,
      _contactsChannel
    ]) {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  }
}

Finder _field() => find.descendant(
    of: find.byType(AlertDialog), matching: find.byType(TextField));

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(_field(), query);
  await tester.pump(const Duration(milliseconds: 301));
  await tester.pumpAndSettle();
}

Future<void> _withFriends(WidgetTester tester, _Fixture fixture,
    Future<void> Function() check) async {
  SharedPreferences.setMockInitialValues({});
  await tester.binding.setSurfaceSize(const Size(1000, 900));
  fixture.install(tester);
  try {
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: ConversationsScreen(
            users: const [],
            token: 'phone-search-session',
            me: const {'id': 'phone-search-owner', 'name': 'משתמש לבדיקה'},
            socket: null,
            unreadCounts: const {},
            groupUnreadCounts: const {},
            groupTypingNames: const {},
            typingUserIds: const {},
            onChatOpened: fixture.opened.add,
            onUserSelected: (user) => fixture.selected.add(Map.of(user)),
            onLogout: () async {},
            onSettings: () {},
            onContactsChanged: () async {
              fixture.contactsChanged++;
            },
            onVoiceCall: (_) {},
            currentMainNavigationIndex: 0,
            onMainNavigationSelected: (_) {},
            onFilterChanged: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('חיפוש ושמירת חבר'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await check();
      expect(
          fixture.writes.where((r) =>
              r.url.path.endsWith('/messages') ||
              r.url.path.contains('/invites/')),
          isEmpty);
      expect(tester.takeException(), isNull);
    }, () => MockClient(fixture.respond));
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.dispose(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.binding.setSurfaceSize(null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (kIsWeb) return;
    final loader = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await loader.load();
  });

  testWidgets('saved exact phone stays excluded and searching never writes',
      (tester) async {
    final fixture = _Fixture()
      ..defaultResults = [_friend(_savedId, 'חבר שמור', saved: true)];
    await _withFriends(tester, fixture, () async {
      await _search(tester, '0501234567');
      expect(fixture.searches.single.url.queryParameters['q'], '0501234567');
      expect(find.text('חבר שמור'), findsNothing);
      expect(find.text('פתח שיחה'), findsNothing);
      expect(find.text('שמור'), findsNothing);
      expect(fixture.writes, isEmpty);
      expect(fixture.contactsChanged, 0);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(fixture.opened, isEmpty);
      expect(fixture.selected, isEmpty);
      expect(fixture.writes, isEmpty);
    });
  });

  testWidgets('saved directory entry stays excluded during explicit search',
      (tester) async {
    final fixture = _Fixture()
      ..directory = [
        _friend(_savedId, 'חבר שמור', saved: true),
        _friend(_unsavedId, 'חבר חדש')
      ]
      ..defaultResults = [_friend(_savedId, 'חבר שמור', saved: true)];
    await _withFriends(tester, fixture, () async {
      expect(find.text('חבר שמור'), findsNothing);
      expect(find.text('חבר חדש'), findsOneWidget);
      await _search(tester, 'חבר שמור');
      expect(
          find.descendant(
              of: find.byType(ListTile), matching: find.text('חבר שמור')),
          findsNothing);
      expect(find.text('פתח שיחה'), findsNothing);
      expect(fixture.writes, isEmpty);
      await _search(tester, '');
      expect(find.text('חבר שמור'), findsNothing);
      expect(find.text('חבר חדש'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  testWidgets(
      'fresh saved result cannot be revived by an unsaved directory copy',
      (tester) async {
    final fixture = _Fixture()
      ..directory = [_friend(_savedId, 'עותק ישן מהמאגר')]
      ..defaultResults = [_friend(_savedId, 'חבר שכבר שמור', saved: true)];
    await _withFriends(tester, fixture, () async {
      expect(find.text('עותק ישן מהמאגר'), findsOneWidget);
      await _search(tester, '0501234567');
      expect(find.text('עותק ישן מהמאגר'), findsNothing);
      expect(find.text('חבר שכבר שמור'), findsNothing);
      expect(find.text('שמור'), findsNothing);
      expect(fixture.writes, isEmpty);
    });
  });

  testWidgets(
      'formatted local phone substring uses only visible directory numbers',
      (tester) async {
    final fixture = _Fixture()
      ..directory = [
        _friend('visible-directory', 'מספר גלוי'),
        _friend('hidden-directory', 'מספר חסוי', visibility: 'hidden'),
      ];
    await _withFriends(tester, fixture, () async {
      await _search(tester, '050 123');
      expect(fixture.searches.single.url.queryParameters['q'], '050 123');
      expect(find.text('מספר גלוי'), findsOneWidget);
      expect(find.text('מספר חסוי'), findsNothing);
      expect(fixture.writes, isEmpty);
    });
  });

  for (final query in [
    '+972 50-123-4567',
    '050 123 4567',
    '050-123-4567',
    '00972 50-123-4567'
  ]) {
    testWidgets('formatted exact phone $query saves only after explicit choice',
        (tester) async {
      final fixture = _Fixture()
        ..defaultResults = [_friend(_unsavedId, 'חבר חדש')];
      await _withFriends(tester, fixture, () async {
        await _search(tester, query);
        expect(fixture.searches.single.url.queryParameters['q'], query);
        expect(find.text('חבר חדש'), findsOneWidget);
        expect(fixture.writes, isEmpty);
        expect(fixture.contactsChanged, 0);
        await tester.tap(find.text('שמור'));
        await tester.pumpAndSettle();
        expect(fixture.writes, hasLength(1));
        expect(fixture.saves.single.url.path,
            endsWith('/contacts/save/$_unsavedId'));
        final payload =
            jsonDecode(fixture.saves.single.body) as Map<String, dynamic>;
        expect(payload['source'], 'phone_manual');
        expect(
            DeviceContactCache.normalizePhone(payload['knownPhone'] as String),
            '0501234567');
        expect(fixture.saves.single.headers['authorization'],
            'Bearer phone-search-session');
        expect(fixture.contactsChanged, 1);
        expect(find.text('חבר חדש'), findsNothing);
      });
    });
  }

  for (final sample in [
    {'query': '0501234567', 'phone': null, 'visibility': 'hidden'},
    {'query': '0501234567', 'phone': '0527654321', 'visibility': 'shared'},
    {'query': 'חבר חדש', 'phone': '0501234567', 'visibility': 'known'},
  ]) {
    testWidgets('save has no manual proof for $sample', (tester) async {
      final fixture = _Fixture()
        ..defaultResults = [
          _friend(_unsavedId, 'חבר חדש',
              phone: sample['phone'], visibility: sample['visibility']!)
        ];
      await _withFriends(tester, fixture, () async {
        await _search(tester, sample['query']!);
        expect(fixture.writes, isEmpty);
        await tester.tap(find.text('שמור'));
        await tester.pumpAndSettle();
        expect(jsonDecode(fixture.saves.single.body), {'source': 'in_app'});
        expect(fixture.writes, hasLength(1));
      });
    });
  }

  testWidgets('late completed search cannot replace a newer query result',
      (tester) async {
    final old = Completer<http.Response>();
    final fixture = _Fixture()
      ..pendingSearches['ישן'] = old
      ..searchResults['חדש'] = [_friend('new-query', 'תוצאה חדשה')];
    await _withFriends(tester, fixture, () async {
      await tester.enterText(_field(), 'ישן');
      await tester.pump(const Duration(milliseconds: 301));
      expect(fixture.searches.map((r) => r.url.queryParameters['q']), ['ישן']);
      await _search(tester, 'חדש');
      expect(find.text('תוצאה חדשה'), findsOneWidget);
      old.complete(_json([_friend('old-query', 'תוצאה ישנה')]));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_field()).controller!.text, 'חדש');
      expect(find.text('תוצאה חדשה'), findsOneWidget);
      expect(find.text('תוצאה ישנה'), findsNothing);
      expect(fixture.writes, isEmpty);
    });
  });

  testWidgets('clearing a pending search restores directory and stops loading',
      (tester) async {
    final old = Completer<http.Response>();
    final fixture = _Fixture()
      ..directory = [_friend('directory', 'משתמש מהמאגר')]
      ..pendingSearches['ישן'] = old;
    await _withFriends(tester, fixture, () async {
      await tester.enterText(_field(), 'ישן');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.enterText(_field(), '');
      await tester.pump(const Duration(milliseconds: 301));
      // Settle only after cancellation clears the visible loading animation.
      await tester.pumpAndSettle();
      expect(find.text('משתמש מהמאגר'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      old.complete(_json([_friend('old-query', 'תוצאה ישנה')]));
      await tester.pumpAndSettle();
      expect(find.text('משתמש מהמאגר'), findsOneWidget);
      expect(find.text('תוצאה ישנה'), findsNothing);
      expect(fixture.searches, hasLength(1));
      expect(fixture.writes, isEmpty);
    });
  });

  testWidgets('query change invalidates old response before its new debounce',
      (tester) async {
    final old = Completer<http.Response>();
    final fixture = _Fixture()
      ..pendingSearches['ישן'] = old
      ..searchResults['חדש'] = [_friend('new-query', 'תוצאה חדשה')];
    await _withFriends(tester, fixture, () async {
      await tester.enterText(_field(), 'ישן');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.enterText(_field(), 'חדש');
      old.complete(_json([_friend('old-query', 'תוצאה ישנה')]));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('תוצאה ישנה'), findsNothing);
      expect(fixture.searches, hasLength(1));
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(find.text('תוצאה חדשה'), findsOneWidget);
      expect(fixture.writes, isEmpty);
    });
  });
}
