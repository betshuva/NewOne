import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:betshuva/inline_custom_emoji.dart';

void main() {
  testWidgets('Hebrew composer isolates Unicode emoji in selection order', (tester) async {
    final controller = InlineEmojiController(isolateEmojiRuns: true, text: 'שלום 😀👍❤️');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TextField(
      controller: controller, textDirection: TextDirection.rtl,
    ))));
    final editable = tester.state<EditableTextState>(find.byType(EditableText)).renderEditable;
    final positions = [
      for (final range in [(6, 8), (8, 10), (10, 12)])
        editable.getBoxesForSelection(TextSelection(baseOffset: range.$1, extentOffset: range.$2)).single.left,
    ];
    expect(positions[0], lessThan(positions[1]));
    expect(positions[1], lessThan(positions[2]));
    expect(encodeInlineEmojiText(controller.text), 'שלום 😀👍❤️');
    controller.selection = TextSelection.collapsed(offset: controller.text.length);
    expect(controller.selection.extentOffset, 13); // Outside the run, on its visual left.
    final caret = [for (final offset in [6, 8, 10, 12])
      editable.getLocalRectForCaret(TextPosition(offset: offset,
        affinity: offset == 12 ? TextAffinity.upstream : TextAffinity.downstream)).left];
    for (var i = 0; i < 3; i++) expect(caret[i], lessThan(caret[i + 1]));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test('editor isolates are idempotent and omitted from persisted messages', () {
    final controller = InlineEmojiController(isolateEmojiRuns: true);
    final raw = 'שלום ${inlineEmojiCharacter(1)}${inlineEmojiCharacter(2)} עולם';
    controller.value = TextEditingValue(text: raw, selection: const TextSelection.collapsed(offset: 7));
    final first = controller.value;
    controller.value = first;
    expect(controller.value, first);
    expect(inlineEmojiPlainText(controller.text), raw);
    expect(encodeInlineEmojiText(controller.text), 'שלום [[bt-emoji:001]][[bt-emoji:002]] עולם');
    // Simulate backspace at the end of the run, then type another emoji.
    final cursor = controller.selection.extentOffset;
    controller.value = controller.value.copyWith(
      text: controller.text.replaceRange(cursor - 1, cursor, ''),
      selection: TextSelection.collapsed(offset: cursor - 1));
    expect(inlineEmojiPlainText(controller.text), 'שלום ${inlineEmojiCharacter(2)} עולם');
    final next = controller.selection.extentOffset;
    controller.value = controller.value.copyWith(
      text: controller.text.replaceRange(next, next, inlineEmojiCharacter(3)),
      selection: TextSelection.collapsed(offset: next + 1));
    expect(encodeInlineEmojiText(controller.text), 'שלום [[bt-emoji:003]][[bt-emoji:002]] עולם');
    controller.dispose();
  });

  testWidgets('consecutive custom emoji read LTR without changing Hebrew or stored text', (tester) async {
    const source = 'שלום [[bt-emoji:001]][[bt-emoji:002]][[bt-emoji:003]] עולם';
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: InlineEmojiText(source,
      textDirection: TextDirection.rtl, textAlign: TextAlign.right))));
    final positions = [for (final id in [1,2,3]) tester.getCenter(find.byKey(ValueKey('inline-custom-emoji-$id'))).dx];
    expect(positions[0], lessThan(positions[1]));
    expect(positions[1], lessThan(positions[2]));
    expect(encodeInlineEmojiText(decodeInlineEmojiText(source)), source);
  });
  test('draft direction starts on the right for text and emoji', () {
    expect(inlineEmojiDraftDirection(''), TextDirection.rtl);
    expect(inlineEmojiDraftDirection('שלום'), TextDirection.rtl);
    expect(inlineEmojiDraftDirection('שלום ${inlineEmojiCharacter(1)}'), TextDirection.rtl);
    expect(inlineEmojiDraftDirection(inlineEmojiCharacter(1)), TextDirection.rtl);
    expect(inlineEmojiDraftDirection('😀❤️'), TextDirection.rtl);
  });

  test('all 150 custom images round-trip without changing ordinary Unicode',
      () {
    final images =
        List.generate(150, (index) => inlineEmojiCharacter(index + 1));
    final editor = 'שלום 😀 ${images.join()} סוף';
    final wire = encodeInlineEmojiText(editor);
    expect(wire, startsWith('שלום 😀 [[bt-emoji:001]]'));
    expect(wire, endsWith('[[bt-emoji:150]] סוף'));
    expect(decodeInlineEmojiText(wire), editor);
    expect(images.every((image) => image.length == 1), isTrue);
    expect(images.toSet(), hasLength(150));
    expect(encodeInlineEmojiText(wire), wire);
  });

  test(
      'unknown or malformed markers and unrelated private-use text stay literal',
      () {
    const text = '[[bt-emoji:000]] [[bt-emoji:151]] [[bt-emoji:999]] '
        '[[bt-emoji:01]] [[bt-emoji:0001]] [[BT-emoji:001]] '
        '[[bt-emoji:001] \uE096 \uF000';
    expect(decodeInlineEmojiText(text), text);
    expect(encodeInlineEmojiText(text), text);
    expect(() => inlineEmojiCharacter(0), throwsRangeError);
    expect(() => inlineEmojiCharacter(151), throwsRangeError);
  });

  test('URL recognition accepts only exact known artwork on the fixed origin',
      () {
    const base = '/betshuva-app/expression-library/user-20260907';
    expect(inlineEmojiIdFromUrl('$base/sticker-01.png'), 1);
    expect(
        inlineEmojiIdFromUrl('https://betshuva.com$base/sticker-99.png'), 99);
    expect(
        inlineEmojiIdFromUrl('https://betshuva.com:443$base/sticker-150.png'),
        150);
    const colored = '/betshuva-app/expression-library/user-20261008-color';
    for (var id = 1; id <= 150; id++) {
      final name = 'sticker-${id.toString().padLeft(2, '0')}.png';
      expect(inlineEmojiIdFromUrl('$colored/$name'), id);
      expect(inlineEmojiIdFromUrl('https://betshuva.com$colored/$name'), id);
    }
    for (final url in [
      'http://betshuva.com$base/sticker-01.png',
      'https://evil.test$base/sticker-01.png',
      'https://betshuva.com.evil.test$base/sticker-01.png',
      'https://name@betshuva.com$base/sticker-01.png',
      'https://betshuva.com:444$base/sticker-01.png',
      '//betshuva.com$base/sticker-01.png',
      'betshuva-app/expression-library/user-20260907/sticker-01.png',
      '$base/sticker-00.png',
      '$base/sticker-151.png',
      '$base/sticker-001.png',
      '$base/sticker-1.png',
      '$base/sticker-01.gif',
      '$base/sticker-01.png?redirect=https://evil.test',
      '$base/sticker-01.png#fragment',
      '$base/../user-20260907/sticker-01.png',
      '$base/%73ticker-01.png',
      '$base/sticker-%30%31.png',
      '$colored/sticker-001.png',
      '$colored/sticker-151.png',
      '$colored/sticker-01.png?v=1',
      '$colored/../user-20260907/sticker-01.png',
      'https://evil.test$colored/sticker-01.png',
    ]) {
      expect(inlineEmojiIdFromUrl(url), isNull, reason: url);
    }
  });

  test(
      'editing a saved message decodes artwork and retains reverse UTF-16 selection',
      () {
    final controller = InlineEmojiController();
    addTearDown(controller.dispose);
    const wire = '😀 אב [[bt-emoji:001]] ג [[bt-emoji:150]]';
    controller.value = TextEditingValue(
      text: wire,
      selection: TextSelection(
        baseOffset: wire.length,
        extentOffset: wire.indexOf('[[bt-emoji:001]]'),
        affinity: TextAffinity.upstream,
        isDirectional: true,
      ),
    );
    expect(controller.text,
        '😀 אב ${inlineEmojiCharacter(1)} ג ${inlineEmojiCharacter(150)}');
    expect(controller.selection.baseOffset, controller.text.length);
    expect(controller.selection.extentOffset, '😀 אב '.length);
    expect(controller.selection.affinity, TextAffinity.upstream);
    expect(controller.selection.isDirectional, isTrue);
    controller.text = 'x[[bt-emoji:001]]y';
    expect(controller.text, 'x${inlineEmojiCharacter(1)}y');
    expect(controller.selection.isValid, isFalse);
  });

  test(
      'cursor positions at a token boundary or inside a pasted token stay atomic',
      () {
    final controller = InlineEmojiController();
    addTearDown(controller.dispose);
    const wire = 'a[[bt-emoji:001]]z';
    for (final (original, expected) in [
      (0, 0),
      (1, 1),
      (6, 2),
      (17, 2),
      (18, 3)
    ]) {
      controller.value = TextEditingValue(
        text: wire,
        selection: TextSelection.collapsed(offset: original),
      );
      expect(controller.selection.extentOffset, expected);
      expect(controller.text, 'a${inlineEmojiCharacter(1)}z');
    }
  });

  test(
      'decoding outside an IME range shifts the range without changing composed text',
      () {
    final controller = InlineEmojiController();
    addTearDown(controller.dispose);
    const wire = '[[bt-emoji:002]] שלום';
    final start = wire.indexOf('שלום');
    controller.value = TextEditingValue(
      text: wire,
      selection: TextSelection.collapsed(offset: wire.length),
      composing: TextRange(start: start, end: wire.length),
    );
    expect(controller.text, '${inlineEmojiCharacter(2)} שלום');
    expect(controller.value.composing.textInside(controller.text), 'שלום');
    expect(controller.value.composing, const TextRange(start: 2, end: 6));
    expect(controller.selection.extentOffset, 6);
  });

  test('active IME token text is unchanged until composition commits', () {
    final controller = InlineEmojiController();
    addTearDown(controller.dispose);
    const wire = '[[bt-emoji:001]]';
    controller.value = const TextEditingValue(
      text: wire,
      selection: TextSelection.collapsed(offset: wire.length),
      composing: TextRange(start: 0, end: wire.length),
    );
    expect(controller.text, wire);
    expect(controller.value.composing,
        const TextRange(start: 0, end: wire.length));
    controller.value = controller.value.copyWith(composing: TextRange.empty);
    expect(controller.text, inlineEmojiCharacter(1));
    expect(controller.selection, const TextSelection.collapsed(offset: 1));
  });

  testWidgets(
      'EditableText lays out real inline artwork and backspace removes one image',
      (tester) async {
    final controller = InlineEmojiController(text: 'אב[[bt-emoji:001]]גד');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: TextField(
        controller: controller,
        textDirection: TextDirection.rtl,
        style: const TextStyle(fontSize: 16),
      )),
    ));
    await tester.tap(find.byType(TextField));
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.renderEditable.text!.toPlainText(), 'אב\uFFFCגד');
    expect(editable.renderEditable.text!.toPlainText().length,
        controller.text.length);
    final imageFinder = find.byKey(const ValueKey('inline-custom-emoji-1'));
    expect(imageFinder, findsOneWidget);
    final image = tester.widget<Image>(imageFinder);
    expect((image.image as NetworkImage).url,
        'https://betshuva.com/betshuva-app/expression-library/user-20261008-color/sticker-01.png');
    final size = tester.getSize(imageFinder);
    expect(size.width, closeTo(23.76, 0.1));
    expect(size.height, closeTo(23.76, 0.1));
    final before = editable.renderEditable
        .getLocalRectForCaret(const TextPosition(offset: 2));
    final after = editable.renderEditable
        .getLocalRectForCaret(const TextPosition(offset: 3));
    expect((before.left - after.left).abs(), greaterThanOrEqualTo(18));
    if (kIsWeb) {
      // Browser text editing arrives as a platform value update. A synthetic
      // Flutter key event does not invoke the DOM input's default Backspace
      // behavior, so deliver the value that deleting its one UTF-16 slot sends.
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'אבגד',
        selection: TextSelection.collapsed(offset: 2),
      ));
    } else {
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    }
    await tester.pump();
    expect(controller.text, 'אבגד');
    expect(controller.selection, const TextSelection.collapsed(offset: 2));
    expect(imageFinder, findsNothing);
    expect(editable.renderEditable.text!.toPlainText(), 'אבגד');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('composing text remains underlined next to the image',
      (tester) async {
    final controller = InlineEmojiController();
    controller.value = TextEditingValue(
      text: '${inlineEmojiCharacter(3)}אבג',
      selection: const TextSelection.collapsed(offset: 4),
      composing: const TextRange(start: 1, end: 4),
    );
    TextSpan? built;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      built = controller.buildTextSpan(
          context: context,
          style: const TextStyle(fontSize: 16),
          withComposing: true);
      return Text.rich(built!);
    })));
    expect(built!.children!.first, isA<WidgetSpan>());
    final text = built!.children!.last as TextSpan;
    expect(text.text, 'אבג');
    expect(text.style!.decoration, TextDecoration.underline);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
      'message rendering preserves artwork, clamps size and provides its label',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: Column(children: [
      InlineEmojiText('שלום [[bt-emoji:001]]', style: TextStyle(fontSize: 9)),
      InlineEmojiText('[[bt-emoji:150]] סוף',
          style: TextStyle(fontSize: 40),
          textDirection: TextDirection.rtl,
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
    ]))));
    expect(
        tester
            .getSize(find.byKey(const ValueKey('inline-custom-emoji-1')))
            .width,
        closeTo(19.8, 0.001));
    expect(
        tester
            .getSize(find.byKey(const ValueKey('inline-custom-emoji-150')))
            .width,
        closeTo(26.4, 0.001));
    expect(find.bySemanticsLabel(RegExp('שמחה')), findsOneWidget);
    expect(find.textContaining('[[bt-emoji:'), findsNothing);
    semantics.dispose();
  });

  testWidgets('ordinary and invalid-token text keeps the ordinary Text widget',
      (tester) async {
    const message = 'שלום 😀 [[bt-emoji:999]]';
    await tester.pumpWidget(const MaterialApp(
        home: InlineEmojiText(message,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis)));
    final text = tester.widget<Text>(find.text(message));
    expect(text.textSpan, isNull);
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.textAlign, TextAlign.end);
    expect(find.byType(Image), findsNothing);
  });
}
