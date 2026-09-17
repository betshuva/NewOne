import 'dart:convert';

import 'package:betshuva/app_screenshot.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _group = {
  'id': 'emoji-test-group',
  'name': 'קבוצת בדיקה',
  'status': 'member',
  'role': 'member',
  'send_permission': 'all',
};
const _uploadedUrl = '/api/uploads/emoji-test-sticker.png';
const _draft = 'טיוטה שנשמרת';
final _pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');
late List<String> _labels;

Map<String, dynamic> get _catalog => {
      'version': 3,
      'categories': [
        {
          'id': 'user-stickers',
          'title': 'מדבקות בתשובה',
          'items': List.generate(
              _labels.length,
              (index) => {
                    'label': _labels[index],
                    'url':
                        '/betshuva-app/expression-library/user-20260907/sticker-${(index + 1).toString().padLeft(2, '0')}.png',
                  }),
        },
      ],
    };

class _ChatHarness {
  final bool isGroup;
  final int catalogStatus;
  final bool allowText;
  final bool allowImages;
  final bool withHistory;
  final requests = <http.Request>[];
  final socket = io.io(
    'http://localhost:1',
    io.OptionBuilder().disableAutoConnect().enableForceNew().build(),
  );

  _ChatHarness(
      {required this.isGroup,
      this.catalogStatus = 200,
      this.allowText = true,
      this.allowImages = true,
      this.withHistory = false});

  late final client = MockClient((request) async {
    requests.add(request);
    dynamic body = <String, dynamic>{};
    final path = request.url.path;
    if (path.contains('/expression-library/user-20260907/')) {
      return http.Response.bytes(_pngBytes, 200,
          headers: {'content-type': 'image/png'});
    } else if (request.method == 'POST' && path.endsWith('/upload')) {
      body = {'url': _uploadedUrl, 'status': 'approved'};
    } else if (request.method == 'POST' && path.endsWith('/messages')) {
      body = {'id': 'emoji-sent-message', 'status': 'sent'};
    } else if (path.endsWith('/expressions/catalog')) {
      return http.Response(jsonEncode(_catalog), catalogStatus,
          headers: {'content-type': 'application/json; charset=utf-8'});
    } else if (path.endsWith('/groups')) {
      body = [_group];
    } else if (path.endsWith('/groups/emoji-test-group')) {
      body = {
        'members': [
          {'id': 'emoji-test-user', 'name': 'משתמש לבדיקה', 'role': 'member'},
        ],
      };
    } else if (path.contains('/messages/') || path.endsWith('/messages')) {
      body = withHistory
          ? [
              {
                'id': 'existing-emoji-message',
                'sender_id': 'emoji-test-recipient',
                'text': 'הודעה קיימת',
                'created_at': '2026-09-17T00:00:00Z'
              }
            ]
          : [];
    } else if (path.endsWith('/filter-settings')) {
      body = {
        'filter': {'text': allowText, 'nonHumanImages': allowImages},
        'personalFilter': {'text': allowText, 'nonHumanImages': allowImages},
        'requiresChoice': false,
      };
    } else if (path.endsWith('/receiving-filter')) {
      body = {
        'filter': {'text': allowText, 'nonHumanImages': allowImages},
      };
    }
    return http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });

  Finder get composer => find.byWidgetPredicate((widget) =>
      widget is TextField &&
      widget.decoration?.hintText ==
          (isGroup
              ? 'הודעה לקבוצה...'
              : allowText
                  ? 'כתוב הודעה...'
                  : 'הנמען אינו מקבל תוכן טקסטואלי'));

  TextEditingController controller(WidgetTester tester) =>
      tester.widget<TextField>(composer).controller!;

  List<http.Request> get sentHttpMessages => requests
      .where((request) =>
          request.method == 'POST' && request.url.path.endsWith('/messages'))
      .toList();

  List<http.Request> get uploads => requests
      .where((request) =>
          request.method == 'POST' && request.url.path.endsWith('/upload'))
      .toList();

  List<Map<String, dynamic>> get sentSocketMessages => socket.sendBuffer
      .whereType<Map>()
      .map((packet) => packet['data'])
      .whereType<List>()
      .where((data) =>
          data.isNotEmpty &&
          const ['chat:message', 'group:message'].contains(data.first))
      .map((data) => Map<String, dynamic>.from(data[1] as Map))
      .toList();

  void expectNothingSent() {
    expect(sentHttpMessages, isEmpty);
    expect(sentSocketMessages, isEmpty);
    expect(uploads, isEmpty);
  }

  void expectOneImageMessage({int sticker = 1}) {
    final filename =
        'betshuva_sticker-${sticker.toString().padLeft(2, '0')}.png';
    expect(uploads, hasLength(1));
    final uploadBody = latin1.decode(uploads.single.bodyBytes);
    expect(uploadBody, contains('name="builtinExpression"\r\n\r\ntrue'));
    expect(uploadBody, contains('filename="$filename"'));
    expect(uploadBody, contains('name="${isGroup ? 'groupId' : 'toUserId'}"'));
    expect(
        uploadBody, contains(isGroup ? _group['id']! : 'emoji-test-recipient'));
    expect(sentHttpMessages, hasLength(1));
    expect(sentSocketMessages, isEmpty,
        reason: 'Image messages must not also be emitted over the socket');
    final request = sentHttpMessages.single;
    expect(request.url.path,
        endsWith(isGroup ? '/groups/${_group['id']}/messages' : '/messages'));
    final message = jsonDecode(request.body) as Map<String, dynamic>;
    if (!isGroup) expect(message['toUserId'], 'emoji-test-recipient');
    expect(message['fileType'], 'image');
    expect(message['fileUrl'], _uploadedUrl);
    expect(message['fileName'], filename);
    expect(message['text'], isNull);
  }

  Future<void> mount(WidgetTester tester) async {
    final previousDestination = appScreenshotDestination.value;
    addTearDown(() {
      socket.dispose();
      client.close();
      appScreenshotDestination.value = previousDestination;
    });
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: isGroup
            ? GroupChatScreen(
                token: 'emoji-test-token',
                me: const {'id': 'emoji-test-user', 'name': 'משתמש לבדיקה'},
                group: Map<String, dynamic>.from(_group),
                socket: socket,
                embedded: true,
              )
            : ChatScreen(
                token: 'emoji-test-token',
                me: const {'id': 'emoji-test-user', 'name': 'משתמש לבדיקה'},
                recipient: const {
                  'id': 'emoji-test-recipient',
                  'name': 'חבר לבדיקה',
                },
                socket: socket,
                embedded: true,
              ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(composer, findsOneWidget);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }
}

Finder get _picker => find.byType(BottomSheet);
Finder get _grid =>
    find.descendant(of: _picker, matching: find.byType(SliverGrid));
Finder get _search =>
    find.descendant(of: _picker, matching: find.byType(TextField));

void _expectFlatImages(WidgetTester tester, {int count = 150}) {
  expect(find.descendant(of: _picker, matching: find.text('אימוג׳י')),
      findsOneWidget);
  expect(find.descendant(of: _picker, matching: find.byType(TabBar)),
      findsNothing);
  expect(find.descendant(of: _picker, matching: find.byType(ChoiceChip)),
      findsNothing);
  expect(find.descendant(of: _picker, matching: find.text('מדבקות בתשובה')),
      findsNothing);
  expect(find.byKey(const ValueKey('inline-emoji-1f600')), findsNothing);
  expect(_grid, findsOneWidget);
  expect(tester.widget<SliverGrid>(_grid).delegate.estimatedChildCount, count);
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byTooltip('אימוג׳י'));
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pumpAndSettle();
  _expectFlatImages(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final bundled = jsonDecode(await rootBundle
        .loadString('assets/stickers/user-catalog.json', cache: false)) as Map;
    _labels = List<String>.from(bundled['categories'][0]['labels'] as List);
    expect(_labels, hasLength(150));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final isGroup in [false, true]) {
    final chatKind = isGroup ? 'group' : 'private';

    testWidgets('$chatKind opens all 150 images and sends a selection once',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, _draft);
        await _openPicker(tester);
        app.expectNothingSent();
        expect(
            app.requests.where(
                (request) => request.url.path.endsWith('/expressions/catalog')),
            hasLength(1));
        await tester.tap(
            find.descendant(of: _picker, matching: find.text(_labels.first)));
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(_picker, findsNothing);
        expect(app.controller(tester).text, _draft);
        app.expectOneImageMessage();
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$chatKind can search and close images without changing draft',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, _draft);
        await _openPicker(tester);
        await tester.enterText(_search, _labels.last);
        await tester.pumpAndSettle();
        _expectFlatImages(tester,
            count:
                _labels.where((label) => label.contains(_labels.last)).length);
        expect(find.descendant(of: _grid, matching: find.text(_labels.last)),
            findsOneWidget);
        app.expectNothingSent();

        await tester.tap(find.byTooltip('סגירה'));
        await tester.pumpAndSettle();
        expect(app.controller(tester).text, _draft);
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$chatKind typed Unicode emoji retains normal text size',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, '😀');
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        final messages = isGroup
            ? app.sentSocketMessages
            : app.sentHttpMessages
                .map((request) =>
                    jsonDecode(request.body) as Map<String, dynamic>)
                .toList();
        expect(messages, hasLength(1));
        expect(messages.single['text'], '😀');
        expect(app.uploads, isEmpty);
        final message = tester.widget<Text>(find.text('😀'));
        expect(message.style?.fontSize, isGroup ? 15 : 14);
        await app.dispose(tester);
      }, () => app.client);
    });
  }

  for (final allowImages in [false, true]) {
    testWidgets(
        'private image picker follows image permission when text is blocked: $allowImages',
        (tester) async {
      final app = _ChatHarness(
          isGroup: false, allowText: false, allowImages: allowImages);
      await http.runWithClient(() async {
        await app.mount(tester);
        final button = tester.widget<IconButton>(find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == 'אימוג׳י'));
        expect(button.onPressed, allowImages ? isNotNull : isNull);
        if (allowImages) {
          await _openPicker(tester);
          await tester.tap(find.byTooltip('סגירה'));
          await tester.pumpAndSettle();
        }
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });
  }

  testWidgets('catalog failure still exposes all 150 images and the last sends',
      (tester) async {
    final app = _ChatHarness(isGroup: false, catalogStatus: 503);
    await http.runWithClient(() async {
      await app.mount(tester);
      await _openPicker(tester);
      await tester.enterText(_search, _labels.last);
      await tester.pumpAndSettle();
      await tester
          .tap(find.descendant(of: _grid, matching: find.text(_labels.last)));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      app.expectOneImageMessage(sticker: 150);
      await app.dispose(tester);
    }, () => app.client);
  });

  for (final viewport in [
    (size: const Size(390, 844), keyboard: 300.0),
    (size: const Size(320, 568), keyboard: 300.0),
    (size: const Size(568, 320), keyboard: 180.0),
  ]) {
    testWidgets(
        'single image list fits ${viewport.size} with the keyboard open',
        (tester) async {
      tester.view.physicalSize = viewport.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final app = _ChatHarness(isGroup: false, withHistory: true);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _openPicker(tester);
        tester.view.viewInsets = FakeViewPadding(bottom: viewport.keyboard);
        await tester.enterText(_search, _labels.first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
            tester
                .getRect(find.descendant(
                    of: _picker, matching: find.byType(CustomScrollView)))
                .bottom,
            lessThanOrEqualTo(viewport.size.height - viewport.keyboard));
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });
  }
}
