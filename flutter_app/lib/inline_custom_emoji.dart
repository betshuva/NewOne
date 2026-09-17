import 'package:flutter/material.dart';

// These IDs belong to the immutable, 150-image user-20260907 catalog. The
// editor uses one UTF-16 position per image; persisted text uses readable IDs.
const _emojiCount = 150;
const _emojiStart = 0xe000;
const _emojiOrigin = 'https://betshuva.com';
const _emojiPath = '/betshuva-app/expression-library/user-20260907';
final _wireEmoji = RegExp(r'\[\[bt-emoji:([0-9]{3})\]\]');
final _editorEmoji = RegExp('[\uE000-\uE095]');

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
    '$_emojiPath/sticker-${id.toString().padLeft(2, '0')}.png';

/// Recognizes only the current built-in artwork, never arbitrary image URLs.
int? inlineEmojiIdFromUrl(String value) {
  // Match the original string before URI normalization can resolve dot
  // segments or decode percent escapes into a supported catalog path.
  final match = RegExp(
    '^(?:https://betshuva\\.com(?::443)?)?'
    '(${RegExp.escape(_emojiPath)}/sticker-([0-9]{2,3})\\.png)\$',
  ).firstMatch(value);
  final id = int.tryParse(match?.group(2) ?? '');
  if (id == null || !_validEmojiId(id) || match?.group(1) != _imagePath(id)) {
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

/// Shared compact rendering for messages, replies and conversation previews.
class InlineEmojiText extends StatelessWidget {
  const InlineEmojiText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final decoded = decodeInlineEmojiText(text);
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
