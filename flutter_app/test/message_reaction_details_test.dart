import 'dart:async';
import 'dart:convert';

import 'package:betshuva/message_reactions.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _api = 'https://example.test/api';
const _token = 'details-account';
const _message = 'details-message';
late String _reactionLibraryCatalog;

class _ReactionAssets extends CachingAssetBundle {
  @override
  Future<String> loadString(String key, {bool cache = true}) {
    if (key == 'assets/stickers/user-catalog.json') {
      return Future.value(_reactionLibraryCatalog);
    }
    return super.loadString(key, cache: cache);
  }

  @override
  Future<ByteData> load(String key) async {
    if (key == 'assets/stickers/user-catalog.json') {
      return rootBundle.load(key);
    }
    return ByteData.sublistView(Uint8List.fromList(utf8
        .encode('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36">'
            '<circle cx="18" cy="18" r="16" fill="#ffcc4d"/></svg>')));
  }
}

Map<String, dynamic> _person(String id, String name, String emoji,
        {bool mine = false}) =>
    {
      'user_id': id,
      'name': name,
      'photo_url': null,
      'emoji': emoji,
      'mine': mine,
    };

List<Map<String, dynamic>> _summaries(List<Map<String, dynamic>> users) {
  final result = <String, Map<String, dynamic>>{};
  for (final user in users) {
    final emoji = user['emoji'] as String;
    final summary = result.putIfAbsent(
        emoji, () => {'emoji': emoji, 'count': 0, 'mine': false});
    summary['count'] = (summary['count'] as int) + 1;
    summary['mine'] = summary['mine'] == true || user['mine'] == true;
  }
  return result.values.toList();
}

http.Response _response(Object? value, {int status = 200}) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

class _Fixture {
  _Fixture({List<Map<String, dynamic>>? users})
      : users = users ??
            [
              _person('own', 'שם משותף', '🙏', mine: true),
              _person('friend', 'אשרת חיל', '❤️'),
              _person('same-name', 'שם משותף', '❤️'),
            ] {
    client = MockClient(_request);
  }

  List<Map<String, dynamic>> users;
  final capture = GlobalKey();
  final cache = MessageReactionsCache();
  late final http.Client client;
  final requests = <http.Request>[];
  final writes = <Map<String, dynamic>>[];
  int detailsStatus = 200;
  int detailsReads = 0;
  Completer<http.Response>? pendingDetails;

  Future<http.Response> _request(http.Request request) async {
    requests.add(request);
    if (request.method == 'PUT') {
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      writes.add(body);
      users.removeWhere((user) => user['mine'] == true);
      if (body['emoji'] != null) {
        users.insert(
            0, _person('own', 'שם משותף', body['emoji'] as String, mine: true));
      }
      return _response(_summaries(users));
    }
    if (request.url.path.endsWith('/details')) {
      detailsReads++;
      if (pendingDetails != null && detailsReads == 1) {
        return pendingDetails!.future;
      }
      return _response({'reactions': _summaries(users), 'users': users},
          status: detailsStatus);
    }
    return _response(_summaries(users));
  }
}

Widget _view(_Fixture fixture,
        {String token = _token,
        String message = _message,
        double textScale = 1}) =>
    RepaintBoundary(
      key: fixture.capture,
      child: DefaultAssetBundle(
        bundle: _ReactionAssets(),
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!),
          home: Scaffold(
            body: Directionality(
              textDirection: TextDirection.rtl,
              child: MessageReactions(
                key: const ValueKey('same-reaction-state'),
                api: _api,
                token: token,
                messageId: message,
                client: fixture.client,
                cache: fixture.cache,
                compact: true,
                showAddButton: false,
              ),
            ),
          ),
        ),
      ),
    );

Finder _badge(String emoji) => find.byKey(ValueKey('compact-reaction-$emoji'));
Finder _filter(String emoji) => find.byKey(ValueKey('reaction-filter-$emoji'));
Finder _personRow(String id) => find.byKey(ValueKey('reaction-person-$id'));
Finder _choice(String emoji) => find.byKey(ValueKey('change-reaction-$emoji'));
Finder get _details => find.byKey(const ValueKey('reaction-details-dialog'));
Finder get _addOwn => find.byKey(const ValueKey('reaction-details-add-own'));
Finder get _more => find.byKey(const ValueKey('more-message-reactions'));
Finder get _library => find.byKey(const ValueKey('message-reaction-library'));

Future<void> _open(WidgetTester tester, _Fixture fixture,
    {String emoji = '🙏', double textScale = 1}) async {
  await tester.pumpWidget(_view(fixture, textScale: textScale));
  await tester.pumpAndSettle();
  await tester.tap(_badge(emoji));
  await tester.pumpAndSettle();
}

Future<void> _showAll(WidgetTester tester) async {
  await tester.tap(_filter('all'));
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(const SizedBox());
  fixture.client.close();
  fixture.cache.dispose();
}

void main() {
  setUpAll(() async {
    _reactionLibraryCatalog =
        await rootBundle.loadString('assets/stickers/user-catalog.json');
  });

  testWidgets(
      'star filters and actor names remain separate at 320px and 200 percent text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const one = '[[bt-emoji:027]]';
    const two = '[[bt-emoji:133]]';
    final fixture = _Fixture(users: [
      _person('own', 'אני', one, mine: true),
      _person('friend-one', 'שם ארוך של חברה עם כוכב', two),
      _person('friend-two', 'חבר נוסף עם כוכב', two),
    ]);
    await _open(tester, fixture, emoji: one, textScale: 2);
    await _showAll(tester);
    final dialog = tester.getRect(_details);
    expect(dialog.left, greaterThanOrEqualTo(0));
    expect(dialog.right, lessThanOrEqualTo(320));
    for (final entry in [(one, 27, '1'), (two, 133, '2')]) {
      final chip = tester.getRect(_filter(entry.$1));
      final artwork = tester.getRect(find.descendant(
          of: _filter(entry.$1),
          matching: find.byKey(ValueKey('inline-custom-emoji-${entry.$2}'))));
      final count = tester.getRect(find.descendant(
          of: _filter(entry.$1), matching: find.text(entry.$3)));
      expect(artwork.overlaps(count), isFalse);
      expect(count.right, lessThanOrEqualTo(artwork.left));
      expect(artwork.left, greaterThanOrEqualTo(chip.left));
      expect(artwork.right, lessThanOrEqualTo(chip.right));
      expect(artwork.top, greaterThanOrEqualTo(chip.top));
      expect(artwork.bottom, lessThanOrEqualTo(chip.bottom));
      expect(chip.left, greaterThanOrEqualTo(dialog.left));
      expect(chip.right, lessThanOrEqualTo(dialog.right));
    }
    for (final entry in [
      ('own', 27, 'את/ה'),
      ('friend-one', 133, 'שם ארוך של חברה עם כוכב')
    ]) {
      await tester.scrollUntilVisible(_personRow(entry.$1), 60,
          scrollable: find
              .descendant(of: _details, matching: find.byType(Scrollable))
              .first);
      await tester.pumpAndSettle();
      final row = tester.getRect(_personRow(entry.$1));
      final artwork = tester.getRect(find.descendant(
          of: _personRow(entry.$1),
          matching: find.byKey(ValueKey('inline-custom-emoji-${entry.$2}'))));
      final name = tester.getRect(find.descendant(
          of: _personRow(entry.$1), matching: find.text(entry.$3)));
      expect(artwork.overlaps(name), isFalse);
      expect(artwork.right, lessThanOrEqualTo(name.left));
      expect(artwork.left, greaterThanOrEqualTo(row.left));
      expect(artwork.right, lessThanOrEqualTo(row.right));
      expect(artwork.top, greaterThanOrEqualTo(row.top));
      expect(artwork.bottom, lessThanOrEqualTo(row.bottom));
    }
    expect(fixture.writes, isEmpty);
    expect(tester.takeException(), isNull);
    await _dispose(tester, fixture);
  });

  testWidgets('opening details shows names and counts without a reaction write',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    expect(_details, findsOneWidget);
    expect(_filter('all'), findsOneWidget);
    expect(find.text('הכול 3'), findsOneWidget);
    expect(find.text('3 תגובות אימוג׳י'), findsOneWidget);
    expect(_filter('🙏'), findsOneWidget);
    expect(_filter('❤️'), findsOneWidget);
    await _showAll(tester);
    expect(_personRow('own'), findsOneWidget);
    expect(_personRow('friend'), findsOneWidget);
    expect(_personRow('same-name'), findsOneWidget);
    expect(find.text('אשרת חיל'), findsOneWidget);
    expect(find.text('את/ה'), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNWidgets(3));
    expect(find.descendant(of: _filter('❤️'), matching: find.text('2')),
        findsOneWidget);
    expect(find.descendant(of: _filter('🙏'), matching: find.text('1')),
        findsOneWidget);
    expect(fixture.writes, isEmpty);
    expect(
        fixture.requests.where((request) =>
            request.url.path == '/api/messages/$_message/reactions/details'),
        hasLength(1));
    if (!kIsWeb) {
      await expectLater(
          find.byKey(fixture.capture),
          matchesGoldenFile(
              '/home/yaniv/.local/state/newone-releases/reaction-details-web-20261007/reaction-details-test-layout.png'));
    }
    await _dispose(tester, fixture);
  });

  testWidgets('emoji tabs filter actors without changing any reaction',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    await tester.tap(_filter('❤️'));
    await tester.pumpAndSettle();
    expect(_personRow('friend'), findsOneWidget);
    expect(_personRow('same-name'), findsOneWidget);
    expect(_personRow('own'), findsNothing);
    await tester.tap(_filter('🙏'));
    await tester.pumpAndSettle();
    expect(_personRow('own'), findsOneWidget);
    expect(_personRow('friend'), findsNothing);
    await _showAll(tester);
    expect(_personRow('own'), findsOneWidget);
    expect(_personRow('friend'), findsOneWidget);
    expect(fixture.writes, isEmpty);
    await _dispose(tester, fixture);
  });

  testWidgets('foreign actor rows including the same name are read only',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    await _showAll(tester);
    for (final id in ['friend', 'same-name']) {
      await tester.tap(_personRow(id));
      await tester.pumpAndSettle();
      expect(_choice('👍'), findsNothing);
      expect(find.byKey(const ValueKey('remove-own-reaction')), findsNothing);
      expect(_details, findsOneWidget);
      expect(fixture.writes, isEmpty);
    }
    await _dispose(tester, fixture);
  });

  testWidgets('own actor can change only its reaction with an emoji-only body',
      (tester) async {
    final fixture = _Fixture();
    final foreign = fixture.users
        .where((user) => user['mine'] != true)
        .map(Map<String, dynamic>.from)
        .toList();
    await _open(tester, fixture);
    await _showAll(tester);
    await tester.tap(_personRow('own'));
    await tester.pumpAndSettle();
    expect(_choice('😂'), findsOneWidget);
    expect(find.byKey(const ValueKey('remove-own-reaction')), findsOneWidget);
    await tester.tap(_choice('😂'));
    await tester.pumpAndSettle();
    expect(fixture.writes, [
      <String, dynamic>{'emoji': '😂'}
    ]);
    expect(
        fixture.users.where((user) => user['mine'] != true).toList(), foreign);
    expect(_badge('😂'), findsOneWidget);
    expect(_badge('🙏'), findsNothing);
    expect(_details, findsOneWidget);
    expect(_filter('😂'), findsOneWidget);
    await _showAll(tester);
    expect(_personRow('friend'), findsOneWidget);
    expect(_personRow('own'), findsOneWidget);
    final request = fixture.requests.singleWhere((r) => r.method == 'PUT');
    expect(request.url.path, '/api/messages/$_message/reactions');
    expect(request.headers['Authorization'], 'Bearer $_token');
    await _dispose(tester, fixture);
  });

  testWidgets(
      'custom actor artwork fits enlarged frames and foreign rows read only',
      (tester) async {
    const first = '[[bt-emoji:001]]';
    const last = '[[bt-emoji:150]]';
    final fixture = _Fixture(users: [
      _person('own', 'שם משותף', first, mine: true),
      _person('friend', 'שם משותף', last),
    ]);
    final foreign = Map<String, dynamic>.from(fixture.users.last);
    await _open(tester, fixture, emoji: first);
    await _showAll(tester);
    expect(find.textContaining('[[bt-emoji:'), findsNothing);
    for (final entry in [('own', 1), ('friend', 150)]) {
      final artwork = find.descendant(
          of: _personRow(entry.$1),
          matching: find.byKey(ValueKey('inline-custom-emoji-${entry.$2}')));
      expect(artwork, findsOneWidget);
      final glyph = tester.getRect(artwork);
      final row = tester.getRect(_personRow(entry.$1));
      expect(glyph.width, closeTo(29.04, .001));
      expect(glyph.height, closeTo(29.04, .001));
      expect(glyph.left, greaterThanOrEqualTo(row.left));
      expect(glyph.right, lessThanOrEqualTo(row.right));
      expect(glyph.top, greaterThanOrEqualTo(row.top));
      expect(glyph.bottom, lessThanOrEqualTo(row.bottom));
      final token = entry.$2 == 1 ? first : last;
      final filter = tester.getRect(_filter(token));
      final filterGlyph = tester.getRect(find.descendant(
          of: _filter(token),
          matching: find.byKey(ValueKey('inline-custom-emoji-${entry.$2}'))));
      expect(filterGlyph.width, closeTo(24.2, .001));
      expect(filterGlyph.height, closeTo(24.2, .001));
      expect(filterGlyph.left, greaterThanOrEqualTo(filter.left));
      expect(filterGlyph.right, lessThanOrEqualTo(filter.right));
      expect(filterGlyph.top, greaterThanOrEqualTo(filter.top));
      expect(filterGlyph.bottom, lessThanOrEqualTo(filter.bottom));
    }
    await tester.tap(_personRow('friend'));
    await tester.pumpAndSettle();
    expect(_more, findsNothing);
    expect(_library, findsNothing);
    expect(fixture.writes, isEmpty);
    await tester.tap(_personRow('own'));
    await tester.pumpAndSettle();
    for (final emoji in messageReactionEmoji) {
      expect(_choice(emoji), findsOneWidget);
    }
    expect(_more, findsOneWidget);
    await tester.tap(_more);
    await tester.pumpAndSettle();
    expect(_library, findsOneWidget);
    expect(fixture.writes, isEmpty);
    await tester.enterText(
        find.byKey(const ValueKey('reaction-library-search')),
        'זהירות מקישור לא ידוע');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reaction-library-emoji-150')));
    await tester.pumpAndSettle();
    expect(_library, findsNothing);
    expect(_details, findsOneWidget);
    expect(fixture.writes, [
      <String, dynamic>{'emoji': last}
    ]);
    expect(fixture.users.singleWhere((user) => user['user_id'] == 'friend'),
        foreign);
    expect(fixture.users.singleWhere((user) => user['mine'] == true)['emoji'],
        last);
    expect(tester.takeException(), isNull);
    await _dispose(tester, fixture);
  });

  testWidgets('opening and cancelling more choices preserves every actor',
      (tester) async {
    final fixture = _Fixture();
    final before = fixture.users.map(Map<String, dynamic>.from).toList();
    await _open(tester, fixture);
    await _showAll(tester);
    await tester.tap(_personRow('own'));
    await tester.pumpAndSettle();
    await tester.tap(_more);
    await tester.pumpAndSettle();
    expect(_library, findsOneWidget);
    expect(fixture.writes, isEmpty);
    await tester.tap(find.byTooltip('סגירה'));
    await tester.pumpAndSettle();
    expect(_library, findsNothing);
    expect(_details, findsOneWidget);
    expect(fixture.writes, isEmpty);
    expect(fixture.users, before);
    await _dispose(tester, fixture);
  });

  testWidgets('removing own actor keeps all foreign reactions and rows',
      (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    await _showAll(tester);
    await tester.tap(_personRow('own'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('remove-own-reaction')));
    await tester.pumpAndSettle();
    expect(fixture.writes, [
      <String, dynamic>{'emoji': null}
    ]);
    expect(_badge('🙏'), findsNothing);
    expect(_badge('❤️'), findsOneWidget);
    await _showAll(tester);
    expect(_personRow('own'), findsNothing);
    expect(_personRow('friend'), findsOneWidget);
    expect(_personRow('same-name'), findsOneWidget);
    expect(fixture.users.map((user) => user['user_id']).toList(),
        ['friend', 'same-name']);
    await _dispose(tester, fixture);
  });

  testWidgets('choosing the current own emoji is a no-op', (tester) async {
    final fixture = _Fixture();
    await _open(tester, fixture);
    await _showAll(tester);
    await tester.tap(_personRow('own'));
    await tester.pumpAndSettle();
    await tester.tap(_choice('🙏'));
    await tester.pumpAndSettle();
    expect(fixture.writes, isEmpty);
    expect(_badge('🙏'), findsOneWidget);
    await _dispose(tester, fixture);
  });

  testWidgets('adding own reaction never edits a foreign actor',
      (tester) async {
    final fixture = _Fixture(users: [_person('friend', 'אשרת חיל', '❤️')]);
    await _open(tester, fixture, emoji: '❤️');
    await _showAll(tester);
    await tester.tap(_personRow('friend'));
    await tester.pumpAndSettle();
    expect(_choice('👍'), findsNothing);
    await tester.tap(_addOwn);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remove-own-reaction')), findsNothing);
    await tester.tap(_choice('❤️'));
    await tester.pumpAndSettle();
    expect(fixture.writes, [
      <String, dynamic>{'emoji': '❤️'}
    ]);
    expect(fixture.users.singleWhere((user) => user['user_id'] == 'friend'),
        _person('friend', 'אשרת חיל', '❤️'));
    expect(_badge('❤️'), findsOneWidget);
    await _dispose(tester, fixture);
  });

  for (final status in [403, 404, 500]) {
    testWidgets('a $status details response exposes no actor edit controls',
        (tester) async {
      final fixture = _Fixture()..detailsStatus = status;
      await _open(tester, fixture);
      expect(_personRow('own'), findsNothing);
      expect(_personRow('friend'), findsNothing);
      expect(_choice('👍'), findsNothing);
      if (_addOwn.evaluate().isNotEmpty) {
        await tester.tap(_addOwn, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      expect(_choice('👍'), findsNothing);
      expect(fixture.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await _dispose(tester, fixture);
    });
  }

  testWidgets(
      'pending details from a previous account cannot reveal its actors',
      (tester) async {
    final fixture = _Fixture();
    fixture.pendingDetails = Completer<http.Response>();
    await tester.pumpWidget(_view(fixture));
    await tester.pumpAndSettle();
    await tester.tap(_badge('🙏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_personRow('own'), findsNothing);
    await tester.pumpWidget(_view(fixture, token: 'another-account'));
    await tester.pump();
    fixture.pendingDetails!.complete(_response({
      'reactions': _summaries(fixture.users),
      'users': fixture.users,
    }));
    await tester.pumpAndSettle();
    expect(_personRow('own'), findsNothing);
    expect(find.text('אשרת חיל'), findsNothing);
    expect(fixture.writes, isEmpty);
    expect(tester.takeException(), isNull);
    await _dispose(tester, fixture);
  });

  testWidgets('a stale details read cannot undo a newer socket reaction',
      (tester) async {
    final fixture = _Fixture(users: [
      _person('own', 'שם משתמש', '🙏', mine: true),
      _person('friend', 'תגובה ישנה', '❤️'),
    ]);
    final oldUsers = fixture.users.map(Map<String, dynamic>.from).toList();
    fixture.pendingDetails = Completer<http.Response>();
    await tester.pumpWidget(_view(fixture));
    await tester.pumpAndSettle();
    await tester.tap(_badge('🙏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fixture.detailsReads, 1);
    fixture.users = [
      _person('own', 'שם משתמש', '😂', mine: true),
      _person('friend', 'תגובה עדכנית', '❤️'),
    ];
    fixture.cache.invalidate(
        api: _api, token: _token, messageId: _message, eventId: 'new-reaction');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_badge('😂'), findsOneWidget);
    expect(_badge('🙏'), findsNothing);
    fixture.pendingDetails!.complete(_response({
      'reactions': _summaries(oldUsers),
      'users': oldUsers,
    }));
    await tester.pumpAndSettle();
    expect(_badge('😂'), findsOneWidget);
    expect(_badge('🙏'), findsNothing);
    await _showAll(tester);
    expect(find.text('תגובה ישנה'), findsNothing);
    expect(find.text('תגובה עדכנית'), findsOneWidget);
    expect(fixture.detailsReads, greaterThanOrEqualTo(2));
    await tester.tap(_personRow('own'));
    await tester.pumpAndSettle();
    expect(
        find.descendant(of: _choice('😂'), matching: find.byIcon(Icons.check)),
        findsOneWidget);
    expect(
        find.descendant(of: _choice('🙏'), matching: find.byIcon(Icons.check)),
        findsNothing);
    await tester.tap(_choice('😂'));
    await tester.pumpAndSettle();
    expect(fixture.writes, isEmpty);
    expect(_badge('😂'), findsOneWidget);
    await _dispose(tester, fixture);
  });

  for (final switchAccount in [true, false]) {
    testWidgets(
        'an open chooser cannot write after ${switchAccount ? 'account' : 'message'} changes',
        (tester) async {
      final fixture = _Fixture();
      await _open(tester, fixture);
      await _showAll(tester);
      await tester.tap(_personRow('own'));
      await tester.pumpAndSettle();
      expect(_choice('😂'), findsOneWidget);
      await tester.pumpWidget(_view(fixture,
          token: switchAccount ? 'another-account' : _token,
          message: switchAccount ? _message : 'another-message'));
      await tester.pumpAndSettle();
      if (_choice('😂').evaluate().isNotEmpty) {
        await tester.tap(_choice('😂'));
        await tester.pumpAndSettle();
      }
      expect(fixture.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await _dispose(tester, fixture);
    });

    testWidgets(
        'an open custom library cannot write after ${switchAccount ? 'account' : 'message'} changes',
        (tester) async {
      final fixture = _Fixture();
      await _open(tester, fixture);
      await _showAll(tester);
      await tester.tap(_personRow('own'));
      await tester.pumpAndSettle();
      await tester.tap(_more);
      await tester.pumpAndSettle();
      expect(_library, findsOneWidget);
      await tester.pumpWidget(_view(fixture,
          token: switchAccount ? 'another-account' : _token,
          message: switchAccount ? _message : 'another-message'));
      await tester.pumpAndSettle();
      final choice = find.byKey(const ValueKey('reaction-library-emoji-001'));
      if (choice.evaluate().isNotEmpty) {
        await tester.tap(choice);
        await tester.pumpAndSettle();
      }
      expect(fixture.writes, isEmpty);
      expect(_library, findsNothing);
      expect(_details, findsNothing);
      expect(tester.takeException(), isNull);
      await _dispose(tester, fixture);
    });
  }

  testWidgets('details fit a narrow RTL web view without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = _Fixture(users: [
      for (var i = 0; i < 12; i++)
        _person('actor-$i', 'שם משתמש ארוך במסך צר מספר $i',
            messageReactionEmoji[i % messageReactionEmoji.length],
            mine: i == 0),
    ]);
    await _open(tester, fixture, emoji: '👍');
    await _showAll(tester);
    final bounds = tester.getRect(_details);
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(390));
    expect(bounds.top, greaterThanOrEqualTo(0));
    expect(bounds.bottom, lessThanOrEqualTo(844));
    for (final emoji in messageReactionEmoji) {
      expect(_filter(emoji), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    expect(fixture.writes, isEmpty);
    await _dispose(tester, fixture);
  });
}
