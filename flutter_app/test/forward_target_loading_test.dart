import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _retryKey = ValueKey('forward-target-retry');
const _targetPaths = [
  '/api/users',
  '/api/groups',
  '/api/users/directory',
];

String _path(http.Request request) =>
    request.url.path.replaceFirst('/betshuva-app', '');

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Object _recoveredTargets(String path) => switch (path) {
      '/api/users' => [
          {'id': 'bob', 'name': 'Bob'},
        ],
      '/api/groups' => [
          {'id': 'study', 'name': 'Study group'},
        ],
      _ => [],
    };

Future<BuildContext> _mountScreen(WidgetTester tester) async {
  late BuildContext screen;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          screen = context;
          return const SizedBox();
        }),
      ),
    ),
  );
  return screen;
}

void main() {
  testWidgets(
      'retry reloads all targets without sending or changing the message',
      (tester) async {
    final requests = <http.Request>[];
    final pending = <String, Completer<http.Response>>{};
    var retrying = false;
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method != 'GET') return _json({'id': 'sent'});
      if (!retrying) return _json({'error': 'temporary failure'}, 500);
      return (pending[_path(request)] = Completer<http.Response>()).future;
    });
    addTearDown(client.close);
    final original = <Map<String, dynamic>>[
      {'id': 'original-message', 'text': 'Keep the original message'},
    ];
    final snapshot = jsonEncode(original);
    final screen = await _mountScreen(tester);
    final result = forwardChatMessages(
      screen,
      'test-token',
      null,
      original,
      client: client,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('לא ניתן לטעון'), findsOneWidget);
    expect(find.byKey(_retryKey), findsOneWidget);
    expect(find.text('נסו שוב'), findsOneWidget);
    expect(requests.map(_path), unorderedEquals(_targetPaths));
    expect(requests.every((request) => request.method == 'GET'), isTrue);

    retrying = true;
    await tester.tap(find.byKey(_retryKey));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(pending.keys, unorderedEquals(_targetPaths));
    // The loading state can keep a disabled retry button or hide it entirely.
    if (find.byKey(_retryKey).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(_retryKey));
      await tester.pump();
    }
    expect(requests, hasLength(6));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(jsonEncode(original), snapshot);

    for (final entry in pending.entries) {
      entry.value.complete(_json(_recoveredTargets(entry.key)));
    }
    await tester.pumpAndSettle();
    final user = find.byKey(const ValueKey('forward-target-user:bob'));
    expect(user, findsOneWidget);
    expect(find.byKey(const ValueKey('forward-target-group:study')),
        findsOneWidget);
    expect(find.byKey(_retryKey), findsNothing);
    expect(find.textContaining('לא ניתן לטעון'), findsNothing);
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(jsonEncode(original), snapshot);

    await tester.tap(user);
    await tester.pumpAndSettle();
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    await tester.tap(find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
    await tester.pumpAndSettle();
    final outcome = await result;
    expect(outcome.sentCount, 1);
    expect(outcome.completedMessageIndexes, {0});
    final writes =
        requests.where((request) => request.method != 'GET').toList();
    expect(writes, hasLength(1));
    expect(_path(writes.single), '/api/messages');
    expect(jsonDecode(writes.single.body), {
      'text': 'Keep the original message',
      'toUserId': 'bob',
    });
    expect(jsonEncode(original), snapshot);
    expect(tester.takeException(), isNull);
  });

  testWidgets('malformed users do not hide groups or lose selection on retry',
      (tester) async {
    final writes = <http.Request>[];
    var recovered = false;
    final client = MockClient((request) async {
      if (request.method != 'GET') {
        writes.add(request);
        return _json({'id': 'sent'});
      }
      if (_path(request) == '/api/groups' || recovered) {
        return _json(_recoveredTargets(_path(request)));
      }
      return http.Response('not valid JSON', 200);
    });
    addTearDown(client.close);
    final screen = await _mountScreen(tester);
    final result = forwardChatMessages(
      screen,
      'test-token',
      null,
      [
        {'text': 'Forward to the group'},
      ],
      client: client,
    );
    await tester.pumpAndSettle();

    final group = find.byKey(const ValueKey('forward-target-group:study'));
    expect(group, findsOneWidget);
    expect(find.byKey(_retryKey), findsOneWidget);
    expect(find.byKey(const ValueKey('forward-target-user:bob')), findsNothing);
    expect(find.text('שגיאת תקשורת בהעברת ההודעה'), findsNothing);
    await tester.tap(group);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(group).value, isTrue);
    expect(writes, isEmpty);

    recovered = true;
    await tester.tap(find.byKey(_retryKey));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(group).value, isTrue);
    expect(
        find.byKey(const ValueKey('forward-target-user:bob')), findsOneWidget);
    expect(find.byKey(_retryKey), findsNothing);
    expect(writes, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
    await tester.pumpAndSettle();
    expect((await result).sentCount, 1);
    expect(writes, hasLength(1));
    expect(_path(writes.single), '/api/groups/study/messages');
    expect(jsonDecode(writes.single.body)['text'], 'Forward to the group');
    expect(tester.takeException(), isNull);
  });

  testWidgets('directory fallback exposes only saved contacts when users fail',
      (tester) async {
    final writes = <http.Request>[];
    final client = MockClient((request) async {
      if (request.method != 'GET') {
        writes.add(request);
        return _json({'id': 'sent'});
      }
      return switch (_path(request)) {
        '/api/users' => _json({'error': 'temporary failure'}, 500),
        '/api/users/directory' => _json([
            {'id': 'saved', 'name': 'Saved contact', 'saved': true},
            {'id': 'unsaved', 'name': 'Unsaved contact', 'saved': false},
            {'id': 'unknown', 'name': 'Unknown contact'},
          ]),
        _ => _json([]),
      };
    });
    addTearDown(client.close);
    final screen = await _mountScreen(tester);
    final result = forwardChatMessages(
      screen,
      'test-token',
      null,
      [
        {'text': 'Saved contacts only'},
      ],
      client: client,
    );
    await tester.pumpAndSettle();

    final saved = find.byKey(const ValueKey('forward-target-user:saved'));
    expect(saved, findsOneWidget);
    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(find.byKey(const ValueKey('forward-target-user:unsaved')),
        findsNothing);
    expect(find.byKey(const ValueKey('forward-target-user:unknown')),
        findsNothing);
    expect(find.text('Unsaved contact'), findsNothing);
    expect(find.text('Unknown contact'), findsNothing);
    expect(writes, isEmpty);
    await tester.tap(saved);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
    await tester.pumpAndSettle();
    expect((await result).sentCount, 1);
    expect(writes, hasLength(1));
    expect(jsonDecode(writes.single.body)['toUserId'], 'saved');
  });

  testWidgets(
      'optional directory failure does not report healthy targets as failed',
      (tester) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return _path(request) == '/api/users/directory'
          ? _json({'error': 'directory unavailable'}, 500)
          : _json(_recoveredTargets(_path(request)));
    });
    addTearDown(client.close);
    final screen = await _mountScreen(tester);
    final result = forwardChatMessages(
      screen,
      'test-token',
      null,
      [
        {'text': 'Keep unsent'},
      ],
      client: client,
    );
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('forward-target-user:bob')), findsOneWidget);
    expect(find.byKey(const ValueKey('forward-target-group:study')),
        findsOneWidget);
    expect(find.byKey(_retryKey), findsNothing);
    expect(find.textContaining('לא ניתן לטעון'), findsNothing);
    await tester.tap(find.byTooltip('ביטול העברה'));
    await tester.pumpAndSettle();
    expect((await result).cancelled, isTrue);
    expect(requests.map(_path), unorderedEquals(_targetPaths));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'failed users retry preserves previously loaded contacts and selection',
      (tester) async {
    final writes = <http.Request>[];
    var retrying = false;
    final client = MockClient((request) async {
      if (request.method != 'GET') {
        writes.add(request);
        return _json({'id': 'sent'});
      }
      final path = _path(request);
      if ((path == '/api/users' && retrying) ||
          (path == '/api/groups' && !retrying)) {
        return _json({'error': 'temporary failure'}, 500);
      }
      return _json(_recoveredTargets(path));
    });
    addTearDown(client.close);
    final screen = await _mountScreen(tester);
    final result = forwardChatMessages(
      screen,
      'test-token',
      null,
      [
        {'text': 'Preserve my recipient'},
      ],
      client: client,
    );
    await tester.pumpAndSettle();
    final user = find.byKey(const ValueKey('forward-target-user:bob'));
    expect(user, findsOneWidget);
    expect(find.byKey(_retryKey), findsOneWidget);
    await tester.tap(user);
    await tester.pumpAndSettle();

    retrying = true;
    await tester.tap(find.byKey(_retryKey));
    await tester.pumpAndSettle();
    expect(user, findsOneWidget);
    expect(tester.widget<CheckboxListTile>(user).value, isTrue);
    expect(find.byKey(const ValueKey('forward-selected-user:bob')),
        findsOneWidget);
    final group = find.byKey(const ValueKey('forward-target-group:study'));
    // The preserved selection and error notice shorten this list's viewport.
    await tester.scrollUntilVisible(
      group,
      80,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('forward-target-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(group, findsOneWidget);
    expect(find.byKey(_retryKey), findsOneWidget);
    expect(writes, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
    await tester.pumpAndSettle();
    expect((await result).sentCount, 1);
    expect(writes, hasLength(1));
    expect(jsonDecode(writes.single.body)['toUserId'], 'bob');
    expect(tester.takeException(), isNull);
  });

  testWidgets('healthy empty target lists show an empty state without retry',
      (tester) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return _json([]);
    });
    addTearDown(client.close);
    final screen = await _mountScreen(tester);
    final result = forwardChatMessages(
      screen,
      'test-token',
      null,
      [
        {'text': 'No available recipients'},
      ],
      client: client,
    );
    await tester.pumpAndSettle();
    expect(find.text('לא נמצאו משתתפים או קבוצות שניתן להעביר אליהם.'),
        findsOneWidget);
    expect(find.textContaining('לא ניתן לטעון'), findsNothing);
    expect(find.byKey(_retryKey), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.tap(find.byTooltip('ביטול העברה'));
    await tester.pumpAndSettle();
    expect((await result).cancelled, isTrue);
    expect(requests.map(_path), unorderedEquals(_targetPaths));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling a pending retry safely ignores late responses',
      (tester) async {
    final requests = <http.Request>[];
    final pending = <String, Completer<http.Response>>{};
    var retrying = false;
    final client = MockClient((request) async {
      requests.add(request);
      if (!retrying) return _json({'error': 'temporary failure'}, 500);
      return (pending[_path(request)] = Completer<http.Response>()).future;
    });
    addTearDown(client.close);
    final original = <Map<String, dynamic>>[
      {'text': 'Cancel without changing me'},
    ];
    final snapshot = jsonEncode(original);
    final screen = await _mountScreen(tester);
    final result = forwardChatMessages(
      screen,
      'test-token',
      null,
      original,
      client: client,
    );
    await tester.pumpAndSettle();
    retrying = true;
    await tester.tap(find.byKey(_retryKey));
    await tester.pump();
    expect(pending.keys, unorderedEquals(_targetPaths));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.byTooltip('ביטול העברה'));
    await tester.pumpAndSettle();
    final outcome = await result;
    expect(outcome.cancelled, isTrue);
    expect(outcome.completedMessageIndexes, isEmpty);
    for (final entry in pending.entries) {
      entry.value.complete(_json(_recoveredTargets(entry.key)));
    }
    await tester.pumpAndSettle();

    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.byKey(_retryKey), findsNothing);
    expect(requests, hasLength(6));
    expect(requests.every((request) => request.method == 'GET'), isTrue);
    expect(jsonEncode(original), snapshot);
    expect(tester.takeException(), isNull);
  });
}
