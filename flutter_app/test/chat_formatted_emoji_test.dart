import 'dart:convert';
import 'dart:ui' as ui;

import 'package:betshuva/chat_text_formatting.dart';
import 'package:betshuva/inline_custom_emoji.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

class _FormattedEmojiBundle extends CachingAssetBundle {
  _FormattedEmojiBundle({this.failCatalog = false, this.failImages = false});

  final bool failCatalog;
  final bool failImages;

  @override
  Future<ByteData> load(String key) async {
    if (key == 'assets/twemoji/emoji_allowlist.json') {
      if (failCatalog) throw StateError('catalog unavailable');
      return ByteData.sublistView(Uint8List.fromList(utf8.encode(jsonEncode([
        {'emoji': '😀', 'twemoji_code': '1f600', 'label_he': 'חיוך'},
        {'emoji': '❤️', 'twemoji_code': '2764', 'label_he': 'לב'},
      ]))));
    }
    if (failImages) throw StateError('image unavailable');
    return ByteData.sublistView(Uint8List.fromList(utf8
        .encode('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36">'
            '<circle cx="18" cy="18" r="16" fill="#ffcc4d"/></svg>')));
  }
}

Future<void> _show(WidgetTester tester, String text,
    {bool textFormatting = true,
    bool failCatalog = false,
    bool failImages = false,
    bool messageEmojis = true,
    double width = 320}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: DefaultAssetBundle(
        bundle: _FormattedEmojiBundle(
            failCatalog: failCatalog, failImages: failImages),
        child: SizedBox(
          width: width,
          child: InlineEmojiText(
            text,
            textFormatting: textFormatting,
            messageEmojis: messageEmojis,
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 14, height: 1.45),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

RenderParagraph _paragraph(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(find
        .descendant(
          of: find.byType(InlineEmojiText),
          matching: find.byWidgetPredicate((widget) => widget is RichText),
        )
        .first);

List<TextSpan> _textRuns(WidgetTester tester) =>
    _messageSpan(tester).children!.whereType<TextSpan>().toList();

TextSpan _messageSpan(WidgetTester tester) => tester
    .widget<Text>(find
        .descendant(
          of: find.byType(InlineEmojiText),
          matching: find.byWidgetPredicate((widget) => widget is Text),
        )
        .first)
    .textSpan! as TextSpan;

TextSpan _run(WidgetTester tester, String text) =>
    _textRuns(tester).singleWhere((span) => span.text == text);

bool _isMetadataSpan(TextSpan span) =>
    span.style?.fontSize == 0 &&
    (span.text?.startsWith('[[bt-style:') == true ||
        span.text?.startsWith('[[/bt-style]]') == true);

void main() {
  testWidgets('formatted Hebrew preserves flat custom and Unicode emoji spans',
      (tester) async {
    const source = '**שלום [[bt-emoji:001]][[bt-emoji:002]] 😀❤️** '
        '_עולם_ ~~ישן~~ `קוד`\n> ציטוט\n- ראשון\n1. שני';
    await _show(tester, source);
    final span = _messageSpan(tester);
    expect(span.toPlainText(includeSemanticsLabels: false),
        'שלום \uFFFC\uFFFC \uFFFC\uFFFC עולם ישן קוד\n│ ציטוט\n• ראשון\n1. שני');
    expect(span.children!.whereType<WidgetSpan>(), hasLength(4));
    expect(
        span.children!.whereType<TextSpan>().every((s) => s.children == null),
        isTrue);
    expect(_run(tester, 'שלום ').style!.fontWeight, FontWeight.bold);
    expect(_run(tester, 'עולם').style!.fontStyle, FontStyle.italic);
    expect(_run(tester, 'ישן').style!.decoration, TextDecoration.lineThrough);
    expect(_run(tester, 'קוד').style!.fontFamily, 'monospace');
    expect(_run(tester, 'קוד').style!.backgroundColor, isNotNull);
    expect(_run(tester, '│ ציטוט').style!.fontStyle, FontStyle.italic);
    final positions = [
      tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-1'))).dx,
      tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-2'))).dx,
      tester
          .getCenter(find.byKey(const ValueKey('message-unicode-emoji-1f600')))
          .dx,
      tester
          .getCenter(find.byKey(const ValueKey('message-unicode-emoji-2764')))
          .dx,
    ];
    for (var i = 1; i < positions.length; i++) {
      expect(positions[i - 1], lessThan(positions[i]));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog fallback retains formatting and custom artwork',
      (tester) async {
    await _show(tester, '**שלום 😀 [[bt-emoji:003]]** _עולם_',
        failCatalog: true);
    expect(_paragraph(tester).text.toPlainText(includeSemanticsLabels: false),
        'שלום 😀 \uFFFC עולם');
    expect(_run(tester, 'שלום 😀 ').style!.fontWeight, FontWeight.bold);
    expect(_run(tester, 'עולם').style!.fontStyle, FontStyle.italic);
    expect(find.byKey(const ValueKey('inline-custom-emoji-3')), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plain titles remain literal unless formatting is enabled',
      (tester) async {
    const title = '**כותרת** _תיאור_ ~~רגיל~~ `קוד`';
    await _show(tester, title, textFormatting: false, messageEmojis: false);
    final text = tester.widget<Text>(find.text(title));
    expect(text.data, title);
    expect(text.textSpan, isNull);
    expect(
        tester
            .widget<InlineEmojiText>(find.byType(InlineEmojiText))
            .textFormatting,
        isFalse);
  });

  testWidgets('editor keeps source offsets and composing styles across runs',
      (tester) async {
    final controller = InlineEmojiController(textFormatting: true);
    addTearDown(controller.dispose);
    const source = '**מודגש** ~~ישן~~ _עולם_ `קוד`';
    final start = source.indexOf('ישן');
    controller.value = TextEditingValue(
      text: source,
      selection: TextSelection(baseOffset: source.length, extentOffset: start),
      composing: TextRange(start: start, end: source.indexOf('עולם') + 4),
    );
    final original = controller.value;
    TextSpan? built;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      built = controller.buildTextSpan(
          context: context,
          style: const TextStyle(fontSize: 14, color: Colors.black),
          withComposing: true);
      return Text.rich(built!);
    })));
    expect(controller.value, original);
    expect(built!.toPlainText(includeSemanticsLabels: false), source);
    final runs = built!.children!.whereType<TextSpan>().toList();
    expect(runs.singleWhere((s) => s.text == 'מודגש').style!.fontWeight,
        FontWeight.bold);
    expect(
        runs.singleWhere((s) => s.text == 'ישן').style!.decoration,
        TextDecoration.combine(
            [TextDecoration.lineThrough, TextDecoration.underline]));
    final italic = runs.singleWhere((s) => s.text == 'עולם');
    expect(italic.style!.fontStyle, FontStyle.italic);
    expect(italic.style!.decoration, TextDecoration.underline);
    final marker = runs.first;
    expect(marker.text, '**');
    expect(marker.style!.color!.a, lessThan(0.6));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('formatted drafts retain selection, caret and emoji order at 320',
      (tester) async {
    const source = '**שלום** [[bt-emoji:001]][[bt-emoji:002]] _עולם_ 😀❤️\n'
        'עוד טקסט בעברית כדי לוודא שהשורה נגללת ומשתלבת היטב '
        '~~סיום~~ [[bt-emoji:003]]';
    final controller = InlineEmojiController(
        text: source, isolateEmojiRuns: true, textFormatting: true);
    addTearDown(controller.dispose);
    controller.selection =
        TextSelection(baseOffset: controller.text.length, extentOffset: 2);
    final original = controller.value;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: TextField(
            controller: controller,
            minLines: 1,
            maxLines: 8,
            textDirection: TextDirection.rtl,
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final span = editable.text! as TextSpan;
    expect(span.children!.whereType<WidgetSpan>(), hasLength(3));
    expect(
        span.children!.whereType<TextSpan>().every((s) => s.children == null),
        isTrue);
    expect(span.toPlainText(includeSemanticsLabels: false),
        controller.text.replaceAll(RegExp('[\uE000-\uF8FF]'), '\uFFFC'));
    expect(encodeInlineEmojiText(controller.text), source);
    expect(controller.value, original);
    final first =
        tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-1')));
    final second =
        tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-2')));
    final third =
        tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-3')));
    expect(first.dx, lessThan(second.dx));
    expect(third.dy, greaterThan(second.dy));
    final cursor = editable
        .getLocalRectForCaret(TextPosition(offset: controller.text.length));
    expect(cursor.left.isFinite && cursor.top.isFinite, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'formatting retains emoji-only enlargement and compact custom size',
      (tester) async {
    await _show(tester, '😀', textFormatting: false);
    expect(tester.widget<SvgPicture>(find.byType(SvgPicture)).width, 44);
    await _show(tester, '**😀**');
    expect(tester.widget<SvgPicture>(find.byType(SvgPicture)).width, 44);
    await _show(tester, '**[[bt-emoji:001]]**');
    expect(
        tester
            .getSize(find.byKey(const ValueKey('inline-custom-emoji-1')))
            .width,
        closeTo(20.79, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sent colors cover text and flat custom and Unicode artwork',
      (tester) async {
    const source = '[[bt-style:fg=1976D2;bg=FFF59D]]'
        '**שלום [[bt-emoji:001]] 😀**[[/bt-style]] רגיל '
        '[[bt-style:fg=C62828;bg=FFEBEE]]_עולם_[[/bt-style]]';
    await _show(tester, source);
    final span = _messageSpan(tester);
    expect(span.toPlainText(includeSemanticsLabels: false),
        'שלום \uFFFC \uFFFC רגיל עולם');
    final blue = _run(tester, 'שלום ');
    expect(blue.style!.color, const Color(0xFF1976D2));
    expect(blue.style!.backgroundColor, const Color(0xFFFFF59D));
    expect(blue.style!.fontWeight, FontWeight.bold);
    final red = _run(tester, 'עולם');
    expect(red.style!.color, const Color(0xFFC62828));
    expect(red.style!.backgroundColor, const Color(0xFFFFEBEE));
    expect(red.style!.fontStyle, FontStyle.italic);
    expect(_run(tester, ' רגיל ').style?.color, isNull);
    expect(span.children!.whereType<WidgetSpan>(), hasLength(2));
    for (final key in [
      'inline-custom-emoji-1',
      'message-unicode-emoji-1f600'
    ]) {
      expect(
          find.ancestor(
              of: find.byKey(ValueKey(key)),
              matching: find.byWidgetPredicate((widget) =>
                  widget is ColoredBox &&
                  widget.color == const Color(0xFFFFF59D))),
          findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit colors survive catalog and image fallback and code',
      (tester) async {
    const source = '[[bt-style:fg=1976D2;bg=FFF59D]]'
        '`שלום 😀`[[/bt-style]]';
    await _show(tester, source, failCatalog: true);
    final fallback = _run(tester, 'שלום 😀');
    expect(fallback.style!.color, const Color(0xFF1976D2));
    expect(fallback.style!.backgroundColor, const Color(0xFFFFF59D));
    expect(fallback.style!.fontFamily, 'monospace');
    await _show(tester, source, failImages: true);
    expect(
        _run(tester, 'שלום ').style!.backgroundColor, const Color(0xFFFFF59D));
    final unicode = tester.widget<Text>(find.text('😀'));
    expect(unicode.style!.color, const Color(0xFF1976D2));
    expect(unicode.style!.backgroundColor, const Color(0xFFFFF59D));
    expect(tester.takeException(), isNull);
  });

  testWidgets('color syntax stays literal when text formatting is disabled',
      (tester) async {
    const source = '[[bt-style:fg=1976D2;bg=FFF59D]]שלום[[/bt-style]]';
    await _show(tester, source, textFormatting: false, messageEmojis: false);
    expect(tester.widget<Text>(find.text(source)).textSpan, isNull);
    final controller = InlineEmojiController(text: source);
    addTearDown(controller.dispose);
    TextSpan? built;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      built = controller.buildTextSpan(
          context: context,
          style: const TextStyle(fontSize: 14),
          withComposing: true);
      return Text.rich(built!);
    })));
    expect(built!.toPlainText(includeSemanticsLabels: false), source);
    expect(built!.children!.whereType<TextSpan>().single.style, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('draft metadata is invisible without changing source or IME',
      (tester) async {
    const source = '[[bt-style:fg=1976D2;bg=FFF59D]]'
        '**שלום** ~~ישן~~[[/bt-style]]';
    final controller = InlineEmojiController(textFormatting: true);
    addTearDown(controller.dispose);
    final start = source.indexOf('ישן');
    controller.value = TextEditingValue(
        text: source,
        selection: TextSelection(baseOffset: start + 3, extentOffset: start),
        composing: TextRange(start: start, end: start + 3));
    final original = controller.value;
    TextSpan? built;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      built = controller.buildTextSpan(
          context: context,
          style: const TextStyle(fontSize: 14),
          withComposing: true);
      return Text.rich(built!);
    })));
    expect(built!.toPlainText(includeSemanticsLabels: false), source);
    expect(built!.toPlainText(includeSemanticsLabels: false).length,
        source.length);
    expect(controller.value, original);
    final spans = built!.children!.whereType<TextSpan>().toList();
    final metadata = spans.where(_isMetadataSpan).toList();
    expect(metadata, hasLength(2));
    expect(metadata.every((s) => s.style!.fontSize == 0), isTrue);
    expect(metadata.every((s) => s.style!.color == Colors.transparent), isTrue);
    final content = spans.singleWhere((s) => s.text == 'ישן');
    expect(content.style!.color, const Color(0xFF1976D2));
    expect(content.style!.backgroundColor, Colors.transparent);
    expect(spans.singleWhere((s) => s.text == 'שלום').style!.backgroundColor,
        const Color(0xFFFFF59D));
    expect(
        content.style!.decoration,
        TextDecoration.combine(
            [TextDecoration.lineThrough, TextDecoration.underline]));
    expect(spans.any((s) => s.text == '**' && s.style!.fontSize != 0), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  test('draft caret skips hidden color tokens without changing text or IME',
      () {
    const source = '[[bt-style:fg=1976D2]]שלום[[/bt-style]]';
    final controller =
        InlineEmojiController(text: source, textFormatting: true);
    addTearDown(controller.dispose);
    final start = source.indexOf('שלום');
    final end = start + 4;
    controller.selection = TextSelection.collapsed(offset: start);
    controller.selection = TextSelection.collapsed(offset: start - 1);
    expect(controller.selection.extentOffset, 0);
    controller.selection = const TextSelection.collapsed(offset: 1);
    expect(controller.selection.extentOffset, start);
    controller.selection = TextSelection.collapsed(offset: end);
    controller.selection = TextSelection.collapsed(offset: end + 1);
    expect(controller.selection.extentOffset, source.length);
    controller.selection = TextSelection.collapsed(offset: source.length - 1);
    expect(controller.selection.extentOffset, end);
    expect(controller.text, source);
    final composing = TextEditingValue(
        text: source,
        selection: const TextSelection.collapsed(offset: 2),
        composing: const TextRange(start: 1, end: 4));
    controller.value = composing;
    expect(controller.value, composing);
  });

  testWidgets('selected colored draft exposes the native selection highlight',
      (tester) async {
    const source = '[[bt-style:fg=1976D2;bg=FFF59D]]שלום לכולם[[/bt-style]]';
    const selectionColor = Color(0xFF90CAF9);
    final controller =
        InlineEmojiController(text: source, textFormatting: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
          textSelectionTheme:
              const TextSelectionThemeData(selectionColor: selectionColor)),
      home: Scaffold(
          body: RepaintBoundary(
        key: const ValueKey('selected-colored-draft'),
        child: SizedBox(
            width: 320,
            child: TextField(
              controller: controller,
              textDirection: TextDirection.rtl,
              style: const TextStyle(fontSize: 16),
            )),
      )),
    ));
    await tester.showKeyboard(find.byType(TextField));
    final start = source.indexOf('שלום');
    controller.selection =
        TextSelection(baseOffset: start + 4, extentOffset: start);
    final original = controller.value;
    await tester.pump();
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final span = editable.text! as TextSpan;
    final runs = span.children!.whereType<TextSpan>().toList();
    final selected = runs.singleWhere((s) => s.text == 'שלום');
    final rest = runs.singleWhere((s) => s.text == ' לכולם');
    expect(selected.style!.color, const Color(0xFF1976D2));
    expect(selected.style!.backgroundColor, Colors.transparent);
    expect(rest.style!.backgroundColor, const Color(0xFFFFF59D));
    expect(editable.selectionColor, selectionColor);
    expect(controller.value, original);
    expect(span.toPlainText(includeSemanticsLabels: false), source);
    final box =
        editable.getBoxesForSelection(controller.selection).single.toRect();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('selected-colored-draft')));
    final point = boundary.globalToLocal(
        editable.localToGlobal(Offset(box.left + 1, box.top + 1)));
    final pixel = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      final result = [for (var i = 0; i < 4; i++) bytes!.getUint8(offset + i)];
      image.dispose();
      return result;
    });
    expect(pixel, [0x90, 0xCA, 0xF9, 0xFF]);
    controller.selection = TextSelection.collapsed(offset: start + 4);
    await tester.pump();
    final restored = (editable.text! as TextSpan)
        .children!
        .whereType<TextSpan>()
        .singleWhere((s) => s.text == 'שלום לכולם');
    expect(restored.style!.backgroundColor, const Color(0xFFFFF59D));
    await tester.pumpWidget(const SizedBox());
  });

  test('palette updates retain their mapped source and selection in the draft',
      () {
    const source =
        'לפני [[bt-style:fg=1976D2;bg=FFF59D]]שלום[[/bt-style]] אחרי';
    final controller =
        InlineEmojiController(text: source, textFormatting: true);
    addTearDown(controller.dispose);
    final start = source.indexOf('שלום');
    controller.selection =
        TextSelection(baseOffset: start + 4, extentOffset: start);
    for (final command in [
      (target: ChatTextColorTarget.foreground, rgb: 0xC62828),
      (target: ChatTextColorTarget.background, rgb: null),
      (target: ChatTextColorTarget.foreground, rgb: null),
    ]) {
      final next = colorChatSelection(controller.value, command.target,
          rgb: command.rgb);
      controller.value = next;
      expect(controller.value, next);
      expect(controller.selection.baseOffset,
          greaterThan(controller.selection.extentOffset));
    }
    expect(controller.text, 'לפני שלום אחרי');
  });

  for (final replacement in ['', 'חדש']) {
    test('selection replacement $replacement balances hidden color metadata',
        () {
      const source =
          'לפני [[bt-style:fg=1976D2;bg=FFF59D]]שלום[[/bt-style]] אחרי';
      final controller =
          InlineEmojiController(text: source, textFormatting: true);
      addTearDown(controller.dispose);
      final start = 2;
      final end = source.indexOf('שלום') + 2;
      controller.selection =
          TextSelection(baseOffset: end, extentOffset: start);
      controller.value = TextEditingValue(
        text: source.replaceRange(start, end, replacement),
        selection: TextSelection.collapsed(offset: start + replacement.length),
      );
      final runs = parseChatFormattedText(controller.text);
      expect(runs.map((r) => r.text).join(), 'לפ$replacementום אחרי');
      final retained = runs.singleWhere((r) => r.text == 'ום');
      expect(retained.foregroundRgb, 0x1976D2);
      expect(retained.backgroundRgb, 0xFFF59D);
      expect(controller.selection.isValid, true);
      expect(controller.selection.isCollapsed, true);
      expect(
          parseChatFormattedText(controller.text, preserveMarkers: true)
              .map((r) => r.text)
              .join(),
          controller.text);
    });
  }

  for (final action in [
    'before-content-backspace',
    'after-content-delete',
    'after-close-backspace',
    'before-open-delete'
  ]) {
    testWidgets('color metadata survives keyboard $action', (tester) async {
      const source =
          'לפני [[bt-style:fg=1976D2;bg=FFF59D]]שלום[[/bt-style]] אחרי';
      final controller =
          InlineEmojiController(text: source, textFormatting: true);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: TextField(
        controller: controller,
        textDirection: TextDirection.rtl,
      ))));
      await tester.showKeyboard(find.byType(TextField));
      final contentStart = source.indexOf('שלום');
      final contentEnd = contentStart + 4;
      final closingEnd = source.indexOf(' אחרי');
      final openingStart = source.indexOf('[[bt-style:');
      final cursor = switch (action) {
        'before-content-backspace' => contentStart,
        'after-content-delete' => contentEnd,
        'after-close-backspace' => closingEnd,
        _ => openingStart,
      };
      final backward = action.endsWith('backspace');
      controller.selection = TextSelection.collapsed(offset: cursor);
      await tester.pump();
      if (kIsWeb) {
        final deleted = backward ? cursor - 1 : cursor;
        tester.testTextInput.updateEditingValue(TextEditingValue(
          text: source.replaceRange(deleted, deleted + 1, ''),
          selection:
              TextSelection.collapsed(offset: backward ? cursor - 1 : cursor),
        ));
      } else {
        await tester.sendKeyEvent(backward
            ? LogicalKeyboardKey.backspace
            : LogicalKeyboardKey.delete);
      }
      await tester.pump();
      final expected = switch (action) {
        'before-content-backspace' => source.replaceFirst('לפני ', 'לפני'),
        'after-content-delete' => source.replaceFirst(' אחרי', 'אחרי'),
        'after-close-backspace' => source.replaceFirst('שלום', 'שלו'),
        _ => source.replaceFirst('שלום', 'לום'),
      };
      expect(controller.text, expected);
      final span = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable
          .text!;
      final metadata = <TextSpan>[];
      span.visitChildren((s) {
        if (s is TextSpan && _isMetadataSpan(s)) {
          metadata.add(s);
        }
        return true;
      });
      expect(metadata, hasLength(2));
      expect(metadata.every((s) => s.style?.fontSize == 0), true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('two differently colored draft emoji keep their RTL order at 320',
      (tester) async {
    const source = 'שלום '
        '[[bt-style:fg=1976D2;bg=FFF59D]][[bt-emoji:001]][[/bt-style]]'
        '[[bt-style:fg=C62828;bg=FFEBEE]][[bt-emoji:002]][[/bt-style]] עולם\n'
        'עוד טקסט בעברית להמשך הטופס';
    final controller = InlineEmojiController(
        text: source, isolateEmojiRuns: true, textFormatting: true);
    addTearDown(controller.dispose);
    controller.selection = TextSelection(
        baseOffset: controller.text.length,
        extentOffset: controller.text.indexOf(inlineEmojiCharacter(1)));
    final original = controller.value;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 320,
                child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 8,
                    textDirection: TextDirection.rtl,
                    style: const TextStyle(fontSize: 14))))));
    await tester.pumpAndSettle();
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    final span = editable.text! as TextSpan;
    expect(span.children!.whereType<WidgetSpan>(), hasLength(2));
    expect(span.toPlainText(includeSemanticsLabels: false),
        controller.text.replaceAll(RegExp('[\uE000-\uF8FF]'), '\uFFFC'));
    expect(encodeInlineEmojiText(controller.text), source);
    expect(controller.value, original);
    final first =
        tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-1')));
    final second =
        tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-2')));
    expect(first.dy, closeTo(second.dy, 0.01));
    expect(first.dx, lessThan(second.dx));
    expect(second.dx, lessThan(320));
    final caret = editable.getLocalRectForCaret(
        TextPosition(offset: controller.text.indexOf(inlineEmojiCharacter(1))));
    expect(caret.left.isFinite && caret.top.isFinite, isTrue);
    expect(tester.takeException(), isNull);
    final cursor = controller.text.indexOf(inlineEmojiCharacter(1)) + 1;
    controller.selection = TextSelection.collapsed(offset: cursor);
    controller.value = controller.value.copyWith(
        text: controller.text
            .replaceRange(cursor, cursor, inlineEmojiCharacter(3)),
        selection: TextSelection.collapsed(offset: cursor + 1));
    await tester.pumpAndSettle();
    expect(
        encodeInlineEmojiText(controller.text),
        source.replaceFirst(
            '[[bt-emoji:001]]', '[[bt-emoji:003]][[bt-emoji:001]]'));
    final added =
        tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-3')));
    final previous =
        tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-1')));
    final last =
        tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-2')));
    expect(added.dx, lessThan(previous.dx));
    expect(previous.dx, lessThan(last.dx));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
