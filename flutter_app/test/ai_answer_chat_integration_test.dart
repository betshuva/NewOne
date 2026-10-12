import 'dart:async';
import 'dart:convert';

import 'package:betshuva/guide_table_text.dart';
import 'package:betshuva/main.dart';
import 'package:betshuva/safe_information_text.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _me = {'id': 'ai-answer-test-viewer', 'name': 'משתמש בדיקה'};
const _ordinaryId = 'ai-answer-ordinary-friend';
const _groupId = 'ai-answer-test-group';
const _sourceOne = 'https://example.org/service';
const _sourceTwo = 'https://example.net/details';
const _body = '# מידע בדיקה\n\nפרט ראשון ($_sourceOne).'
    '\n\nפרט נוסף ($_sourceTwo).';
const _filter = <String, bool>{
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true,
};

Map<String, dynamic> _presentation({String title = 'שירות ציבורי'}) => {
      'version': 1,
      'format': 'markdown',
      'citations': [
        {'index': 1, 'title': title, 'url': _sourceOne},
        {'index': 2, 'title': 'מידע נוסף', 'url': _sourceTwo},
      ],
      'references': <dynamic>[],
    };

Map<String, dynamic> _historyMessage({
  String id = 'ai-answer-history',
  String sender = kSafeInformationAiId,
  String body = _body,
  Map<String, dynamic>? presentation,
  bool camelCase = false,
}) =>
    {
      'id': id,
      'sender_id': sender,
      'sender_name': 'מידע בטוח · AI',
      'recipient_id': _me['id'],
      'group_id': _groupId,
      'body': body,
      'type': 'text',
      if (camelCase)
        'aiPresentation': presentation ?? _presentation()
      else
        'ai_presentation': presentation ?? _presentation(),
      'created_at': '2026-10-12T12:00:00Z',
      'message_status': 'read',
      'is_read': true,
    };

http.Response _json(Object data) => http.Response(jsonEncode(data), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _ChatFixture {
  _ChatFixture({required this.group, this.recipientId = kSafeInformationAiId});

  final bool group;
  final String recipientId;
  final requests = <http.Request>[];
  List<Map<String, dynamic>> history = [];
  Future<http.Response>? delayedHistory;
  Map<String, dynamic>? systemReply;
  final socket = io.io(
    'http://localhost:1',
    io.OptionBuilder().disableAutoConnect().enableForceNew().build(),
  );

  Map<String, dynamic> get groupData => {
        'id': _groupId,
        'name': 'קבוצת בדיקה',
        'role': 'member',
        'status': 'member',
        'send_permission': 'all',
        'member_count': 3,
      };

  bool _isHistory(http.Request request) =>
      request.method == 'GET' &&
      request.url.path.endsWith(
          group ? '/groups/$_groupId/messages' : '/messages/$recipientId');

  int get historyReads => requests.where(_isHistory).length;

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (_isHistory(request)) {
      return delayedHistory == null ? _json(history) : await delayedHistory!;
    }
    if (request.method == 'POST' && path.endsWith('/messages')) {
      return _json({
        'id': 'ai-answer-question',
        'status': 'read',
        if (systemReply != null) 'systemReply': systemReply,
      });
    }
    if (path.endsWith('/groups')) return _json([groupData]);
    if (path.endsWith('/groups/$_groupId')) {
      return _json({
        'members': [
          {..._me, 'role': 'member'},
          {'id': kSafeInformationAiId, 'name': 'מידע בטוח · AI'},
          {'id': _ordinaryId, 'name': 'מידע בטוח · AI'},
        ],
        'pending_invite_ids': [],
      });
    }
    if (path.endsWith('/filter-settings') ||
        path.endsWith('/receiving-filter')) {
      return _json({
        'filter': _filter,
        'personalFilter': _filter,
        'requiresChoice': false,
      });
    }
    if (path.endsWith('/filter-pin') || path.endsWith('/filter-pin/enter')) {
      return _json({'configured': false, 'unlocked': true});
    }
    if (path.contains('/listings/') && path.endsWith('/preview')) {
      return _json({'title': 'מודעת בדיקה'});
    }
    return _json({});
  });

  Widget app() => MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: group
              ? GroupChatScreen(
                  group: groupData,
                  token: 'ai-answer-test-token',
                  me: _me,
                  socket: socket,
                  embedded: true,
                )
              : ChatScreen(
                  token: 'ai-answer-test-token',
                  me: _me,
                  recipient: {
                    'id': recipientId,
                    'name': 'מידע בטוח · AI',
                  },
                  socket: socket,
                  embedded: true,
                ),
        ),
      );

  void receive({String sender = kSafeInformationAiId}) {
    socket.connected = true;
    socket.onevent({
      'data': [
        group ? 'group:message' : 'chat:message',
        {
          'id': 'ai-answer-socket',
          if (group) 'groupId': _groupId,
          'fromUserId': sender,
          'toUserId': sender == _me['id'] ? recipientId : _me['id'],
          'fromName': 'מידע בטוח · AI',
          'text': _body,
          'fileType': 'text',
          'aiPresentation': _presentation(),
          'createdAt': '2026-10-12T12:01:00Z',
        },
      ],
    });
    socket.connected = false;
  }
}

Future<void> _withChat(
  WidgetTester tester,
  _ChatFixture fixture,
  Future<void> Function() check, {
  Size viewport = const Size(1400, 1100),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(fixture.app());
      await tester.pumpAndSettle();
      await check();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      fixture.socket.connected = false;
      fixture.socket.dispose();
    }
  }, () => fixture.client);
  expect(tester.takeException(), isNull);
}

void _expectSources({String title = 'שירות ציבורי'}) {
  expect(find.byKey(const ValueKey('ai-answer-body')), findsOneWidget);
  expect(find.byKey(const ValueKey('ai-answer-sources')), findsOneWidget);
  final first = find.byKey(const ValueKey('ai-source-card-1'));
  final second = find.byKey(const ValueKey('ai-source-card-2'));
  expect(first, findsOneWidget);
  expect(second, findsOneWidget);
  expect(
      find.descendant(of: first, matching: find.text(title)), findsOneWidget);
  expect(find.descendant(of: second, matching: find.text('מידע נוסף')),
      findsOneWidget);
}

Future<void> _tapAnswerUrl(WidgetTester tester, String url) async {
  final paragraphs = find.descendant(
      of: find.byType(SafeInformationText), matching: find.byType(RichText));
  for (final element in paragraphs.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    final start = paragraph.text.toPlainText().indexOf(url);
    if (start < 0) continue;
    await tester.ensureVisible(find.byWidget(element.widget));
    await tester.pumpAndSettle();
    final box = paragraph
        .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 5))
        .first;
    await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
    // Web chat bubbles also handle double-tap to copy their text. Let that
    // recognizer's timer expire so the child link receives its single tap.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    return;
  }
  fail('The AI answer did not retain its legacy URL: $url');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  for (final group in [false, true]) {
    final kind = group ? 'group' : 'private';

    testWidgets(
        '$kind history refresh and cached reopen retain source metadata',
        (tester) async {
      final fixture = _ChatFixture(group: group)
        ..history = [_historyMessage(camelCase: true)];
      await _withChat(tester, fixture, () async {
        _expectSources();

        final priorReads = fixture.historyReads;
        fixture.history = [
          _historyMessage(presentation: _presentation(title: 'מקור מעודכן')),
        ];
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(fixture.historyReads, greaterThan(priorReads));
        _expectSources(title: 'מקור מעודכן');
        expect(find.text('שירות ציבורי'), findsNothing);

        // Hold the next REST request: the reopened view must use its persisted
        // history, including metadata, before a fresh response becomes available.
        final pendingHistory = Completer<http.Response>();
        fixture.delayedHistory = pendingHistory.future;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        try {
          await tester.pumpWidget(fixture.app());
          await tester.pumpAndSettle();
          _expectSources(title: 'מקור מעודכן');
        } finally {
          pendingHistory.complete(_json(fixture.history));
          fixture.delayedHistory = null;
          await tester.pumpAndSettle();
        }
        _expectSources(title: 'מקור מעודכן');
      });
    });

    testWidgets(
        '$kind Socket delivers source metadata without a history reload',
        (tester) async {
      final fixture = _ChatFixture(group: group);
      await _withChat(tester, fixture, () async {
        expect(find.byType(SafeInformationText), findsNothing);
        final priorReads = fixture.historyReads;
        fixture.receive();
        await tester.pumpAndSettle();
        _expectSources();
        expect(fixture.historyReads, priorReads);
      });
    });

    testWidgets(
        '$kind ordinary sender cannot become AI through name or metadata',
        (tester) async {
      final fixture = _ChatFixture(group: group, recipientId: _ordinaryId)
        ..history = [_historyMessage(sender: _ordinaryId)];
      await _withChat(tester, fixture, () async {
        expect(find.byType(SafeInformationText), findsNothing);
        expect(find.byKey(const ValueKey('ai-answer-sources')), findsNothing);
        expect(find.byKey(const ValueKey('ai-source-card-1')), findsNothing);
        expect(find.text('שירות ציבורי'), findsNothing);
        expect(find.text(_body), findsOneWidget);
      });
    });

    testWidgets(
        '$kind legacy URLs stay actionable without inventing source cards',
        (tester) async {
      final fixture = _ChatFixture(group: group)
        ..history = [_historyMessage()..remove('ai_presentation')];
      await _withChat(tester, fixture, () async {
        expect(find.byType(SafeInformationText), findsOneWidget);
        expect(find.byKey(const ValueKey('ai-answer-sources')), findsNothing);
        expect(find.byKey(const ValueKey('ai-source-card-1')), findsNothing);
        expect(find.text('שירות ציבורי'), findsNothing);
        await _tapAnswerUrl(tester, _sourceOne);
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('חזרה לבתשובה'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      });
    });

    testWidgets('$kind outgoing user metadata does not use the AI renderer',
        (tester) async {
      final fixture = _ChatFixture(group: group)
        ..history = [_historyMessage(sender: _me['id']!)];
      await _withChat(tester, fixture, () async {
        expect(find.byType(SafeInformationText), findsNothing);
        expect(find.byKey(const ValueKey('ai-source-card-1')), findsNothing);
        fixture.receive(sender: _me['id']!);
        await tester.pumpAndSettle();
        expect(find.byType(SafeInformationText), findsNothing);
        expect(find.byKey(const ValueKey('ai-answer-sources')), findsNothing);
      });
    });

    testWidgets('$kind source card asks for external navigation confirmation',
        (tester) async {
      final fixture = _ChatFixture(group: group)..history = [_historyMessage()];
      await _withChat(tester, fixture, () async {
        final second = find.byKey(const ValueKey('ai-source-card-2'));
        await tester.ensureVisible(second);
        await tester.pumpAndSettle();
        await tester.tap(second);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);
        expect(find.text('ישראל מבקש לעצור רגע'), findsOneWidget);
        expect(find.descendant(of: dialog, matching: find.text('example.net')),
            findsOneWidget);
        expect(find.descendant(of: dialog, matching: find.text('example.org')),
            findsNothing);
        await tester.tap(find.text('חזרה לבתשובה'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        _expectSources();
      });
    });
  }

  testWidgets(
      'HTTP systemReply normalizes source metadata before history polling',
      (tester) async {
    final fixture = _ChatFixture(group: false)
      ..systemReply = {
        'id': 'ai-answer-http-reply',
        'fromUserId': kSafeInformationAiId,
        'text': _body,
        'fileType': 'text',
        'aiPresentation': _presentation(),
        'createdAt': '2026-10-12T12:01:00Z',
      };
    await _withChat(tester, fixture, () async {
      final priorReads = fixture.historyReads;
      await tester.enterText(find.byType(TextField), 'מהו השירות?');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      _expectSources();
      expect(fixture.historyReads, priorReads);
      final sent = fixture.requests.where((request) =>
          request.method == 'POST' && request.url.path.endsWith('/messages'));
      expect(sent, hasLength(1));
      expect(jsonDecode(sent.single.body),
          containsPair('toUserId', kSafeInformationAiId));
    });
  });

  testWidgets(
      'Israel guide keeps table rendering even with AI presentation data',
      (tester) async {
    const table = '| שם | טלפון |\n|---|---|\n| שירות | 0501234567 |';
    final fixture = _ChatFixture(group: false, recipientId: kSystemGuideId)
      ..history = [_historyMessage(sender: kSystemGuideId, body: table)];
    await _withChat(tester, fixture, () async {
      expect(find.byType(GuideTableText), findsOneWidget);
      expect(find.text('0501234567'), findsOneWidget);
      expect(find.byType(SafeInformationText), findsNothing);
      expect(find.byKey(const ValueKey('ai-answer-sources')), findsNothing);
    });
  });

  testWidgets('AI source cards preserve internal marketplace cards',
      (tester) async {
    const listing = '11111111-1111-4111-8111-111111111111';
    final fixture = _ChatFixture(group: false)
      ..history = [
        _historyMessage(body: '$_body\n\nbetshuva://listing/$listing')
      ];
    await _withChat(tester, fixture, () async {
      _expectSources();
      expect(find.text('מודעת בדיקה'), findsOneWidget);
      expect(find.text('צפה במודעה'), findsOneWidget);
      expect(find.textContaining('betshuva://listing/'), findsNothing);
      expect(
          fixture.requests.where((request) =>
              request.url.path.endsWith('/listings/$listing/preview')),
          hasLength(1));
    });
  });

  testWidgets('actual AI chat at 1440px places sources left of the answer',
      (tester) async {
    final fixture = _ChatFixture(group: false)..history = [_historyMessage()];
    await _withChat(tester, fixture, () async {
      _expectSources();
      final body = tester.getRect(find.byKey(const ValueKey('ai-answer-body')));
      final sources =
          tester.getRect(find.byKey(const ValueKey('ai-answer-sources')));
      expect(sources.right, lessThan(body.left));
      expect(sources.top, closeTo(body.top, 0.1));
      expect(body.right, lessThanOrEqualTo(1440));
      expect(sources.left, greaterThanOrEqualTo(0));
    }, viewport: const Size(1440, 1100));
  });

  testWidgets('actual AI chat at 390px places sources below the answer',
      (tester) async {
    final fixture = _ChatFixture(group: false)..history = [_historyMessage()];
    await _withChat(tester, fixture, () async {
      _expectSources();
      final body = tester.getRect(find.byKey(const ValueKey('ai-answer-body')));
      final sources =
          tester.getRect(find.byKey(const ValueKey('ai-answer-sources')));
      expect(sources.top, greaterThanOrEqualTo(body.bottom));
      expect(sources.left, closeTo(body.left, 0.1));
      expect(sources.right, closeTo(body.right, 0.1));
      expect(body.right, lessThanOrEqualTo(390));
      expect(sources.left, greaterThanOrEqualTo(0));
    }, viewport: const Size(390, 1000));
  });
}
