import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
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
const inlineEmojiScale = 1.1;

/// The pale greeting illustrations need more contrast at inline sizes.
/// Keep the saturated icons, portraits, alpha and artwork dimensions intact.
Widget vividInlineEmojiArtwork(int? id, Widget child) {
  if (!kIsWeb || id == null || id < 49 || id > 148) return child;
  return ColorFiltered(
    colorFilter: const ColorFilter.matrix([
      1.3845664, -0.2403072, -0.0242592, 0, -30.6,
      -0.0714336, 1.2156928, -0.0242592, 0, -30.6,
      -0.0714336, -0.2403072, 1.4317408, 0, -30.6,
      0, 0, 0, 1, 0,
    ]),
    child: child,
  );
}

/// Composers start on the right, including emoji-only drafts.
TextDirection inlineEmojiDraftDirection(String text) => TextDirection.rtl;

bool _isDraftEmoji(String character) => _editorEmoji.hasMatch(character) ||
    RegExp(r'[\u{1f000}-\u{1faff}\u2600-\u27bf]', unicode: true)
        .hasMatch(character);

int? _precedingEmojiRunStart(String prefix) {
  int? start;
  var offset = 0;
  for (final character in prefix.characters) {
    if (_isDraftEmoji(character)) {
      start ??= offset;
    } else if (character != ' ' && character != '\t') {
      start = null;
    }
    offset += character.length;
  }
  return start;
}

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
  final size = baseSize * inlineEmojiScale;
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
    // Reverse only the artwork identities within each consecutive run. Keep
    // its original bidi slots, so nearby Hebrew/Latin words and isolated
    // emoji never exchange positions when a run is displayed LTR.
    for (final run in RegExp('\uFFFC(?:[ \t]*\uFFFC)+').allMatches(plain)) {
      final indices = [
        for (var i = 0; i < offsets.length; i++)
          if (offsets[i] >= run.start && offsets[i] < run.end) i
      ];
      if (indices.any((i) => _visualPositions[i] == null)) continue;
      final positions = indices.map((i) => _visualPositions[i]!).toList()
        ..sort();
      for (var i = 0; i < indices.length; i++) {
        _visualPositions[indices[i]] = positions[i];
      }
    }
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

// These isolates belong to the editor's bidi layout, not the message payload.
String inlineEmojiPlainText(String text) =>
    text.replaceAll(RegExp('[\u2066\u2069]'), '');

String encodeInlineEmojiText(String text) => inlineEmojiPlainText(text).replaceAllMapped(
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

TextEditingValue _isolateEmojiEditingValue(TextEditingValue incoming) {
  // Leave active IME composition untouched until it commits.
  if (incoming.isComposingRangeValid && !incoming.composing.isCollapsed) {
    return incoming;
  }
  final plain = inlineEmojiPlainText(incoming.text);
  int logicalOffset(int offset) => offset < 0
      ? offset
      : inlineEmojiPlainText(incoming.text.substring(0, offset)).length;
  final runs = <TextRange>[];
  if (inlineEmojiDraftDirection(plain) == TextDirection.rtl) {
    int? start;
    var end = 0;
    var offset = 0;
    for (final character in plain.characters) {
      final emoji = _isDraftEmoji(character);
      if (emoji) {
        start ??= offset;
        end = offset + character.length;
      } else if (character != ' ' && character != '\t') {
        if (start != null) runs.add(TextRange(start: start, end: end));
        start = null;
      }
      offset += character.length;
    }
    if (start != null) runs.add(TextRange(start: start, end: end));
  }
  final display = StringBuffer();
  var previousEnd = 0;
  for (final run in runs) {
    display
      ..write(plain.substring(previousEnd, run.start))
      ..write('\u2066') // LTR isolate: only this emoji run changes direction.
      ..write(plain.substring(run.start, run.end))
      ..write('\u2069');
    previousEnd = run.end;
  }
  display.write(plain.substring(previousEnd));
  int displayOffset(int offset) {
    if (offset < 0) return offset;
    var extra = 0;
    for (final run in runs) {
      if (offset < run.start) break;
      extra++;
      if (offset < run.end) break;
      extra++;
    }
    return offset + extra;
  }
  return incoming.copyWith(
    text: display.toString(),
    selection: TextSelection(
      baseOffset: displayOffset(logicalOffset(incoming.selection.baseOffset)),
      extentOffset: displayOffset(logicalOffset(incoming.selection.extentOffset)),
      affinity: incoming.selection.affinity,
      isDirectional: incoming.selection.isDirectional,
    ),
    composing: TextRange.empty,
  );
}

class InlineEmojiController extends TextEditingController {
  InlineEmojiController({String? text, this.isolateEmojiRuns = false})
      : super.fromValue(isolateEmojiRuns
            ? _isolateEmojiEditingValue(
                TextEditingValue(text: decodeInlineEmojiText(text ?? '')))
            : TextEditingValue(text: decodeInlineEmojiText(text ?? '')));

  final bool isolateEmojiRuns;
  bool _disposed = false;
  bool _layoutCheckScheduled = false;

  TextEditingValue _insertEmojisOnTheLeft(TextEditingValue incoming) {
    if (!incoming.selection.isValid || !incoming.selection.isCollapsed ||
        (incoming.isComposingRangeValid && !incoming.composing.isCollapsed)) {
      return incoming;
    }
    final oldText = inlineEmojiPlainText(value.text);
    final newText = inlineEmojiPlainText(incoming.text);
    // Backspace at the visual left edge first reaches the invisible closing
    // isolate. Remove the leftmost artwork instead of restoring that marker.
    final cursor = value.selection.extentOffset;
    if (newText == oldText && incoming.text.length == value.text.length - 1 &&
        value.selection.isCollapsed && cursor > 0 &&
        value.text[cursor - 1] == '\u2069' &&
        incoming.selection.extentOffset == cursor - 1) {
      final end = inlineEmojiPlainText(value.text.substring(0, cursor)).length;
      final start = _precedingEmojiRunStart(oldText.substring(0, end));
      if (start != null) {
        final length = oldText.substring(start).characters.first.length;
        return incoming.copyWith(
          text: oldText.replaceRange(start, start + length, ''),
          selection: TextSelection.collapsed(offset: end - length),
          composing: TextRange.empty,
        );
      }
    }
    if (newText.length <= oldText.length) return incoming;
    var start = 0;
    while (start < oldText.length && oldText.codeUnitAt(start) == newText.codeUnitAt(start)) {
      start++;
    }
    final insertedLength = newText.length - oldText.length;
    if (newText.substring(start + insertedLength) != oldText.substring(start)) return incoming;
    final inserted = newText.substring(start, start + insertedLength);
    if (!inserted.characters.every(_isDraftEmoji)) return incoming;
    // A skin tone extends the preceding grapheme; it is not a new reaction.
    final firstRune = inserted.runes.first;
    if (firstRune >= 0x1f3fb && firstRune <= 0x1f3ff) return incoming;
    final extent = inlineEmojiPlainText(incoming.text.substring(0, incoming.selection.extentOffset)).length;
    if (extent != start + insertedLength) return incoming;
    // Artwork runs have an LTR layout. Insert each new choice at their left
    // edge, keeping previous choices on the right and the caret after the run.
    final runStart = _precedingEmojiRunStart(oldText.substring(0, start));
    final target = runStart ?? start;
    return incoming.copyWith(
      text: oldText.substring(0, target) + inserted.characters.toList().reversed.join() +
          oldText.substring(target),
      selection: TextSelection.collapsed(offset: extent),
      composing: TextRange.empty,
    );
  }

  @override
  set value(TextEditingValue newValue) {
    final decoded = _decodeEditingValue(newValue);
    super.value = isolateEmojiRuns
        ? _isolateEmojiEditingValue(_insertEmojisOnTheLeft(decoded))
        : decoded;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final spans = _emojiSpans(context, text, style: style,
      composing: withComposing && value.isComposingRangeValid
          ? value.composing : TextRange.empty);
    if (!isolateEmojiRuns) return spans;
    final width = _draftEmojiWidth(_draftEditable(context));
    if (!_layoutCheckScheduled && _editorEmoji.allMatches(text).length > 1) {
      _layoutCheckScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _layoutCheckScheduled = false;
        if (!_disposed && context.mounted &&
            width != _draftEmojiWidth(_draftEditable(context))) {
          // Initial drafts and browser resizing must use the field's final
          // layout width, which is only available after the first frame.
          notifyListeners();
        }
      });
    }
    return _draftEmojiSpans(context, spans);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

RenderEditable? _draftEditable(BuildContext context) {
  RenderEditable? editable;
  void visit(RenderObject object) {
    if (object is RenderEditable) { editable = object; return; }
    object.visitChildren((child) { if (editable == null) visit(child); });
  }
  final object = context.findRenderObject();
  if (object != null) visit(object);
  return editable;
}

double _draftEmojiWidth(RenderEditable? render) =>
    render != null && render.hasSize && render.maxLines != 1
        ? (render.constraints.maxWidth - render.cursorWidth - 1).clamp(0.0, double.infinity)
        : double.infinity;

// RenderEditable uses SkParagraph's placeholder ordering, which can exchange
// images across separate bidi runs. Correct only the artwork assigned to its
// slots; editing offsets, composing ranges and the transmitted text stay intact.
TextSpan _draftEmojiSpans(BuildContext context, TextSpan spans) {
  final children = spans.children!;
  final indices = <int>[];
  final offsets = <int>[];
  var offset = 0;
  for (var i = 0; i < children.length; i++) {
    final span = children[i];
    if (span is WidgetSpan) {
      indices.add(i); offsets.add(offset++);
    } else {
      offset += span.toPlainText(includeSemanticsLabels: false).length;
    }
  }
  if (indices.length < 2) return spans;
  final style = DefaultTextStyle.of(context).style.merge(spans.style);
  final size = ((style.fontSize ?? 14) * 1.35).clamp(18.0, 24.0).toDouble() * inlineEmojiScale;
  final render = _draftEditable(context);
  final width = _draftEmojiWidth(render);
  final scaler = render?.textScaler ?? MediaQuery.textScalerOf(context);
  final actual = TextPainter(text: TextSpan(style: style, children: children),
    textDirection: TextDirection.rtl, textScaler: scaler);
  final reference = TextPainter(text: TextSpan(style: style,
    text: spans.toPlainText(includeSemanticsLabels: false)),
    textDirection: TextDirection.rtl, textScaler: scaler);
  try {
    actual.setPlaceholderDimensions([for (final _ in indices)
      PlaceholderDimensions(size: Size.square(size), alignment: PlaceholderAlignment.middle)]);
    actual.layout(maxWidth: width); reference.layout();
    final boxes = actual.inlinePlaceholderBoxes;
    if (boxes == null || boxes.length != indices.length) return spans;
    final positions = [for (final at in offsets)
      reference.getBoxesForSelection(TextSelection(baseOffset: at, extentOffset: at + 1))];
    if (positions.any((boxes) => boxes.length != 1)) return spans;
    final reordered = List<InlineSpan>.of(children);
    final lines = <double, List<int>>{};
    for (var i=0; i<indices.length; i++) {
      (lines[boxes[i].top] ??= <int>[]).add(i);
    }
    for (final line in lines.values) {
      final slots = List<int>.of(line)..sort((a,b)=>boxes[a].left.compareTo(boxes[b].left));
      final artwork = List<int>.of(line)..sort((a,b)=>positions[a].single.left.compareTo(positions[b].single.left));
      for (var i=0; i<slots.length; i++) {
        final slot=children[indices[slots[i]]] as WidgetSpan;
        final image=children[indices[artwork[i]]] as WidgetSpan;
        reordered[indices[slots[i]]] = WidgetSpan(alignment: slot.alignment,
          baseline: slot.baseline, style: slot.style, child: image.child);
      }
    }
    return TextSpan(style: spans.style, children: reordered);
  } finally {
    actual.dispose(); reference.dispose();
  }
}

TextSpan _emojiSpans(
  BuildContext context,
  String text, {
  TextStyle? style,
  TextRange composing = TextRange.empty,
}) {
  final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
  final size =
      ((effectiveStyle.fontSize ?? 14) * 1.35).clamp(18.0, 24.0).toDouble() *
          inlineEmojiScale;
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
              child: vividInlineEmojiArtwork(
                id,
                Image.network(
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
    return _MessageEmojiText.rich(
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
