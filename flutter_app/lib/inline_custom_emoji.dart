import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

// These IDs belong to the immutable, 150-image user-20260907 catalog. The
// editor uses one UTF-16 position per image; persisted text uses readable IDs.
const _emojiCount = 150;
const _emojiStart = 0xe000;
const _emojiOrigin = 'https://betshuva.com';
const _emojiPath = '/betshuva-app/expression-library/user-20260907';
const _coloredEmojiPath =
    '/betshuva-app/expression-library/user-20261008-color';
final _wireEmoji = RegExp(r'\[\[bt-emoji:([0-9]{3})\]\]');
final _editorEmoji = RegExp('[\uE000-\uE095]');

typedef _MessageEmojiArtwork = ({String code, String label});
final _messageEmojiCatalogs =
    Expando<Future<Map<String, _MessageEmojiArtwork>>>();
final _messageEmojiImages = Expando<Map<String, Future<String?>>>();

String _emojiCatalogKey(String emoji) => emoji.replaceAll('\uFE0F', '');

Future<Map<String, _MessageEmojiArtwork>> _messageEmojiCatalog(
    AssetBundle bundle) {
  return _messageEmojiCatalogs[bundle] ??= () async {
    try {
      final entries = jsonDecode(
          await bundle.loadString('assets/twemoji/emoji_allowlist.json'));
      if (entries is! List) return <String, _MessageEmojiArtwork>{};
      final result = <String, _MessageEmojiArtwork>{};
      for (final entry in entries) {
        if (entry is! Map) continue;
        final emoji = entry['emoji'];
        final code = entry['twemoji_code'];
        final label = entry['label_he'];
        if (emoji is! String ||
            emoji.isEmpty ||
            code is! String ||
            !RegExp(r'^[0-9a-f]+(?:-[0-9a-f]+)*$').hasMatch(code) ||
            label is! String) continue;
        result[_emojiCatalogKey(emoji)] = (code: code, label: label);
      }
      return result;
    } catch (_) {
      // A missing catalog must not hide a message or change its stored text.
      return <String, _MessageEmojiArtwork>{};
    }
  }();
}

Future<String?> _messageEmojiImage(AssetBundle bundle, String code) {
  final cache = _messageEmojiImages[bundle] ??= <String, Future<String?>>{};
  return cache.putIfAbsent(code, () async {
    try {
      return await bundle.loadString('assets/twemoji/svg/$code.svg');
    } catch (_) {
      // Catch asset transport errors before the SVG decoder caches the load.
      return null;
    }
  });
}

class _MessageEmojiImage extends StatelessWidget {
  const _MessageEmojiImage(
      {super.key,
      required this.code,
      required this.character,
      required this.size,
      required this.style});

  final String code;
  final String character;
  final double size;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    Widget fallback() => Center(
            child: Text(
          character,
          textScaler: TextScaler.noScaling,
          style: style.copyWith(fontSize: size, height: 1),
        ));
    return SizedBox.square(
      dimension: size,
      child: FutureBuilder<String?>(
        future: _messageEmojiImage(DefaultAssetBundle.of(context), code),
        builder: (context, snapshot) {
          final source = snapshot.data;
          if (source == null) return fallback();
          return SvgPicture.string(
            source,
            width: size,
            height: size,
            placeholderBuilder: (_) => fallback(),
            errorBuilder: (_, __, ___) => fallback(),
          );
        },
      ),
    );
  }
}

TextSpan _messageEmojiSpans(BuildContext context, String text,
    Map<String, _MessageEmojiArtwork> catalog, TextStyle? style) {
  final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
  final characters = text.characters.toList();
  final visible = characters.where((character) => character.trim().isNotEmpty);
  final count = visible.length;
  final emojiOnly = count >= 1 &&
      count <= 3 &&
      visible.every(
          (character) => catalog.containsKey(_emojiCatalogKey(character)));
  final baseSize = emojiOnly
      ? (count == 1
          ? 40.0
          : count == 2
              ? 36.0
              : 32.0)
      : ((effectiveStyle.fontSize ?? 14) * 1.35).clamp(18.0, 24.0).toDouble();
  // Text.rich scales WidgetSpan children with the surrounding text.
  final size = baseSize;
  final spans = <InlineSpan>[];
  final plain = StringBuffer();
  void flushPlain() {
    if (plain.isEmpty) return;
    spans
        .addAll(_emojiSpans(context, plain.toString(), style: style).children!);
    plain.clear();
  }

  for (final character in characters) {
    final artwork = catalog[_emojiCatalogKey(character)];
    if (artwork == null) {
      plain.write(character);
      continue;
    }
    flushPlain();
    spans.add(WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Semantics(
        label: '${artwork.label} $character',
        image: true,
        child: ExcludeSemantics(
          child: _MessageEmojiImage(
            key: ValueKey<String>('message-unicode-emoji-${artwork.code}'),
            code: artwork.code,
            character: character,
            size: size,
            style: effectiveStyle,
          ),
        ),
      ),
    ));
  }
  flushPlain();
  return TextSpan(style: style, children: spans);
}

// Flutter 3.47.1's SkParagraph puts placeholder runs in input order even in
// RTL visual runs (flutter/flutter#54400). Its placeholder selection boxes
// share the bug. A plain-text paragraph resolves the same neutral U+FFFC
// characters correctly; use only that ordering, retaining the real layout.
class _MessageEmojiText extends Text {
  const _MessageEmojiText.rich(super.textSpan,
      {super.style,
      super.textAlign,
      super.textDirection,
      super.maxLines,
      super.overflow})
      : super.rich();

  @override
  Widget build(BuildContext context) {
    final built = super.build(context);
    return built is RichText ? _MessageEmojiRichText(built) : built;
  }
}

class _MessageEmojiRichText extends RichText {
  _MessageEmojiRichText(RichText original)
      : super(
          text: original.text,
          textAlign: original.textAlign,
          textDirection: original.textDirection,
          softWrap: original.softWrap,
          overflow: original.overflow,
          textScaler: original.textScaler,
          maxLines: original.maxLines,
          locale: original.locale,
          strutStyle: original.strutStyle,
          textWidthBasis: original.textWidthBasis,
          textHeightBehavior: original.textHeightBehavior,
          selectionRegistrar: original.selectionRegistrar,
          selectionColor: original.selectionColor,
        );

  @override
  RenderParagraph createRenderObject(BuildContext context) =>
      _MessageEmojiParagraph(
        text,
        textAlign: textAlign,
        textDirection: textDirection ?? Directionality.of(context),
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        locale: locale ?? Localizations.maybeLocaleOf(context),
        strutStyle: strutStyle,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        registrar: selectionRegistrar,
        selectionColor: selectionColor,
        devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ??
            View.maybeOf(context)?.devicePixelRatio ??
            1,
      );
}

class _MessageEmojiParagraph extends RenderParagraph {
  _MessageEmojiParagraph(super.text,
      {required super.textDirection,
      super.textAlign,
      super.softWrap,
      super.overflow,
      super.textScaler,
      super.maxLines,
      super.locale,
      super.strutStyle,
      super.textWidthBasis,
      super.textHeightBehavior,
      super.registrar,
      super.selectionColor,
      super.devicePixelRatio});

  InlineSpan? _referenceSpan;
  TextDirection? _referenceDirection;
  final _reference = TextPainter(textAlign: TextAlign.left);
  List<double?> _visualPositions = const [];

  void _updateVisualPositions() {
    if (identical(text, _referenceSpan) && textDirection == _referenceDirection)
      return;
    final plain = text.toPlainText(includeSemanticsLabels: false);
    _referenceSpan = text;
    _referenceDirection = textDirection;
    final offsets = <int>[];
    var offset = 0;
    text.visitChildren((span) {
      if (span is TextSpan) {
        offset += span.text?.length ?? 0;
      } else if (span is PlaceholderSpan) {
        offsets.add(offset++);
      }
      return true;
    });
    _reference
      ..text = TextSpan(text: plain, style: const TextStyle(fontSize: 14))
      ..textDirection = textDirection
      ..layout();
    _visualPositions = offsets.map((offset) {
      final boxes = _reference.getBoxesForSelection(
          TextSelection(baseOffset: offset, extentOffset: offset + 1));
      return boxes.length == 1 ? boxes.single.left : null;
    }).toList();
  }

  @override
  void positionInlineChildren(List<ui.TextBox> boxes) {
    if (boxes.length < 2) {
      super.positionInlineChildren(boxes);
      return;
    }
    _updateVisualPositions();
    final ordered = List<ui.TextBox>.of(boxes);
    var start = 0;
    while (start < boxes.length) {
      var end = start + 1;
      while (end < boxes.length &&
          (boxes[end].top - boxes[start].top).abs() < 0.01) {
        end++;
      }
      final indices = [for (var i = start; i < end; i++) i];
      // Message artwork has the same dimensions within each paragraph.
      // Skip an ambiguous/ellipsized group instead of shifting identities.
      final complete = indices.every((i) =>
          i < _visualPositions.length &&
          _visualPositions[i] != null &&
          (boxes[i].toRect().width - boxes[start].toRect().width).abs() <
              0.01 &&
          (boxes[i].toRect().height - boxes[start].toRect().height).abs() <
              0.01);
      if (indices.length > 1 && complete) {
        final visualBoxes = indices.map((i) => boxes[i]).toList()
          ..sort((a, b) => a.left.compareTo(b.left));
        indices.sort(
            (a, b) => _visualPositions[a]!.compareTo(_visualPositions[b]!));
        for (var i = 0; i < indices.length; i++) {
          ordered[indices[i]] = visualBoxes[i];
        }
      }
      start = end;
    }
    super.positionInlineChildren(ordered);
  }

  @override
  void systemFontsDidChange() {
    _referenceSpan = null;
    _reference.markNeedsLayout();
    super.systemFontsDidChange();
  }

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }
}

bool _validEmojiId(int id) => id >= 1 && id <= _emojiCount;

String inlineEmojiCharacter(int id) {
  if (!_validEmojiId(id)) throw RangeError.range(id, 1, _emojiCount, 'id');
  return String.fromCharCode(_emojiStart + id - 1);
}

int? _emojiIdAt(String text, int offset) {
  final id = text.codeUnitAt(offset) - _emojiStart + 1;
  return _validEmojiId(id) ? id : null;
}

String _imagePath(int id) =>
    '$_coloredEmojiPath/sticker-${id.toString().padLeft(2, '0')}.png';

/// Recognizes the same immutable IDs in the original and colored catalogs.
/// Arbitrary image URLs never become decorative text tokens.
int? inlineEmojiIdFromUrl(String value) {
  // Match the original string before URI normalization can resolve dot
  // segments or decode percent escapes into a supported catalog path.
  final match = RegExp(
    '^(?:https://betshuva\\.com(?::443)?)?'
    '((?:${RegExp.escape(_emojiPath)}|${RegExp.escape(_coloredEmojiPath)})'
    '/sticker-([0-9]{2,3})\\.png)\$',
  ).firstMatch(value);
  final id = int.tryParse(match?.group(2) ?? '');
  if (id == null || !_validEmojiId(id)) return null;
  final name = 'sticker-${id.toString().padLeft(2, '0')}.png';
  if (![_emojiPath, _coloredEmojiPath]
      .any((folder) => match?.group(1) == '$folder/$name')) {
    return null;
  }
  return id;
}

String encodeInlineEmojiText(String text) => text.replaceAllMapped(
      _editorEmoji,
      (match) =>
          '[[bt-emoji:${(_emojiIdAt(match[0]!, 0)!).toString().padLeft(3, '0')}]]',
    );

String decodeInlineEmojiText(String text) => text.replaceAllMapped(
      _wireEmoji,
      (match) {
        final id = int.parse(match[1]!);
        return _validEmojiId(id) ? inlineEmojiCharacter(id) : match[0]!;
      },
    );

TextEditingValue _decodeEditingValue(TextEditingValue incoming) {
  final replacements = <({int start, int end, String character})>[];
  final composing = incoming.composing;
  for (final match in _wireEmoji.allMatches(incoming.text)) {
    final id = int.parse(match[1]!);
    if (!_validEmojiId(id)) continue;
    // Do not rewrite the text an IME is still composing. Once it commits,
    // the next value update can safely turn the completed token into an image.
    if (incoming.isComposingRangeValid &&
        !composing.isCollapsed &&
        match.start < composing.end &&
        match.end > composing.start) {
      continue;
    }
    replacements.add((
      start: match.start,
      end: match.end,
      character: inlineEmojiCharacter(id),
    ));
  }
  if (replacements.isEmpty) return incoming;
  final decoded = StringBuffer();
  var previousEnd = 0;
  for (final replacement in replacements) {
    decoded
      ..write(incoming.text.substring(previousEnd, replacement.start))
      ..write(replacement.character);
    previousEnd = replacement.end;
  }
  decoded.write(incoming.text.substring(previousEnd));
  int offset(int original) {
    if (original < 0) return original;
    var removed = 0;
    for (final replacement in replacements) {
      if (original <= replacement.start) return original - removed;
      if (original < replacement.end) return replacement.start - removed + 1;
      removed += replacement.end - replacement.start - 1;
    }
    return original - removed;
  }

  return incoming.copyWith(
    text: decoded.toString(),
    selection: TextSelection(
      baseOffset: offset(incoming.selection.baseOffset),
      extentOffset: offset(incoming.selection.extentOffset),
      affinity: incoming.selection.affinity,
      isDirectional: incoming.selection.isDirectional,
    ),
    composing: composing.isValid
        ? TextRange(start: offset(composing.start), end: offset(composing.end))
        : TextRange.empty,
  );
}

class InlineEmojiController extends TextEditingController {
  InlineEmojiController({String? text})
      : super(text: decodeInlineEmojiText(text ?? ''));

  @override
  set value(TextEditingValue newValue) {
    super.value = _decodeEditingValue(newValue);
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) =>
      _emojiSpans(
        context,
        text,
        style: style,
        composing: withComposing && value.isComposingRangeValid
            ? value.composing
            : TextRange.empty,
      );
}

TextSpan _emojiSpans(
  BuildContext context,
  String text, {
  TextStyle? style,
  TextRange composing = TextRange.empty,
}) {
  final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
  final size =
      ((effectiveStyle.fontSize ?? 14) * 1.35).clamp(18.0, 24.0).toDouble();
  final spans = <InlineSpan>[];
  var offset = 0;
  while (offset < text.length) {
    final id = _emojiIdAt(text, offset);
    final inComposing = composing.isValid &&
        offset >= composing.start &&
        offset < composing.end;
    final segmentStyle = inComposing
        ? const TextStyle(decoration: TextDecoration.underline)
        : null;
    if (id != null) {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        style: segmentStyle,
        child: Semantics(
          label: _emojiLabels[id - 1],
          image: true,
          child: ExcludeSemantics(
            child: SizedBox.square(
              dimension: size,
              child: Image.network(
                '$_emojiOrigin${_imagePath(id)}',
                key: ValueKey<String>('inline-custom-emoji-$id'),
                width: size,
                height: size,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.broken_image_outlined,
                  size: size,
                  color: effectiveStyle.color,
                ),
              ),
            ),
          ),
        ),
      ));
      offset++;
      continue;
    }
    final start = offset++;
    while (offset < text.length &&
        _emojiIdAt(text, offset) == null &&
        offset != composing.start &&
        offset != composing.end) {
      offset++;
    }
    spans.add(
        TextSpan(text: text.substring(start, offset), style: segmentStyle));
  }
  return TextSpan(style: style, children: spans);
}

/// Shared rendering; replies, previews and drafts stay compact by default.
class InlineEmojiText extends StatelessWidget {
  const InlineEmojiText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.maxLines,
    this.overflow,
    this.messageEmojis = false,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final int? maxLines;
  final TextOverflow? overflow;

  /// Color Unicode emoji in message bodies and enlarge 1–3 emoji alone.
  final bool messageEmojis;

  @override
  Widget build(BuildContext context) {
    final decoded = decodeInlineEmojiText(text);
    if (messageEmojis) {
      return FutureBuilder<Map<String, _MessageEmojiArtwork>>(
        future: _messageEmojiCatalog(DefaultAssetBundle.of(context)),
        builder: (context, snapshot) {
          final catalog = snapshot.data;
          if (catalog == null ||
              !decoded.characters.any((character) =>
                  catalog.containsKey(_emojiCatalogKey(character)))) {
            return InlineEmojiText(text,
                style: style,
                textAlign: textAlign,
                textDirection: textDirection,
                maxLines: maxLines,
                overflow: overflow);
          }
          return _MessageEmojiText.rich(
            _messageEmojiSpans(context, decoded, catalog, style),
            style: style,
            textAlign: textAlign,
            textDirection: textDirection,
            maxLines: maxLines,
            overflow: overflow,
          );
        },
      );
    }
    if (!_editorEmoji.hasMatch(decoded)) {
      return Text(
        text,
        style: style,
        textAlign: textAlign,
        textDirection: textDirection,
        maxLines: maxLines,
        overflow: overflow,
      );
    }
    return Text.rich(
      _emojiSpans(context, decoded, style: style),
      style: style,
      textAlign: textAlign,
      textDirection: textDirection,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

// Accessibility names from assets/stickers/user-catalog.json. Image files stay
// in the existing same-origin catalog; no extra copy of the artwork is bundled.
const _emojiLabels = <String>[
  "שמחה",
  "צחוק",
  "חיוך",
  "קריצה",
  "נשיקה",
  "שלווה",
  "אהבה",
  "התרגשות",
  "עיניים נוצצות",
  "הפתעה",
  "ספק",
  "מחשבה",
  "רוגע",
  "דאגה",
  "בכי",
  "תסכול",
  "לב ורוד",
  "לבבות",
  "כל הכבוד",
  "מצוין",
  "מחיאות כפיים",
  "תודה",
  "שלום",
  "כוח",
  "אישור",
  "נצנוצים",
  "כוכב",
  "זיקוקים",
  "בלון",
  "מתנה",
  "חגיגה",
  "דגלונים",
  "שמש",
  "זריחה",
  "ירח",
  "לילה",
  "ענן",
  "ענף",
  "פרח",
  "עלים",
  "בית",
  "דלת פתוחה",
  "חלון",
  "פנס",
  "דרך",
  "קפה",
  "ספר",
  "לב וענף",
  "שבת שלום",
  "חג שמח",
  "שבוע טוב",
  "בוקר טוב",
  "לילה טוב",
  "יום טוב ומבורך",
  "בשורות טובות",
  "מזל טוב",
  "הולדת בן",
  "הולדת בת",
  "חתן וכלה",
  "שמחת תורה",
  "סוכות שמח",
  "חג סוכות שמח",
  "גמר חתימה טובה",
  "שנה טובה",
  "חנוכה שמח",
  "חג חנוכה שמח",
  "חג פסח שמח",
  "חג שבועות שמח",
  "פורים שמח",
  "ט״ו בשבט שמח",
  "צום מועיל",
  "עם ישראל חי",
  "קפה טוב",
  "תודה",
  "שמחים לשמוע",
  "כל הכבוד",
  "בריאות טובה",
  "פרנסה טובה",
  "דלתות טובות",
  "שמור על עצמך",
  "שת״פ פורה",
  "הצלחה גדולה",
  "המשך כך",
  "יום נעים",
  "חג שמח בלונים",
  "מתגעגעים",
  "שלום",
  "תמיד איתכם",
  "בהצלחה",
  "מזל וברכה",
  "גם זה יעבור",
  "עוד נגיע",
  "דרך צלחה",
  "רגע של מנוחה",
  "גוט שאבעס",
  "תמיד בבית",
  "הבית של בתשובה",
  "רגע",
  "מחכה לתשובה",
  "קיבלתי",
  "שלחתי",
  "התקבל",
  "התראה",
  "בודק",
  "קפה בדרך",
  "בשורות טובות",
  "תפילה בשבילך",
  "לימוד פורה",
  "תשובה בהצלחה",
  "רעיון טוב",
  "שאלה טובה",
  "מעולה",
  "תודה רבה",
  "יישר כוח",
  "הפתעה",
  "מגיע",
  "בדרך",
  "הגעתי",
  "נמצא בדרך",
  "בהכוונה",
  "כמעט שם",
  "נטען",
  "מתארגן",
  "לילה טוב",
  "יום נפלא",
  "מזג אוויר נעים",
  "הכול לטובה",
  "צמיחה והצלחה",
  "עוד צעד קדימה",
  "מגיעים רחוק",
  "הצלחה גדולה",
  "יקר מפז",
  "כוכב",
  "שמור עליך",
  "שלום",
  "נתראה",
  "אהבתי",
  "מזל טוב",
  "יום הולדת שמח",
  "פינוק",
  "תודה",
  "דלתות טובות",
  "יום טוב",
  "רק בשמחות",
  "לילה טוב",
  "תודה",
  "הדרך טובה",
  "תמיד יש אור",
  "ישראל כאן בשבילך",
  "זהירות מקישור לא ידוע",
];
