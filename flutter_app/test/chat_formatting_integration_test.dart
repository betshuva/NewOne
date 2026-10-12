import 'dart:convert';

import 'package:betshuva/chat_text_formatting.dart';
import 'package:betshuva/inline_custom_emoji.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _me = {'id': 'format-user', 'name': 'משתמש לבדיקה'};
const _recipient = {'id': 'format-recipient', 'name': 'חבר לבדיקה'};
const _group = {
  'id': 'format-group',
  'name': 'קבוצת בדיקה',
  'status': 'member',
  'role': 'member',
  'send_permission': 'all',
};

class _FormattingAssets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == 'assets/twemoji/emoji_allowlist.json') {
      return ByteData.sublistView(Uint8List.fromList(utf8.encode('[]')));
    }
    return rootBundle.load(key);
  }
}

class _Chat {
  _Chat(
      {required this.isGroup,
      this.allowText = true,
      this.history = const [],
      this.fontFamily});

  final bool isGroup;
  final bool allowText;
  final List<Map<String, dynamic>> history;
  final String? fontFamily;
  final requests = <http.Request>[];
  final socket = io.io(
    'http://localhost:1',
    io.OptionBuilder().disableAutoConnect().enableForceNew().build(),
  );

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    Object body = <String, dynamic>{};
    if (request.method == 'POST' && path.endsWith('/messages')) {
      body = {'id': 'sent-format-message', 'status': 'sent'};
    } else if (request.method == 'PATCH') {
      body = {'ok': true};
    } else if (path.endsWith('/groups/format-group')) {
      body = {
        'members': [
          {..._me, 'role': 'member'},
          {..._recipient, 'role': 'member'},
        ],
      };
    } else if (path.endsWith('/messages') || path.contains('/messages/')) {
      body = history;
    } else if (path.endsWith('/filter-settings')) {
      body = {
        'filter': {'text': allowText, 'nonHumanImages': true},
        'personalFilter': {'text': allowText, 'nonHumanImages': true},
        'requiresChoice': false,
      };
    } else if (path.endsWith('/receiving-filter')) {
      body = {
        'filter': {'text': allowText, 'nonHumanImages': true},
      };
    } else if (path.endsWith('/users') || path.endsWith('/users/directory')) {
      body = [
        {'id': 'forward-recipient', 'name': 'נמען להעברה', 'saved': true},
      ];
    } else if (path.endsWith('/groups')) {
      body = [_group];
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

  FocusNode focusNode(WidgetTester tester) =>
      tester.widget<TextField>(composer).focusNode!;

  List<http.Request> get writes => requests
      .where((request) =>
          request.method == 'POST' && request.url.path.endsWith('/messages'))
      .toList();

  List<Map<String, dynamic>> get socketMessages => socket.sendBuffer
      .whereType<Map>()
      .map((packet) => packet['data'])
      .whereType<List>()
      .where((data) =>
          data.isNotEmpty &&
          ['chat:message', 'group:message'].contains(data.first))
      .map((data) => Map<String, dynamic>.from(data[1] as Map))
      .toList();

  Future<void> mount(WidgetTester tester) async {
    addTearDown(socket.dispose);
    addTearDown(client.close);
    await tester.pumpWidget(MaterialApp(
      theme: fontFamily == null ? null : ThemeData(fontFamily: fontFamily),
      home: DefaultAssetBundle(
        bundle: _FormattingAssets(),
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: isGroup
              ? GroupChatScreen(
                  token: 'format-token',
                  me: _me,
                  group: Map<String, dynamic>.from(_group),
                  socket: socket,
                  embedded: true,
                )
              : ChatScreen(
                  token: 'format-token',
                  me: _me,
                  recipient: _recipient,
                  socket: socket,
                  embedded: true,
                ),
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

  void expectSentText(String text) {
    if (isGroup) {
      expect(writes, isEmpty);
      expect(socketMessages, hasLength(1));
      expect(socketMessages.single['groupId'], _group['id']);
      expect(socketMessages.single['text'], text);
    } else {
      expect(socketMessages, isEmpty);
      expect(writes, hasLength(1));
      final body = jsonDecode(writes.single.body) as Map;
      expect(body['toUserId'], _recipient['id']);
      expect(body['text'], text);
    }
  }
}

Finder get _toolbar => find.byKey(const ValueKey('chat-formatting-toolbar'));

Finder _formatButton(String name) => find.byKey(ValueKey('chat-format-$name'));

Finder _message(String rawText) => find.byWidgetPredicate(
    (widget) => widget is InlineEmojiText && widget.text == rawText);

void _viewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _draft(WidgetTester tester, _Chat app, String text,
    {int start = 0, int? end}) async {
  app.focusNode(tester).requestFocus();
  app.controller(tester).value = TextEditingValue(
    text: text,
    selection:
        TextSelection(baseOffset: start, extentOffset: end ?? text.length),
  );
  await tester.pump();
}

Future<void> _tapFormat(WidgetTester tester, String name) async {
  final button = _formatButton(name);
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
}

Finder get _colorPicker => find.byKey(const ValueKey('chat-color-picker'));

String _visibleText(String raw) =>
    parseChatFormattedText(inlineEmojiPlainText(raw))
        .map((run) => run.text)
        .join();

String _selectedText(TextEditingController controller) =>
    _visibleText(controller.selection.textInside(controller.text));

Future<void> _openColorPicker(WidgetTester tester, String target) async {
  await _tapFormat(tester, target);
  await tester.pumpAndSettle();
  expect(_colorPicker, findsOneWidget);
  expect(find.byKey(const ValueKey('chat-color-preview')), findsOneWidget);
}

Future<void> _pickColor(WidgetTester tester, String target, int? rgb) async {
  await _openColorPicker(tester, target);
  final choice = rgb == null
      ? find.byKey(const ValueKey('chat-color-clear'))
      : find.byKey(ValueKey(
          'chat-color-swatch-${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}'));
  await tester.ensureVisible(choice);
  await tester.pumpAndSettle();
  await tester.tap(choice);
  await tester.pumpAndSettle();
  expect(_colorPicker, findsNothing);
}

void _expectColoredText(WidgetTester tester, Finder scope, String selected,
    {int? foreground, int? background, bool bold = false}) {
  final spans = _styledText(tester, scope);
  final selectedSpans = spans.where((part) => part.text.contains(selected));
  expect(selectedSpans, isNotEmpty);
  for (final part in selectedSpans) {
    if (foreground != null) {
      expect(part.style.color, Color(0xFF000000 | foreground));
    }
    expect(part.style.backgroundColor,
        background == null ? null : Color(0xFF000000 | background));
    if (bold) expect(part.style.fontWeight, FontWeight.bold);
  }
}

TextSelection _logicalSelection(TextEditingController controller) {
  int offset(int at) => at < 0
      ? at
      : inlineEmojiPlainText(controller.text.substring(0, at)).length;
  return TextSelection(
      baseOffset: offset(controller.selection.baseOffset),
      extentOffset: offset(controller.selection.extentOffset));
}

List<({String text, TextStyle style})> _styledText(
    WidgetTester tester, Finder scope) {
  final result = <({String text, TextStyle style})>[];
  void visit(InlineSpan span, TextStyle inherited) {
    final style = inherited.merge(span.style);
    if (span is TextSpan) {
      if (span.text?.isNotEmpty ?? false) {
        result.add((text: span.text!, style: style));
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    }
  }

  for (final text in tester.widgetList<RichText>(find.descendant(
      of: scope,
      matching: find.byWidgetPredicate((widget) => widget is RichText)))) {
    visit(text.text, const TextStyle());
  }
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (kIsWeb) return;
    await (FontLoader('ChatSearchHebrew')
          ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf')))
        .load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final isGroup in [false, true]) {
    final kind = isGroup ? 'group' : 'private';

    testWidgets('$kind searches a word split across colored text runs',
        (tester) async {
      const body = 'ש[[bt-style:fg=1976D2]]לו[[/bt-style]]ם לכולם';
      final app = _Chat(
          isGroup: isGroup,
          fontFamily: kIsWeb ? null : 'ChatSearchHebrew',
          history: [
            {
              'id': 'partly-colored-search',
              'sender_id': _recipient['id'],
              'sender_name': _recipient['name'],
              'type': 'text',
              'body': body,
              'created_at': '2026-10-11T12:00:00Z',
            },
            {
              'id': 'unrelated-search',
              'sender_id': _recipient['id'],
              'sender_name': _recipient['name'],
              'type': 'text',
              'body': 'יום טוב לכולם',
              'created_at': '2026-10-11T12:01:00Z',
            },
          ]);
      await http.runWithClient(() async {
        await app.mount(tester);
        final menu = find.byWidgetPredicate((widget) =>
            widget is PopupMenuButton<String> &&
            widget.tooltip == (isGroup ? 'אפשרויות קבוצה' : 'אפשרויות שיחה'));
        if (kIsWeb) {
          // Ahem overflows long menu labels and browser font loading stalls in
          // this harness. Native tests click the real menu with Hebrew fonts.
          tester.widget<PopupMenuButton<String>>(menu).onSelected!('search');
        } else {
          await tester.tap(menu);
          await tester.pumpAndSettle();
          await tester.tap(find.text('חיפוש בהודעות'));
        }
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        expect(dialog, findsOneWidget);
        final searchField =
            find.descendant(of: dialog, matching: find.byType(TextField));
        await tester.enterText(searchField, 'שלום');
        await tester.pumpAndSettle();
        final result = find.descendant(of: dialog, matching: _message(body));
        expect(result, findsOneWidget);
        expect(find.descendant(of: dialog, matching: find.byType(ListTile)),
            findsOneWidget);
        final spans = _styledText(tester, result);
        expect(spans.map((part) => part.text).join(), 'שלום לכולם');
        expect(spans.any((part) => part.text.contains('bt-style')), isFalse);
        expect(
            spans.any((part) =>
                part.text == 'לו' &&
                part.style.color == const Color(0xFF1976D2)),
            isTrue);
        await tester
            .tap(find.descendant(of: dialog, matching: find.text('סגור')));
        await tester.pumpAndSettle();
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$kind color picker applies clears and cancels with selection retained',
        (tester) async {
      final app = _Chat(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _draft(tester, app, 'שלום עולם', start: 4, end: 0);
        final controller = app.controller(tester);
        final original = controller.value;
        await _openColorPicker(tester, 'foreground');
        expect(controller.value, original);
        await tester.tap(find.byKey(const ValueKey('chat-color-cancel')));
        await tester.pumpAndSettle();
        expect(controller.value, original);
        expect(app.focusNode(tester).hasFocus, isTrue);

        await _openColorPicker(tester, 'background');
        const newerDraft = TextEditingValue(
            text: 'טיוטה חדשה', selection: TextSelection.collapsed(offset: 3));
        controller.value = newerDraft;
        await tester.pump();
        await tester
            .tap(find.byKey(const ValueKey('chat-color-swatch-FFF59D')));
        await tester.pumpAndSettle();
        expect(controller.value, newerDraft,
            reason: 'A palette result must not overwrite a changed draft');
        await _draft(tester, app, 'שלום עולם', start: 4, end: 0);

        await _pickColor(tester, 'foreground', 0x1976D2);
        var runs =
            parseChatFormattedText(inlineEmojiPlainText(controller.text));
        expect(runs.where((run) => run.text == 'שלום').single.foregroundRgb,
            0x1976D2);
        expect(_visibleText(controller.text), 'שלום עולם');
        expect(_selectedText(controller), 'שלום');
        expect(controller.selection.baseOffset,
            greaterThan(controller.selection.extentOffset));
        expect(app.focusNode(tester).hasFocus, isTrue);

        await _pickColor(tester, 'background', 0xFFF59D);
        runs = parseChatFormattedText(inlineEmojiPlainText(controller.text));
        final colored = runs.where((run) => run.text == 'שלום').single;
        expect(colored.foregroundRgb, 0x1976D2);
        expect(colored.backgroundRgb, 0xFFF59D);
        expect(_selectedText(controller), 'שלום');
        expect(controller.selection.baseOffset,
            greaterThan(controller.selection.extentOffset));

        await _pickColor(tester, 'foreground', null);
        runs = parseChatFormattedText(inlineEmojiPlainText(controller.text));
        final highlighted = runs.where((run) => run.text == 'שלום').single;
        expect(highlighted.foregroundRgb, isNull);
        expect(highlighted.backgroundRgb, 0xFFF59D);
        expect(_selectedText(controller), 'שלום');

        await _pickColor(tester, 'background', null);
        expect(inlineEmojiPlainText(controller.text), 'שלום עולם');
        expect(_logicalSelection(controller), original.selection);
        expect(app.focusNode(tester).hasFocus, isTrue);
        expect(app.writes, isEmpty);
        expect(app.socketMessages, isEmpty);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$kind sends combined colors and bold without visible wire markers',
        (tester) async {
      final app = _Chat(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _draft(tester, app, 'שלום עולם', start: 4, end: 0);
        final controller = app.controller(tester);
        await _pickColor(tester, 'foreground', 0x1976D2);
        await _pickColor(tester, 'background', 0xFFF59D);
        await _tapFormat(tester, 'bold');
        expect(_visibleText(controller.text), 'שלום עולם');
        expect(_selectedText(controller), 'שלום');
        final wire = encodeInlineEmojiText(controller.text);
        expect(wire, contains('[[bt-style:'));
        expect(wire, contains('fg=1976D2'));
        expect(wire, contains('bg=FFF59D'));
        final runs = parseChatFormattedText(wire);
        final selected = runs.where((run) => run.text == 'שלום').single;
        expect(selected.foregroundRgb, 0x1976D2);
        expect(selected.backgroundRgb, 0xFFF59D);
        expect(selected.bold, isTrue);
        expect(
            runs.where((run) => run.text.contains('עולם')).every((run) =>
                run.foregroundRgb == null && run.backgroundRgb == null),
            isTrue);
        await tester.tap(find.byKey(const ValueKey('chat-composer-action')));
        await tester.pumpAndSettle();
        app.expectSentText(wire);
        expect(controller.text, isEmpty);
        final body = _message(wire);
        expect(body, findsOneWidget);
        expect(_styledText(tester, body).map((part) => part.text).join(),
            'שלום עולם');
        _expectColoredText(tester, body, 'שלום',
            foreground: 0x1976D2, background: 0xFFF59D, bold: true);
        final uncolored = _styledText(tester, body)
            .where((part) => part.text.contains('עולם'));
        expect(
            uncolored.every((part) =>
                part.style.color != const Color(0xFF1976D2) &&
                part.style.backgroundColor == null),
            isTrue);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$kind renders incoming and own colored history with basic formatting',
        (tester) async {
      const incoming =
          '[[bt-style:fg=1976D2;bg=FFF59D]]**קבלה**[[/bt-style]] רגיל';
      const outgoing =
          '[[bt-style:fg=C62828;bg=BBDEFB]]_שליחה_[[/bt-style]] רגיל';
      final app = _Chat(isGroup: isGroup, history: [
        {
          'id': 'incoming-colored',
          'sender_id': _recipient['id'],
          'sender_name': _recipient['name'],
          'type': 'text',
          'body': incoming,
          'created_at': '2026-10-12T12:00:00Z',
        },
        {
          'id': 'outgoing-colored',
          'sender_id': _me['id'],
          'sender_name': _me['name'],
          'type': 'text',
          'body': outgoing,
          'created_at': '2026-10-12T12:01:00Z',
        },
      ]);
      await http.runWithClient(() async {
        await app.mount(tester);
        expect(
            _styledText(tester, _message(incoming))
                .map((part) => part.text)
                .join(),
            'קבלה רגיל');
        expect(
            _styledText(tester, _message(outgoing))
                .map((part) => part.text)
                .join(),
            'שליחה רגיל');
        _expectColoredText(tester, _message(incoming), 'קבלה',
            foreground: 0x1976D2, background: 0xFFF59D, bold: true);
        _expectColoredText(tester, _message(outgoing), 'שליחה',
            foreground: 0xC62828, background: 0xBBDEFB);
        expect(
            _styledText(tester, _message(outgoing)).any((part) =>
                part.text == 'שליחה' &&
                part.style.fontStyle == FontStyle.italic),
            isTrue);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$kind edits and forwards colored messages preserving their raw body',
        (tester) async {
      const original =
          '[[bt-style:fg=1976D2;bg=FFF59D]]**שלום**[[/bt-style]] עולם';
      final app = _Chat(isGroup: isGroup, history: [
        {
          'id': 'editable-colored',
          'sender_id': _me['id'],
          'sender_name': _me['name'],
          'type': 'text',
          'body': original,
          'created_at': '2026-10-12T12:01:00Z',
        },
      ]);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.longPress(_message(original));
        await tester.pumpAndSettle();
        await tester.tap(find.text('ערוך הודעה'));
        await tester.pumpAndSettle();
        expect(inlineEmojiPlainText(app.controller(tester).text), original);
        final selectedStart = original.indexOf('שלום');
        await _draft(tester, app, original,
            start: selectedStart, end: selectedStart + 4);
        await _pickColor(tester, 'background', null);
        final edited = encodeInlineEmojiText(app.controller(tester).text);
        expect(edited, isNot(original));
        expect(edited, contains('fg=1976D2'));
        expect(edited, isNot(contains('bg=')));
        expect(_visibleText(edited), 'שלום עולם');
        await tester.tap(find.byKey(const ValueKey('chat-composer-action')));
        await tester.pumpAndSettle();
        final patches = app.requests.where((r) => r.method == 'PATCH').toList();
        expect(patches, hasLength(1));
        expect(patches.single.url.path, endsWith('/messages/editable-colored'));
        expect(jsonDecode(patches.single.body), {'body': edited});
        _expectColoredText(tester, _message(edited), 'שלום',
            foreground: 0x1976D2, bold: true);
        await tester.longPress(_message(edited));
        await tester.pumpAndSettle();
        await tester.tap(find.text('העבר'));
        await tester.pumpAndSettle();
        await tester.tap(find
            .byKey(const ValueKey('forward-target-user:forward-recipient')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
        await tester.pumpAndSettle();
        expect(app.writes, hasLength(1));
        final forwarded = jsonDecode(app.writes.single.body) as Map;
        expect(forwarded['text'], edited);
        expect(forwarded['toUserId'], 'forward-recipient');
        expect(app.socketMessages, isEmpty);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$kind color picker fits 320 pixels with the keyboard open',
        (tester) async {
      _viewport(tester, const Size(320, 740));
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      final app = _Chat(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _draft(tester, app, 'שלום עולם', end: 4);
        final before = app.controller(tester).value;
        final fieldRect = tester.getRect(app.composer);
        await _openColorPicker(tester, 'background');
        final palettePanel = find
            .descendant(of: _colorPicker, matching: find.byType(Material))
            .first;
        final paletteRect = tester.getRect(palettePanel);
        expect(paletteRect.left, greaterThanOrEqualTo(0));
        expect(paletteRect.right, lessThanOrEqualTo(320));
        expect(paletteRect.top, greaterThanOrEqualTo(0));
        expect(paletteRect.bottom, lessThanOrEqualTo(480));
        expect(app.controller(tester).value, before);
        expect(tester.getRect(app.composer), fieldRect);
        expect(tester.takeException(), isNull);
        final yellow = find.byKey(const ValueKey('chat-color-swatch-FFF59D'));
        expect(yellow.hitTestable(), findsOneWidget);
        await tester.tap(yellow);
        await tester.pumpAndSettle();
        expect(_colorPicker, findsNothing);
        expect(_selectedText(app.controller(tester)), 'שלום');
        expect(app.focusNode(tester).hasFocus, isTrue);
        expect(tester.getSize(app.composer).width, greaterThanOrEqualTo(80));
        expect(tester.takeException(), isNull);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$kind does not format metadata or send empty colored wrappers',
        (tester) async {
      final app = _Chat(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _draft(tester, app, 'שלום');
        await _pickColor(tester, 'foreground', 0x1976D2);
        final controller = app.controller(tester);
        final colored = controller.value;
        final openingEnd = colored.text.indexOf(']]') + 2;
        controller.selection =
            TextSelection(baseOffset: 0, extentOffset: openingEnd);
        await tester.pump();
        expect(_toolbar, findsNothing,
            reason: 'Hidden color metadata is not a formatting target');
        controller.value = colored;
        await tester.pump();
        controller.value = colored.copyWith(
          text: colored.text
              .replaceRange(colored.selection.start, colored.selection.end, ''),
          selection: TextSelection.collapsed(offset: colored.selection.start),
          composing: TextRange.empty,
        );
        await tester.pump();
        expect(controller.text, contains('[[bt-style:'));
        expect(_visibleText(controller.text), isEmpty);
        final action = tester.widget<IconButton>(
            find.byKey(const ValueKey('chat-composer-action')));
        expect((action.icon as Icon).icon, Icons.mic);
        controller.selection =
            TextSelection(baseOffset: 0, extentOffset: controller.text.length);
        await tester.pump();
        expect(_toolbar, findsNothing);
        tester.widget<TextField>(app.composer).onSubmitted!('');
        await tester.pumpAndSettle();
        expect(app.writes, isEmpty);
        expect(app.socketMessages, isEmpty);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$kind selects, toggles bold and sends the exact formatted body',
        (tester) async {
      final app = _Chat(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        expect(_toolbar, findsNothing);
        await _draft(tester, app, 'שלום עולם', start: 4, end: 0);
        expect(_toolbar, findsOneWidget);
        final controller = app.controller(tester);
        expect(controller, isA<InlineEmojiController>());
        await _tapFormat(tester, 'bold');
        expect(inlineEmojiPlainText(controller.text), '**שלום** עולם');
        expect(_logicalSelection(controller),
            const TextSelection(baseOffset: 6, extentOffset: 2));
        expect(app.focusNode(tester).hasFocus, isTrue);
        await _tapFormat(tester, 'bold');
        expect(inlineEmojiPlainText(controller.text), 'שלום עולם');
        expect(_logicalSelection(controller),
            const TextSelection(baseOffset: 4, extentOffset: 0));
        await _tapFormat(tester, 'bold');
        expect(app.writes, isEmpty);
        expect(app.socketMessages, isEmpty);
        await tester.tap(find.byKey(const ValueKey('chat-composer-action')));
        await tester.pumpAndSettle();
        app.expectSentText('**שלום** עולם');
        expect(controller.text, isEmpty);
        expect(_toolbar, findsNothing);
        final spans = _styledText(tester, _message('**שלום** עולם'));
        expect(
            spans.any((part) =>
                part.text == 'שלום' &&
                part.style.fontWeight == FontWeight.bold),
            isTrue);
        expect(spans.map((part) => part.text).join(), 'שלום עולם');
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$kind applies all seven selection actions without sending',
        (tester) async {
      final app = _Chat(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        for (final example in [
          (name: 'bold', source: 'שלום עולם', end: 4, result: '**שלום** עולם'),
          (name: 'italic', source: 'שלום עולם', end: 4, result: '_שלום_ עולם'),
          (
            name: 'strikethrough',
            source: 'שלום עולם',
            end: 4,
            result: '~~שלום~~ עולם'
          ),
          (
            name: 'code',
            source: 'hello world',
            end: 5,
            result: '`hello` world'
          ),
          (
            name: 'bulletList',
            source: 'ראשון\nשני',
            end: 9,
            result: '- ראשון\n- שני'
          ),
          (
            name: 'numberedList',
            source: 'ראשון\nשני',
            end: 9,
            result: '1. ראשון\n2. שני'
          ),
          (
            name: 'quote',
            source: 'ראשון\nשני',
            end: 9,
            result: '> ראשון\n> שני'
          ),
        ]) {
          await _draft(tester, app, example.source, end: example.end);
          await _tapFormat(tester, example.name);
          expect(
              inlineEmojiPlainText(app.controller(tester).text), example.result,
              reason: example.name);
          expect(app.focusNode(tester).hasFocus, isTrue);
          expect(tester.takeException(), isNull);
        }
        expect(app.writes, isEmpty);
        expect(app.socketMessages, isEmpty);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$kind formats emoji with Hebrew and preserves encoded artwork',
        (tester) async {
      final app = _Chat(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        final source = 'שלום ${inlineEmojiCharacter(1)} עולם';
        await _draft(tester, app, source, end: 6);
        await _tapFormat(tester, 'bold');
        expect(inlineEmojiPlainText(app.controller(tester).text),
            '**שלום ${inlineEmojiCharacter(1)}** עולם');
        expect(_logicalSelection(app.controller(tester)),
            const TextSelection(baseOffset: 2, extentOffset: 8));
        expect(tester.widget<TextField>(app.composer).textDirection,
            TextDirection.rtl);
        await tester.tap(find.byKey(const ValueKey('chat-composer-action')));
        await tester.pumpAndSettle();
        app.expectSentText('**שלום [[bt-emoji:001]]** עולם');
        expect(find.byKey(const ValueKey('inline-custom-emoji-1')),
            findsOneWidget);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$kind shows received and sent history with readable styles',
        (tester) async {
      const incoming = '**קבלה** _נטוי_ ~~ישן~~ `code`';
      const outgoing = '**שליחה** _נטוי_ ~~ישן~~ `code`';
      final app = _Chat(isGroup: isGroup, history: [
        {
          'id': 'incoming-formatted',
          'sender_id': _recipient['id'],
          'sender_name': _recipient['name'],
          'type': 'text',
          'body': incoming,
          'created_at': '2026-10-12T12:00:00Z',
        },
        {
          'id': 'outgoing-formatted',
          'sender_id': _me['id'],
          'sender_name': _me['name'],
          'type': 'text',
          'body': outgoing,
          'created_at': '2026-10-12T12:01:00Z',
        },
      ]);
      await http.runWithClient(() async {
        await app.mount(tester);
        for (final example in [
          (raw: incoming, label: 'קבלה'),
          (raw: outgoing, label: 'שליחה'),
        ]) {
          expect(_message(example.raw), findsOneWidget);
          final spans = _styledText(tester, _message(example.raw));
          expect(spans.map((part) => part.text).join(),
              '${example.label} נטוי ישן code');
          expect(
              spans.any((part) =>
                  part.text == example.label &&
                  part.style.fontWeight == FontWeight.bold),
              isTrue);
          expect(
              spans.any((part) =>
                  part.text == 'נטוי' &&
                  part.style.fontStyle == FontStyle.italic),
              isTrue);
          expect(
              spans.any((part) =>
                  part.text == 'ישן' &&
                  (part.style.decoration
                          ?.contains(TextDecoration.lineThrough) ??
                      false)),
              isTrue);
          expect(
              spans.any((part) =>
                  part.text == 'code' && part.style.fontFamily == 'monospace'),
              isTrue);
        }
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$kind edits existing formatting without losing raw markers',
        (tester) async {
      const original = '**שלום** _עולם_';
      final app = _Chat(isGroup: isGroup, history: [
        {
          'id': 'editable-formatted',
          'sender_id': _me['id'],
          'sender_name': _me['name'],
          'type': 'text',
          'body': original,
          'created_at': '2026-10-12T12:01:00Z',
        },
      ]);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.longPress(_message(original));
        await tester.pumpAndSettle();
        await tester.tap(find.text('ערוך הודעה'));
        await tester.pumpAndSettle();
        expect(inlineEmojiPlainText(app.controller(tester).text), original);
        await _draft(tester, app, original, start: 10, end: 14);
        await _tapFormat(tester, 'strikethrough');
        const edited = '**שלום** _~~עולם~~_';
        expect(inlineEmojiPlainText(app.controller(tester).text), edited);
        await tester.tap(find.byKey(const ValueKey('chat-composer-action')));
        await tester.pumpAndSettle();
        final patches = app.requests.where((r) => r.method == 'PATCH').toList();
        expect(patches, hasLength(1));
        expect(
            patches.single.url.path, endsWith('/messages/editable-formatted'));
        expect(jsonDecode(patches.single.body), {'body': edited});
        expect(app.writes, isEmpty);
        expect(app.socketMessages, isEmpty);
        expect(_message(edited), findsOneWidget);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$kind copies and forwards the stored formatted text unchanged',
        (tester) async {
      const original = '**שלום** _עולם_\n- ראשון\n- שני';
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final app = _Chat(isGroup: isGroup, history: [
        {
          'id': 'forward-formatted',
          'sender_id': _me['id'],
          'sender_name': _me['name'],
          'type': 'text',
          'body': original,
          'created_at': '2026-10-12T12:01:00Z',
        },
      ]);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.tap(_message(original));
        if (kIsWeb) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.tap(_message(original));
        }
        await tester.pumpAndSettle();
        expect(copied, original);
        await tester.longPress(_message(original));
        await tester.pumpAndSettle();
        await tester.tap(find.text('העבר'));
        await tester.pumpAndSettle();
        await tester.tap(find
            .byKey(const ValueKey('forward-target-user:forward-recipient')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
        await tester.pumpAndSettle();
        expect(app.writes, hasLength(1));
        final forwarded = jsonDecode(app.writes.single.body) as Map;
        expect(forwarded['text'], original);
        expect(forwarded['toUserId'], 'forward-recipient');
        expect(app.socketMessages, isEmpty);
        expect(_message(original), findsOneWidget);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$kind formatting retains native cut copy and paste actions',
        (tester) async {
      String? copied;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        switch (call.method) {
          case 'Clipboard.getData':
            return {'text': 'הדבקה'};
          case 'Clipboard.hasStrings':
            return {'value': true};
          case 'Clipboard.setData':
            copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() =>
          messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final app = _Chat(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _draft(tester, app, 'שלום עולם', end: 4);
        final editable = find.descendant(
            of: app.composer, matching: find.byType(EditableText));
        final state = tester.state<EditableTextState>(editable);
        state.clipboardStatus.value = ClipboardStatus.pasteable;
        final field = tester.widget<TextField>(app.composer);
        final menu =
            field.contextMenuBuilder!(tester.element(app.composer), state);
        expect(menu, isA<AdaptiveTextSelectionToolbar>());
        final items = state.contextMenuButtonItems;
        expect(
            items.map((item) => item.type),
            containsAll([
              ContextMenuButtonType.cut,
              ContextMenuButtonType.copy,
              ContextMenuButtonType.paste,
              ContextMenuButtonType.selectAll,
            ]));
        final overlay = Overlay.of(tester.element(app.composer));
        final entry = OverlayEntry(builder: (_) => menu);
        var entryRemoved = false;
        addTearDown(() {
          if (!entryRemoved) entry.remove();
          entry.dispose();
        });
        overlay.insert(entry);
        await tester.pump();
        final labels = MaterialLocalizations.of(tester.element(app.composer));
        for (final label in [
          labels.cutButtonLabel,
          labels.copyButtonLabel,
          labels.pasteButtonLabel,
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.byKey(const ValueKey('chat-context-formatting-toolbar')),
            findsOneWidget);
        await tester.tap(find.text(labels.copyButtonLabel));
        await tester.pump();
        expect(copied, 'שלום');
        expect(inlineEmojiPlainText(app.controller(tester).text), 'שלום עולם');
        entry.remove();
        entryRemoved = true;
        await tester.pump();
        await app.dispose(tester);
      }, () => app.client);
    });

    for (final viewport in [const Size(320, 740), const Size(1280, 900)]) {
      testWidgets('$kind formatting fits $viewport and retains composer height',
          (tester) async {
        _viewport(tester, viewport);
        final app = _Chat(isGroup: isGroup);
        await http.runWithClient(() async {
          await app.mount(tester);
          await _draft(tester, app, 'שלום עולם', start: 9, end: 9);
          final shortcuts =
              find.byKey(const ValueKey('chat-composer-shortcuts'));
          final before = tester.getRect(shortcuts);
          expect(_toolbar, findsNothing);
          app.controller(tester).selection =
              const TextSelection(baseOffset: 0, extentOffset: 9);
          await tester.pump();
          expect(_toolbar, findsOneWidget);
          expect(tester.getRect(shortcuts).height, before.height);
          expect(tester.getRect(shortcuts).top, before.top);
          expect(find.byKey(const ValueKey('chat-stickers-shortcut')),
              findsOneWidget);
          expect(find.byKey(const ValueKey('chat-inline-emoji-shortcut')),
              findsOneWidget);
          await _tapFormat(tester, 'quote');
          expect(
              inlineEmojiPlainText(app.controller(tester).text), '> שלום עולם');
          final quoteRect = tester.getRect(_formatButton('quote'));
          expect(quoteRect.left, greaterThanOrEqualTo(0));
          expect(quoteRect.right, lessThanOrEqualTo(viewport.width));
          expect(app.focusNode(tester).hasFocus, isTrue);
          expect(tester.takeException(), isNull);
          await app.dispose(tester);
        }, () => app.client);
      });
    }
  }

  for (final viewport in [const Size(360, 800), const Size(1280, 900)]) {
    for (final colored in [false, true]) {
      for (final summary in {
        'empty': <String, dynamic>{},
        'delivered': <String, dynamic>{
          'deliveredCount': 2,
          'blockedCount': 0,
          'deliveredTo': [
            {'name': 'חבר אחד'},
            {'name': 'חבר שני'},
          ],
        },
        'filtered': <String, dynamic>{
          'deliveredCount': 1,
          'blockedCount': 2,
          'deliveredTo': [
            {'name': 'חבר אחד'},
          ],
          'blockedFor': [
            {'name': 'חבר שני'},
            {'name': 'חבר שלישי'},
          ],
        },
      }.entries) {
        testWidgets(
            'group delivery bubble and options stay compact '
            '($viewport, colored=$colored, ${summary.key})', (tester) async {
          _viewport(tester, viewport);
          final body = colored
              ? '[[bt-style:fg=1976D2;bg=FFF59D]]שלום[[/bt-style]]'
              : 'שלום';
          final app = _Chat(isGroup: true, history: [
            {
              'id': 'compact-delivery-message',
              'sender_id': _me['id'],
              'sender_name': _me['name'],
              'type': 'text',
              'body': body,
              'created_at': '2026-10-12T12:00:00Z',
              'message_status': 'delivered',
              'delivery_summary': summary.value,
            },
          ]);
          await http.runWithClient(() async {
            await app.mount(tester);
            final message = _message(body);
            expect(message, findsOneWidget);
            final bubble = find.ancestor(
                of: message,
                matching: find.byWidgetPredicate((widget) =>
                    widget is Container &&
                    widget.decoration is BoxDecoration &&
                    (widget.decoration! as BoxDecoration).color == kIncoming));
            expect(bubble, findsOneWidget);
            final summaryTooltip = find.byWidgetPredicate((widget) =>
                widget is Tooltip &&
                widget.message?.startsWith('נשלח בקבוצה') == true);
            expect(summaryTooltip, findsOneWidget);
            final object = tester.getRect(bubble);
            final contentWidth = tester.getRect(summaryTooltip).width;
            final textWidth = tester.getRect(message).width;
            final widest = contentWidth > textWidth ? contentWidth : textWidth;
            expect(object.width, closeTo(widest + 16, 1),
                reason:
                    'Delivery details must size the bubble to their content');
            expect(object.width, lessThanOrEqualTo(436));
            expect(object.width, lessThanOrEqualTo(viewport.width * .75));

            await tester.tap(find.byTooltip('אפשרויות הודעה'));
            await tester.pumpAndSettle();
            final menu = tester
                .getRect(find.byKey(const ValueKey('message-options-menu')));
            expect(menu.width, lessThanOrEqualTo(208));
            expect(menu.left, greaterThanOrEqualTo(0));
            expect(menu.right, lessThanOrEqualTo(viewport.width));
            expect(menu.top, greaterThanOrEqualTo(0));
            expect(menu.bottom, lessThanOrEqualTo(viewport.height));
            if (viewport.width > 600) {
              expect(menu.right, closeTo(object.left - 4, 1));
            }
            expect(tester.getRect(bubble), object);
            expect(tester.takeException(), isNull);
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
            await app.dispose(tester);
          }, () => app.client);
        });
      }
    }
  }

  testWidgets('private text receiving filter keeps formatting unavailable',
      (tester) async {
    final app = _Chat(isGroup: false, allowText: false);
    await http.runWithClient(() async {
      await app.mount(tester);
      expect(tester.widget<TextField>(app.composer).enabled, isFalse);
      await _draft(tester, app, 'שלום עולם');
      expect(_toolbar, findsNothing);
      expect(_formatButton('bold'), findsNothing);
      expect(_formatButton('foreground'), findsNothing);
      expect(_formatButton('background'), findsNothing);
      expect(app.writes, isEmpty);
      expect(app.socketMessages, isEmpty);
      await app.dispose(tester);
    }, () => app.client);
  });
}
