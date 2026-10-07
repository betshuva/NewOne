import 'dart:convert';

import 'package:betshuva/inline_custom_emoji.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

const _catalog = [
  {'emoji': '😀', 'twemoji_code': '1f600', 'label_he': 'חיוך'},
  {'emoji': '❤️', 'twemoji_code': '2764', 'label_he': 'לב אדום'},
  {'emoji': '👍', 'twemoji_code': '1f44d', 'label_he': 'כל הכבוד'},
];
const _svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36">'
    '<circle cx="18" cy="18" r="16" fill="#ffcc4d"/></svg>';

class _EmojiBundle extends CachingAssetBundle {
  _EmojiBundle(
      {this.catalog = _catalog,
      this.failCatalog = false,
      this.failImages = false});

  final Object catalog;
  final bool failCatalog;
  final bool failImages;
  int catalogReads = 0;
  final imageReads = <String>[];

  @override
  Future<ByteData> load(String key) async {
    if (key == 'assets/twemoji/emoji_allowlist.json') {
      catalogReads++;
      if (failCatalog) throw StateError('catalog unavailable');
      return ByteData.sublistView(
          Uint8List.fromList(utf8.encode(jsonEncode(catalog))));
    }
    imageReads.add(key);
    if (failImages) throw StateError('artwork unavailable');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(_svg)));
  }
}

Future<void> _show(
  WidgetTester tester,
  String text, {
  _EmojiBundle? bundle,
  bool message = true,
  double scale = 1,
  double width = 400,
  int? maxLines,
  TextOverflow? overflow,
}) async {
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: DefaultAssetBundle(
    bundle: bundle ?? _EmojiBundle(),
    child: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: SizedBox(
            width: width,
            child: InlineEmojiText(
              text,
              messageEmojis: message,
              style: const TextStyle(fontSize: 14, height: 1.45),
              textAlign: TextAlign.right,
              textDirection: TextDirection.rtl,
              maxLines: maxLines,
              overflow: overflow,
            )),
      ),
    ),
  ))));
  await tester.pumpAndSettle();
}

Size _paintedSize(WidgetTester tester, Finder finder) {
  final box = tester.renderObject<RenderBox>(finder);
  final origin = box.localToGlobal(Offset.zero);
  final corner = box.localToGlobal(box.size.bottomRight(Offset.zero));
  return Size((corner.dx - origin.dx).abs(), (corner.dy - origin.dy).abs());
}

Finder get _messageText => find.byWidgetPredicate((widget) => widget is Text);

RenderParagraph _messageParagraph(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(find
        .descendant(
          of: find.byType(InlineEmojiText).first,
          matching: find.byWidgetPredicate((widget) => widget is RichText),
        )
        .first);

Rect _wordRect(WidgetTester tester, String word) {
  final paragraph = _messageParagraph(tester);
  final plain = paragraph.text.toPlainText(includeSemanticsLabels: false);
  final offset = plain.indexOf(word);
  expect(offset, greaterThanOrEqualTo(0));
  final box = paragraph
      .getBoxesForSelection(
          TextSelection(baseOffset: offset, extentOffset: offset + word.length))
      .single
      .toRect();
  return Rect.fromPoints(paragraph.localToGlobal(box.topLeft),
      paragraph.localToGlobal(box.bottomRight));
}

Finder _artwork(String code) =>
    find.byKey(ValueKey('message-unicode-emoji-$code'));

void main() {
  for (final scenario in [
    (text: '😀', size: 40.0, count: 1),
    (text: '😀❤️', size: 36.0, count: 2),
    (text: '😀 ❤️ 👍', size: 32.0, count: 3),
    (text: '😀❤️👍😀', size: 18.9, count: 4),
  ]) {
    testWidgets('enlarges only 1–3 emoji: ${scenario.text}', (tester) async {
      await _show(tester, scenario.text);
      final emoji = find.byType(SvgPicture);
      expect(emoji, findsNWidgets(scenario.count));
      for (final picture in tester.widgetList<SvgPicture>(emoji)) {
        expect(picture.width, closeTo(scenario.size, 0.001));
        expect(picture.height, closeTo(scenario.size, 0.001));
        expect(picture.colorFilter, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mixed Hebrew remains compact, accessible and RTL',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _show(tester, 'שלום 😀 עולם');
    expect(tester.widget<SvgPicture>(find.byType(SvgPicture)).width,
        closeTo(18.9, 0.001));
    final text = tester.widget<Text>(_messageText.last);
    expect(text.style?.fontSize, 14);
    expect(text.textDirection, TextDirection.rtl);
    expect(text.textAlign, TextAlign.right);
    expect(find.bySemanticsLabel(RegExp('חיוך 😀')), findsOneWidget);
    expect(
        tester.widget<InlineEmojiText>(find.byType(InlineEmojiText).first).text,
        'שלום 😀 עולם');
    semantics.dispose();
  });

  testWidgets('distinct artwork stays beside its correct Hebrew words',
      (tester) async {
    await _show(tester, 'שלום 😀 עולם ❤️');
    final hello = _wordRect(tester, 'שלום');
    final world = _wordRect(tester, 'עולם');
    final smile = tester.getRect(_artwork('1f600'));
    final heart = tester.getRect(_artwork('2764'));
    expect(hello.left, greaterThan(smile.right));
    expect(smile.left, greaterThan(world.right));
    expect(world.left, greaterThan(heart.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Latin in an RTL paragraph keeps Unicode bidirectional order',
      (tester) async {
    await _show(tester, 'hello 😀 world ❤️');
    final hello = _wordRect(tester, 'hello');
    final world = _wordRect(tester, 'world');
    final smile = tester.getRect(_artwork('1f600'));
    final heart = tester.getRect(_artwork('2764'));
    // The trailing neutral heart is on the RTL side of the English run.
    expect(heart.right, lessThan(hello.left));
    expect(hello.right, lessThan(smile.left));
    expect(smile.right, lessThan(world.left));
    expect(tester.takeException(), isNull);
  });

  testWidgets('separate message sizes retain multiline artwork order',
      (tester) async {
    final bundle = _EmojiBundle();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DefaultAssetBundle(
      bundle: bundle,
      child: const Directionality(
          textDirection: TextDirection.rtl,
          child: Column(
            children: [
              SizedBox(
                  key: ValueKey('single'),
                  width: 55,
                  child: InlineEmojiText('😀', messageEmojis: true)),
              SizedBox(
                  key: ValueKey('wrapped-pair'),
                  width: 55,
                  child: InlineEmojiText('😀 ❤️', messageEmojis: true)),
              SizedBox(
                  key: ValueKey('multiline-triple'),
                  width: 90,
                  child: InlineEmojiText('😀 ❤️\n👍', messageEmojis: true)),
            ],
          )),
    ))));
    await tester.pumpAndSettle();
    Finder inMessage(String message, String code) => find.descendant(
        of: find.byKey(ValueKey(message)), matching: _artwork(code));
    expect(
        _paintedSize(tester, inMessage('single', '1f600')), const Size(40, 40));
    final pairSmile = tester.getRect(inMessage('wrapped-pair', '1f600'));
    final pairHeart = tester.getRect(inMessage('wrapped-pair', '2764'));
    expect(pairSmile.size, const Size(36, 36));
    expect(pairHeart.size, const Size(36, 36));
    expect(pairSmile.bottom, lessThanOrEqualTo(pairHeart.top));
    final tripleSmile = tester.getRect(inMessage('multiline-triple', '1f600'));
    final tripleHeart = tester.getRect(inMessage('multiline-triple', '2764'));
    final tripleThumb = tester.getRect(inMessage('multiline-triple', '1f44d'));
    for (final rect in [tripleSmile, tripleHeart, tripleThumb]) {
      expect(rect.size, const Size(32, 32));
    }
    expect(tripleSmile.left, greaterThan(tripleHeart.right));
    expect(tripleSmile.bottom, lessThanOrEqualTo(tripleThumb.top));
    expect(tripleHeart.bottom, lessThanOrEqualTo(tripleThumb.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('maxLines hides omitted artwork within the visible paragraph',
      (tester) async {
    await _show(tester, 'שלום 😀 עולם ❤️ עוד מילים 👍',
        width: 120, maxLines: 1, overflow: TextOverflow.ellipsis);
    final paragraph = _messageParagraph(tester);
    final bounds = Rect.fromPoints(paragraph.localToGlobal(Offset.zero),
        paragraph.localToGlobal(paragraph.size.bottomRight(Offset.zero)));
    var visible = 0;
    for (final code in ['1f600', '2764', '1f44d']) {
      final box = tester.renderObject<RenderBox>(_artwork(code));
      final start = box.localToGlobal(Offset.zero);
      final end = box.localToGlobal(box.size.bottomRight(Offset.zero));
      // Flutter zeroes the paint transform of ellipsized inline children.
      if (!start.dx.isFinite || !end.dx.isFinite) continue;
      visible++;
      expect(start.dx, greaterThanOrEqualTo(bounds.left - 0.001));
      expect(end.dx, lessThanOrEqualTo(bounds.right + 0.001));
      expect(start.dy, greaterThanOrEqualTo(bounds.top - 0.001));
      expect(end.dy, lessThanOrEqualTo(bounds.bottom + 0.001));
    }
    expect(visible, lessThan(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('artwork ordering adapts after width reflow', (tester) async {
    final bundle = _EmojiBundle();
    const source = 'שלום 😀 עולם ❤️';
    await _show(tester, source, bundle: bundle);
    expect(tester.getCenter(_artwork('1f600')).dx,
        greaterThan(tester.getCenter(_artwork('2764')).dx));
    await _show(tester, source, bundle: bundle, width: 105);
    expect(tester.getCenter(_artwork('1f600')).dy,
        lessThan(tester.getCenter(_artwork('2764')).dy));
    await _show(tester, source, bundle: bundle);
    expect(tester.getCenter(_artwork('1f600')).dx,
        greaterThan(tester.getCenter(_artwork('2764')).dx));
    expect(tester.takeException(), isNull);
  });

  testWidgets('two visible ellipsized icons retain their distinct identities',
      (tester) async {
    await _show(tester, 'שלום 😀 עולם ❤️ עוד מילים 👍',
        width: 250, maxLines: 1, overflow: TextOverflow.ellipsis);
    final hello = _wordRect(tester, 'שלום');
    final world = _wordRect(tester, 'עולם');
    final smile = tester.getRect(_artwork('1f600'));
    final heart = tester.getRect(_artwork('2764'));
    expect(smile.left.isFinite, isTrue);
    expect(heart.left.isFinite, isTrue);
    expect(hello.left, greaterThan(smile.right));
    expect(smile.left, greaterThan(world.right));
    expect(world.left, greaterThan(heart.right));
    final thumb = tester.renderObject<RenderBox>(_artwork('1f44d'));
    expect(thumb.localToGlobal(Offset.zero).dx.isFinite, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixed Hebrew and Latin keep icon identity after soft wrap',
      (tester) async {
    await _show(tester, 'שלום 😀 hello ❤️ עולם 👍 טוב', width: 240);
    final smile = tester.getRect(_artwork('1f600'));
    final heart = tester.getRect(_artwork('2764'));
    final thumb = tester.getRect(_artwork('1f44d'));
    expect(smile.top, closeTo(heart.top, 0.01));
    expect(smile.left, greaterThan(heart.right));
    expect(smile.bottom, lessThanOrEqualTo(thumb.top));
    expect(heart.bottom, lessThanOrEqualTo(thumb.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('artwork identities refresh when the message source changes',
      (tester) async {
    final bundle = _EmojiBundle();
    await _show(tester, 'שלום 😀 עולם ❤️', bundle: bundle);
    expect(tester.getCenter(_artwork('1f600')).dx,
        greaterThan(tester.getCenter(_artwork('2764')).dx));
    await _show(tester, 'שלום ❤️ עולם 😀', bundle: bundle);
    final hello = _wordRect(tester, 'שלום');
    final world = _wordRect(tester, 'עולם');
    final smile = tester.getRect(_artwork('1f600'));
    final heart = tester.getRect(_artwork('2764'));
    expect(hello.left, greaterThan(heart.right));
    expect(heart.left, greaterThan(world.right));
    expect(world.left, greaterThan(smile.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('replies and previews keep their compact default',
      (tester) async {
    final bundle = _EmojiBundle();
    await _show(tester, '😀', bundle: bundle, message: false);
    expect(find.byType(SvgPicture), findsNothing);
    expect(tester.widget<Text>(find.text('😀')).style?.fontSize, 14);
    expect(bundle.catalogReads, 0);
  });

  testWidgets('variation selector hearts use approved artwork', (tester) async {
    await _show(tester, '❤ ❤️');
    expect(find.byKey(const ValueKey('message-unicode-emoji-2764')),
        findsNWidgets(2));
    for (final svg in tester.widgetList<SvgPicture>(find.byType(SvgPicture))) {
      expect(svg.width, 36);
    }
  });

  testWidgets(
      'unsupported full graphemes are preserved without partial artwork',
      (tester) async {
    for (final text in ['👍🏽', '👩‍💻', '🇮🇱', '1️⃣', '❤\uFE0E', '123 אבג']) {
      await _show(tester, text);
      expect(find.byType(SvgPicture), findsNothing, reason: text);
      expect(find.text(text), findsOneWidget, reason: text);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('unavailable catalog preserves readable Unicode', (tester) async {
    await _show(tester, '😀', bundle: _EmojiBundle(failCatalog: true));
    expect(find.text('😀'), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable artwork falls back to readable enlarged Unicode',
      (tester) async {
    await _show(tester, '😀', bundle: _EmojiBundle(failImages: true));
    expect(find.text('😀'), findsOneWidget);
    expect(tester.widget<Text>(find.text('😀')).style?.height, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid catalog paths cannot load arbitrary assets',
      (tester) async {
    final bundle = _EmojiBundle(catalog: [
      {'emoji': '😀', 'twemoji_code': '../other', 'label_he': 'invalid'},
    ]);
    await _show(tester, '😀', bundle: bundle);
    expect(bundle.imageReads, isEmpty);
    expect(find.text('😀'), findsOneWidget);
  });

  testWidgets('three enlarged emoji fit narrow width with scaled text',
      (tester) async {
    await _show(tester, '😀 ❤️ 👍', scale: 2.5, width: 220);
    expect(find.byType(SvgPicture), findsNWidgets(3));
    for (final code in ['1f600', '2764', '1f44d']) {
      final image = find.byKey(ValueKey('message-unicode-emoji-$code'));
      final size = _paintedSize(tester, image);
      expect(size.width, closeTo(80, 0.001));
      expect(size.height, closeTo(80, 0.001));
    }
    expect(tester.takeException(), isNull);
    expect(tester.getSize(_messageText.last).width, lessThanOrEqualTo(220));
  });

  testWidgets('Unicode fallback is scaled exactly once', (tester) async {
    await _show(tester, '😀',
        bundle: _EmojiBundle(failImages: true), scale: 2.5, width: 220);
    final image = find.byKey(const ValueKey('message-unicode-emoji-1f600'));
    final size = _paintedSize(tester, image);
    expect(size.width, closeTo(100, 0.001));
    expect(size.height, closeTo(100, 0.001));
    expect(
        tester.widget<Text>(find.text('😀')).textScaler, TextScaler.noScaling);
    expect(tester.widget<Text>(find.text('😀')).style?.height, 1);
    expect(find.byType(SvgPicture), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog is loaded once for multiple message bodies',
      (tester) async {
    final bundle = _EmojiBundle();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: DefaultAssetBundle(
      bundle: bundle,
      child: const Column(children: [
        InlineEmojiText('😀', messageEmojis: true),
        InlineEmojiText('👍', messageEmojis: true),
      ]),
    ))));
    await tester.pumpAndSettle();
    expect(bundle.catalogReads, 1);
    expect(find.byType(SvgPicture), findsNWidgets(2));
  });
}
