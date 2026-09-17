import 'dart:convert';

import 'package:betshuva/app_screenshot.dart';
import 'package:betshuva/inline_custom_emoji.dart';
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
final _labels = List.generate(150, (index) => 'אימוג׳י לבדיקה ${index + 1}');
var _bundledCatalogReads = 0;
const _standardCatalog = [
  {
    'emoji': '😀',
    'category': 'פנים ורגשות',
    'label_he': 'חיוך',
    'twemoji_code': '1f600',
  },
  {
    'emoji': '👍',
    'category': 'מחוות',
    'label_he': 'אגודל למעלה',
    'twemoji_code': '1f44d',
  },
  {
    'emoji': '❤️',
    'category': 'לבבות',
    'label_he': 'לב אדום',
    'twemoji_code': '2764',
  },
];
const _svgFixture =
    '<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" '
    'viewBox="0 0 36 36"><circle cx="18" cy="18" r="16" fill="#ffcc4d"/></svg>';

Map<String, dynamic> get _bundledCatalog => {
      'version': 3,
      'categories': [
        {
          'id': 'user-stickers',
          'title': 'מדבקות בתשובה',
          'path': 'user-20260907',
          'prefix': 'sticker',
          'extension': 'png',
          'labels': _labels,
        },
      ],
    };

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
  final List<Map<String, dynamic>>? history;
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
      this.withHistory = false,
      this.history});

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
      body = history ??
          (withHistory
              ? [
                  {
                    'id': 'existing-emoji-message',
                    'sender_id': 'emoji-test-recipient',
                    'body': 'הודעה קיימת',
                    'created_at': '2026-09-17T00:00:00Z'
                  }
                ]
              : []);
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

  void expectOneTextMessage(String wireText) {
    expect(uploads, isEmpty);
    late Map<String, dynamic> message;
    if (isGroup) {
      expect(sentSocketMessages, hasLength(1));
      expect(sentHttpMessages, isEmpty);
      message = sentSocketMessages.single;
      expect(message['groupId'], _group['id']);
    } else {
      expect(sentHttpMessages, hasLength(1));
      expect(sentSocketMessages, isEmpty);
      final request = sentHttpMessages.single;
      expect(request.url.path, endsWith('/messages'));
      message = jsonDecode(request.body) as Map<String, dynamic>;
      expect(message['toUserId'], 'emoji-test-recipient');
    }
    expect(message['text'], wireText);
    expect(message['fileType'], isNull);
    expect(message['fileUrl'], isNull);
    expect(message['fileName'], isNull);
    expect(message['stickerId'], isNull);
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
Finder get _customTab => find.byKey(const ValueKey('expression-custom-tab'));
Finder get _standardTab =>
    find.byKey(const ValueKey('expression-standard-tab'));

void _expectFlatImages(WidgetTester tester, {int count = 150}) {
  expect(find.descendant(of: _picker, matching: find.text('אימוג׳י')),
      findsOneWidget);
  expect(find.descendant(of: _picker, matching: find.byType(TabBar)),
      findsNothing);
  expect(find.descendant(of: _picker, matching: find.byType(ChoiceChip)),
      findsNWidgets(2));
  expect(tester.widget<ChoiceChip>(_customTab).selected, isTrue);
  expect(tester.widget<ChoiceChip>(_standardTab).selected, isFalse);
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

Future<void> _selectEmoji(WidgetTester tester, int id) async {
  await tester
      .tap(find.descendant(of: _grid, matching: find.text(_labels[id - 1])));
  await tester.pumpAndSettle();
  expect(_picker, findsNothing);
}

Future<void> _openStandardTab(WidgetTester tester) async {
  await tester.ensureVisible(_standardTab);
  await tester.pumpAndSettle();
  await tester.tap(_standardTab);
  await tester.pumpAndSettle();
  expect(tester.widget<ChoiceChip>(_standardTab).selected, isTrue);
  expect(tester.widget<ChoiceChip>(_customTab).selected, isFalse);
  expect(find.byKey(const ValueKey('inline-emoji-1f600')), findsOneWidget);
  expect(find.descendant(of: _picker, matching: find.text('רגילים')),
      findsOneWidget);
}

Future<void> _selectStandardEmoji(WidgetTester tester, String code) async {
  await tester.tap(find.byKey(ValueKey('inline-emoji-$code')));
  await tester.pumpAndSettle();
  expect(_picker, findsNothing);
}

void _expectSmallEmoji(WidgetTester tester, Finder scope, int id) {
  final image = find.descendant(
    of: scope,
    matching: find.byKey(ValueKey('inline-custom-emoji-$id')),
  );
  expect(image, findsOneWidget);
  final size = tester.getSize(image);
  expect(size.width, inInclusiveRange(18.0, 24.0));
  expect(size.height, inInclusiveRange(18.0, 24.0));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _bundledCatalogReads = 0;
    rootBundle.evict('assets/stickers/user-catalog.json');
    rootBundle.evict('assets/twemoji/emoji_allowlist.json');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // The Chrome test host does not serve project assets. Exercise the real
    // fallback parser with a bundled-catalog fixture, independent of that host.
    messenger.setMockMessageHandler('flutter/assets', (message) {
      final key = const StringCodec().decodeMessage(message);
      if (key == 'assets/stickers/user-catalog.json') {
        _bundledCatalogReads++;
        return Future.value(ByteData.sublistView(
            Uint8List.fromList(utf8.encode(jsonEncode(_bundledCatalog)))));
      }
      if (key == 'assets/twemoji/emoji_allowlist.json') {
        return Future.value(ByteData.sublistView(
            Uint8List.fromList(utf8.encode(jsonEncode(_standardCatalog)))));
      }
      if (key?.startsWith('assets/twemoji/svg/') ?? false) {
        return Future.value(
            ByteData.sublistView(Uint8List.fromList(utf8.encode(_svgFixture))));
      }
      return messenger.delegate.send('flutter/assets', message) ??
          Future.value(null);
    });
  });
  tearDown(() {
    rootBundle.evict('assets/stickers/user-catalog.json');
    rootBundle.evict('assets/twemoji/emoji_allowlist.json');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  for (final isGroup in [false, true]) {
    final chatKind = isGroup ? 'group' : 'private';

    testWidgets(
        '$chatKind inserts a small emoji at the caret and sends only on explicit send',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        const draft = 'שלום abc עולם';
        await tester.enterText(app.composer, draft);
        final controller = app.controller(tester);
        expect(controller, isA<InlineEmojiController>());
        controller.selection = const TextSelection.collapsed(offset: 5);
        await _openPicker(tester);
        app.expectNothingSent();
        expect(
            app.requests.where(
                (request) => request.url.path.endsWith('/expressions/catalog')),
            hasLength(1));
        await _selectEmoji(tester, 1);
        final raw = 'שלום ${inlineEmojiCharacter(1)}abc עולם';
        expect(controller.text, raw);
        expect(controller.selection, const TextSelection.collapsed(offset: 6));
        app.expectNothingSent();
        _expectSmallEmoji(tester, app.composer, 1);
        expect(encodeInlineEmojiText(raw), 'שלום [[bt-emoji:001]]abc עולם');

        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage('שלום [[bt-emoji:001]]abc עולם');
        expect(controller.text, isEmpty);
        _expectSmallEmoji(tester, find.byType(InlineEmojiText), 1);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$chatKind can search and close images without changing draft',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        final draft = '$_draft ${inlineEmojiCharacter(1)}';
        await tester.enterText(app.composer, draft);
        app.controller(tester).selection = const TextSelection(
          baseOffset: 5,
          extentOffset: 1,
        );
        final before = app.controller(tester).value;
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
        expect(app.controller(tester).value, before);
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind restores Unicode emoji at the caret beside custom emoji without autosending',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        final draft = 'שלום abc ${inlineEmojiCharacter(1)} סוף';
        await tester.enterText(app.composer, draft);
        final controller = app.controller(tester);
        controller.selection = const TextSelection.collapsed(offset: 5);

        await _openPicker(tester);
        await _openStandardTab(tester);
        app.expectNothingSent();
        await _selectStandardEmoji(tester, '1f600');

        expect(controller.text, 'שלום 😀abc ${inlineEmojiCharacter(1)} סוף');
        expect(controller.selection, const TextSelection.collapsed(offset: 7));
        _expectSmallEmoji(tester, app.composer, 1);
        app.expectNothingSent();

        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage('שלום 😀abc [[bt-emoji:001]] סוף');
        expect(controller.text, isEmpty);
        _expectSmallEmoji(tester, find.byType(InlineEmojiText), 1);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind switches both emoji lists and replaces a reversed selection with Unicode',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        final draft = 'לפני ${inlineEmojiCharacter(2)} להחליף אחרי';
        final start = draft.indexOf('להחליף');
        final end = start + 'להחליף'.length;
        await tester.enterText(app.composer, draft);
        final controller = app.controller(tester);
        controller.selection =
            TextSelection(baseOffset: end, extentOffset: start);

        await _openPicker(tester);
        await _openStandardTab(tester);
        await tester.tap(_customTab);
        await tester.pumpAndSettle();
        _expectFlatImages(tester);
        await tester.enterText(_search, _labels.last);
        await tester.pumpAndSettle();
        _expectFlatImages(tester, count: 1);
        expect(find.descendant(of: _grid, matching: find.text(_labels.last)),
            findsOneWidget);

        await _openStandardTab(tester);
        await tester.enterText(_search, 'לב אדום');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('inline-emoji-1f600')), findsNothing);
        expect(find.byKey(const ValueKey('inline-emoji-2764')), findsOneWidget);
        app.expectNothingSent();
        await _selectStandardEmoji(tester, '2764');

        expect(controller.text,
            '${draft.substring(0, start)}❤️${draft.substring(end)}');
        expect(controller.selection,
            TextSelection.collapsed(offset: start + '❤️'.length));
        _expectSmallEmoji(tester, app.composer, 2);
        app.expectNothingSent();

        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage('לפני [[bt-emoji:002]] ❤️ אחרי');
        expect(controller.text, isEmpty);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind replaces a reversed selection and preserves the caret on reopening',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        const draft = 'לפני להחליף אחרי';
        final start = draft.indexOf('להחליף');
        final end = start + 'להחליף'.length;
        await tester.enterText(app.composer, draft);
        final controller = app.controller(tester);
        controller.selection =
            TextSelection(baseOffset: end, extentOffset: start);
        await _openPicker(tester);
        await _selectEmoji(tester, 2);
        final first =
            '${draft.substring(0, start)}${inlineEmojiCharacter(2)}${draft.substring(end)}';
        expect(controller.text, first);
        expect(
            controller.selection, TextSelection.collapsed(offset: start + 1));
        app.expectNothingSent();

        await _openPicker(tester);
        await tester.enterText(_search, _labels.last);
        await tester.pumpAndSettle();
        await _selectEmoji(tester, 150);
        final expected =
            '${draft.substring(0, start)}${inlineEmojiCharacter(2)}${inlineEmojiCharacter(150)}${draft.substring(end)}';
        expect(controller.text, expected);
        expect(
            controller.selection, TextSelection.collapsed(offset: start + 2));
        _expectSmallEmoji(tester, app.composer, 2);
        _expectSmallEmoji(tester, app.composer, 150);
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind hydrates an own text emoji for editing and patches encoded text',
        (tester) async {
      const original = 'עריכה [[bt-emoji:001]] המשך';
      final app = _ChatHarness(isGroup: isGroup, history: [
        {
          'id': 'existing-own-emoji',
          'sender_id': 'emoji-test-user',
          'sender_name': 'משתמש לבדיקה',
          'type': 'text',
          'body': original,
          'created_at': '2026-09-17T00:00:00Z',
        },
      ]);
      await http.runWithClient(() async {
        await app.mount(tester);
        _expectSmallEmoji(tester, find.byType(InlineEmojiText), 1);
        await tester
            .longPress(find.byKey(const ValueKey('inline-custom-emoji-1')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: 'The existing-message actions must fit before editing');
        await tester.tap(find.text('ערוך הודעה'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: 'Loading the existing emoji into the editor must fit');
        final controller = app.controller(tester);
        final raw = 'עריכה ${inlineEmojiCharacter(1)} המשך';
        expect(controller.text, raw);
        controller.selection = TextSelection.collapsed(offset: raw.length);
        await _openPicker(tester);
        await _selectEmoji(tester, 2);
        expect(controller.text, '$raw${inlineEmojiCharacter(2)}');
        app.expectNothingSent();
        expect(app.requests.where((request) => request.method == 'PATCH'),
            isEmpty);

        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        final patches =
            app.requests.where((request) => request.method == 'PATCH').toList();
        expect(patches, hasLength(1));
        expect(
            patches.single.url.path, endsWith('/messages/existing-own-emoji'));
        expect(jsonDecode(patches.single.body),
            {'body': '$original[[bt-emoji:002]]'});
        app.expectNothingSent();
        expect(controller.text, isEmpty);
        _expectSmallEmoji(tester, find.byType(InlineEmojiText), 1);
        _expectSmallEmoji(tester, find.byType(InlineEmojiText), 2);
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

  for (final policy in [
    (allowText: false, allowImages: false),
    (allowText: false, allowImages: true),
    (allowText: true, allowImages: false),
  ]) {
    testWidgets('private inline emoji follows text permission: $policy',
        (tester) async {
      final app = _ChatHarness(
          isGroup: false,
          allowText: policy.allowText,
          allowImages: policy.allowImages);
      await http.runWithClient(() async {
        await app.mount(tester);
        final button = tester.widget<IconButton>(find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == 'אימוג׳י'));
        expect(button.onPressed, policy.allowText ? isNotNull : isNull);
        if (policy.allowText) {
          await _openPicker(tester);
          await _selectEmoji(tester, 1);
          expect(app.controller(tester).text, inlineEmojiCharacter(1));
        }
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });
  }

  testWidgets(
      'catalog failure still exposes all 150 images and inserts the last as text',
      (tester) async {
    final app = _ChatHarness(isGroup: false, catalogStatus: 503);
    await http.runWithClient(() async {
      await app.mount(tester);
      await _openPicker(tester);
      expect(_bundledCatalogReads, 1);
      await tester.enterText(_search, _labels.last);
      await tester.pumpAndSettle();
      await _selectEmoji(tester, 150);
      expect(app.controller(tester).text, inlineEmojiCharacter(150));
      app.expectNothingSent();
      _expectSmallEmoji(tester, app.composer, 150);
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      app.expectOneTextMessage('[[bt-emoji:150]]');
      _expectSmallEmoji(tester, find.byType(InlineEmojiText), 150);
      await app.dispose(tester);
    }, () => app.client);
  });

  for (final viewport in [
    (size: const Size(390, 844), keyboard: 300.0),
    (size: const Size(320, 568), keyboard: 300.0),
    (size: const Size(568, 320), keyboard: 180.0),
  ]) {
    testWidgets('both emoji lists fit ${viewport.size} with the keyboard open',
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
        await tester.ensureVisible(_standardTab);
        await tester.pumpAndSettle();
        await tester.tap(_standardTab);
        await tester.pumpAndSettle();
        expect(tester.widget<ChoiceChip>(_standardTab).selected, isTrue);
        final standardScroll = find
            .descendant(of: _picker, matching: find.byType(Scrollable))
            .first;
        await tester.scrollUntilVisible(
          find.descendant(of: _search, matching: find.byType(EditableText)),
          60,
          scrollable: standardScroll,
        );
        await tester.pumpAndSettle();
        await tester.enterText(_search, 'חיוך');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
            tester
                .getRect(find.descendant(
                    of: _picker, matching: find.byType(CustomScrollView)))
                .bottom,
            lessThanOrEqualTo(viewport.size.height - viewport.keyboard));
        app.expectNothingSent();
        final smile = find.byKey(const ValueKey('inline-emoji-1f600'));
        await tester.scrollUntilVisible(smile, 60, scrollable: standardScroll);
        await tester.pumpAndSettle();
        await tester.tap(smile);
        await tester.pumpAndSettle();
        expect(_picker, findsNothing);
        expect(app.controller(tester).text, '😀');
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });
  }
}
