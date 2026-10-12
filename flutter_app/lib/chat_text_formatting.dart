import 'package:flutter/widgets.dart';

/// Formatting stays in the message body, so edits and forwards retain it.
enum ChatTextFormat {
  bold,
  italic,
  strikethrough,
  code,
  bulletList,
  numberedList,
  quote,
}

enum ChatTextColorTarget { foreground, background }

class ChatTextRun {
  const ChatTextRun({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.strikethrough = false,
    this.code = false,
    this.quote = false,
    this.marker = false,
    this.foregroundRgb,
    this.backgroundRgb,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool strikethrough;
  final bool code;
  final bool quote;
  final bool marker;
  final int? foregroundRgb;
  final int? backgroundRgb;
}

final _blockPrefix = RegExp(r'^([ \t]*)(>[ \t]+|[-*][ \t]+|[0-9]+\.[ \t]+)');
final _wordCharacter =
    RegExp(r'[A-Za-z0-9\u00c0-\u02ff\u0370-\u1fff\u2c00-\ua7ff]');
const _styleClose = '[[/bt-style]]';
final _styleOpening = RegExp(
    r'\[\[bt-style:((?:fg|bg)=[0-9a-fA-F]{6}(?:;(?:fg|bg)=[0-9a-fA-F]{6})?)\]\]');

/// With [preserveMarkers], runs occupy precisely the original UTF-16 offsets.
/// The editor can therefore style the text without changing caret positions.
List<ChatTextRun> parseChatFormattedText(String text,
    {bool preserveMarkers = false}) {
  final runs = <ChatTextRun>[];
  var start = 0;
  while (start < text.length) {
    final newline = text.indexOf('\n', start);
    final end = newline < 0 ? text.length : newline;
    final crlf = end > start && text[end - 1] == '\r';
    final lineEnd = crlf ? end - 1 : end;
    final line = text.substring(start, lineEnd);
    final prefix = _blockPrefix.firstMatch(line);
    final isQuote = prefix?.group(2)?.startsWith('>') ?? false;
    var bodyStart = 0;
    // A marker without any content remains literal, including empty lists.
    if (prefix != null && line.substring(prefix.end).trim().isNotEmpty) {
      final indent = prefix.group(1)!;
      _append(runs, ChatTextRun(text: indent, quote: isQuote));
      final marker = prefix.group(2)!;
      _append(
          runs,
          ChatTextRun(
              text: preserveMarkers
                  ? marker
                  : isQuote
                      ? '│ '
                      : marker.startsWith('-') || marker.startsWith('*')
                          ? '• '
                          : marker,
              quote: isQuote,
              marker: preserveMarkers));
      bodyStart = prefix.end;
    }
    _parseInline(line.substring(bodyStart), runs,
        preserveMarkers: preserveMarkers, quote: bodyStart > 0 && isQuote);
    if (newline >= 0) {
      _append(runs, ChatTextRun(text: crlf ? '\r\n' : '\n'));
    } else if (crlf) {
      _append(runs, const ChatTextRun(text: '\r'));
    }
    start = end + 1;
  }
  return runs;
}

class _Delimiter {
  _Delimiter(this.start, this.text) {
    if (isColor && text != _styleClose) {
      for (final attribute in text.substring(11, text.length - 2).split(';')) {
        final rgb = int.parse(attribute.substring(3), radix: 16);
        if (attribute.startsWith('fg=')) {
          foregroundRgb = rgb;
        } else {
          backgroundRgb = rgb;
        }
      }
    }
  }

  final int start;
  final String text;
  bool matched = false;
  bool opening = true;
  _Delimiter? partner;
  int? foregroundRgb;
  int? backgroundRgb;

  int get end => start + text.length;
  bool get isColor => text == _styleClose || text.startsWith('[[bt-style:');
}

class _ChatStyle {
  const _ChatStyle({this.flags = 0, this.foregroundRgb, this.backgroundRgb});
  final int flags;
  final int? foregroundRgb;
  final int? backgroundRgb;

  _ChatStyle withFlags(int value) => _ChatStyle(
      flags: value, foregroundRgb: foregroundRgb, backgroundRgb: backgroundRgb);
}

_ChatStyle _activeStyle(List<_Delimiter> active) {
  var flags = 0;
  int? foreground;
  int? background;
  for (final delimiter in active) {
    flags |= _delimiterBit(delimiter.text);
    foreground = delimiter.foregroundRgb ?? foreground;
    background = delimiter.backgroundRgb ?? background;
  }
  return _ChatStyle(
      flags: flags, foregroundRgb: foreground, backgroundRgb: background);
}

String _styleMarker(_ChatStyle style) {
  String hex(int rgb) => rgb.toRadixString(16).padLeft(6, '0').toUpperCase();
  return '[[bt-style:${[
    if (style.foregroundRgb != null) 'fg=${hex(style.foregroundRgb!)}',
    if (style.backgroundRgb != null) 'bg=${hex(style.backgroundRgb!)}',
  ].join(';')}]]';
}

String _closingMarker(String marker) =>
    marker.startsWith('[[bt-style:') ? _styleClose : marker;

String? _delimiterAt(String text, int offset, {String? activeMarker}) {
  if (text.startsWith(_styleClose, offset)) return _styleClose;
  final color = _styleOpening.matchAsPrefix(text, offset);
  if (color != null) {
    final attributes = color.group(1)!.split(';');
    if (attributes.length == 1 ||
        attributes[0].substring(0, 2) != attributes[1].substring(0, 2)) {
      return color.group(0);
    }
  }
  // A shared *** boundary opens bold then italic, and closes in reverse.
  if (activeMarker == '*' && text.startsWith('***', offset)) return '*';
  for (final marker in const ['**', '~~', '`', '_', '*']) {
    if (text.startsWith(marker, offset)) return marker;
  }
  return null;
}

bool _isEscaped(String text, int offset) {
  var slashes = 0;
  for (var i = offset - 1; i >= 0 && text[i] == r'\'; i--) {
    slashes++;
  }
  return slashes.isOdd;
}

bool _canOpen(String text, _Delimiter delimiter) {
  if (delimiter.isColor) {
    return delimiter.text != _styleClose && delimiter.end < text.length;
  }
  if (delimiter.end >= text.length || text[delimiter.end].trim().isEmpty) {
    return false;
  }
  return delimiter.text != '_' ||
      delimiter.start == 0 ||
      !_wordCharacter.hasMatch(text[delimiter.start - 1]);
}

bool _canClose(String text, _Delimiter delimiter) {
  if (delimiter.isColor) return delimiter.text == _styleClose;
  if (delimiter.start == 0 || text[delimiter.start - 1].trim().isEmpty) {
    return false;
  }
  return delimiter.text != '_' ||
      delimiter.end == text.length ||
      !_wordCharacter.hasMatch(text[delimiter.end]);
}

List<_Delimiter> _inlineDelimiters(String text) {
  final delimiters = <_Delimiter>[];
  final stack = <_Delimiter>[];
  var offset = 0;
  while (offset < text.length) {
    final marker = _delimiterAt(text, offset,
        activeMarker: stack.isEmpty ? null : stack.last.text);
    if (marker == null) {
      offset++;
      continue;
    }
    if (_isEscaped(text, offset)) {
      offset += marker.length;
      // An escaped double/triple star is literal as a whole; its remainder
      // must not become a new single-star italic delimiter.
      if (marker.startsWith('*')) {
        while (offset < text.length && text[offset] == '*') {
          offset++;
        }
      }
      continue;
    }
    final delimiter = _Delimiter(offset, marker);
    delimiters.add(delimiter);
    // Inline code is literal; formatting inside it must never be interpreted.
    if (stack.isNotEmpty && stack.last.text == '`' && marker != '`') {
      offset += marker.length;
      continue;
    }
    final closesColor =
        delimiter.text == _styleClose && stack.isNotEmpty && stack.last.isColor;
    if (stack.isNotEmpty &&
        (closesColor || stack.last.text == marker) &&
        (stack.last.end < offset || closesColor) &&
        _canClose(text, delimiter)) {
      final opening = stack.removeLast()
        ..matched = true
        ..partner = delimiter;
      delimiter
        ..matched = true
        ..opening = false
        ..partner = opening;
    } else if (_canOpen(text, delimiter)) {
      stack.add(delimiter);
    }
    offset += marker.length;
  }
  return delimiters;
}

bool _onlyMatchedDelimiters(List<_Delimiter> delimiters, int start, int end) {
  var position = start;
  for (final delimiter in delimiters) {
    if (!delimiter.matched || delimiter.start < position) continue;
    if (delimiter.start >= end) break;
    if (delimiter.start != position || delimiter.end > end) return false;
    position = delimiter.end;
  }
  return position == end;
}

void _parseInline(String text, List<ChatTextRun> runs,
    {required bool preserveMarkers, required bool quote}) {
  final delimiters = _inlineDelimiters(text);
  final active = <_Delimiter>[];
  ChatTextRun run(String value, {bool marker = false}) {
    final style = _activeStyle(active);
    return ChatTextRun(
        text: value,
        bold: (style.flags & 1) != 0,
        italic: (style.flags & 2) != 0,
        strikethrough: (style.flags & 4) != 0,
        code: (style.flags & 8) != 0,
        quote: quote,
        marker: marker,
        foregroundRgb: style.foregroundRgb,
        backgroundRgb: style.backgroundRgb);
  }

  var previous = 0;
  for (final delimiter in delimiters.where((item) => item.matched)) {
    _append(runs, run(text.substring(previous, delimiter.start)));
    if (delimiter.opening) active.add(delimiter);
    if (preserveMarkers) {
      _append(runs, run(delimiter.text, marker: true));
    }
    if (!delimiter.opening) active.removeLast();
    previous = delimiter.end;
  }
  _append(runs, run(text.substring(previous)));
}

void _append(List<ChatTextRun> runs, ChatTextRun next) {
  if (next.text.isEmpty) return;
  if (runs.isNotEmpty) {
    final last = runs.last;
    if (last.bold == next.bold &&
        last.italic == next.italic &&
        last.strikethrough == next.strikethrough &&
        last.code == next.code &&
        last.quote == next.quote &&
        last.marker == next.marker &&
        last.foregroundRgb == next.foregroundRgb &&
        last.backgroundRgb == next.backgroundRgb &&
        !(last.marker &&
            (last.text.startsWith('[[bt-style:') ||
                last.text.startsWith(_styleClose))) &&
        !(next.marker &&
            (next.text.startsWith('[[bt-style:') ||
                next.text.startsWith(_styleClose)))) {
      runs[runs.length - 1] = ChatTextRun(
          text: last.text + next.text,
          bold: next.bold,
          italic: next.italic,
          strikethrough: next.strikethrough,
          code: next.code,
          quote: next.quote,
          marker: next.marker,
          foregroundRgb: next.foregroundRgb,
          backgroundRgb: next.backgroundRgb);
      return;
    }
  }
  runs.add(next);
}

/// Sets or clears one color on the selected content without replacing the
/// other color or existing formatting. RGB values are opaque 24-bit colors.
TextEditingValue colorChatSelection(
    TextEditingValue value, ChatTextColorTarget target,
    {int? rgb}) {
  final selection = value.selection;
  if (!selection.isValid ||
      selection.end > value.text.length ||
      selection.isCollapsed ||
      (value.composing.isValid && !value.composing.isCollapsed) ||
      (rgb != null && (rgb < 0 || rgb > 0xffffff))) {
    return value;
  }
  final range = _wholeGraphemes(value.text, selection.start, selection.end);
  final edits = <_Edit>[];
  var start = range.start;
  while (start < range.end) {
    final lineStart =
        start == 0 ? 0 : value.text.lastIndexOf('\n', start - 1) + 1;
    final newline = value.text.indexOf('\n', start);
    final lineEnd = newline < 0 ? value.text.length : newline;
    final end = lineEnd > range.end ? range.end : lineEnd;
    final line = value.text.substring(lineStart, lineEnd);
    final prefix = _blockPrefix.firstMatch(line);
    final contentStart =
        prefix != null && line.substring(prefix.end).trim().isNotEmpty
            ? lineStart + prefix.end
            : start;
    final partStart = start < contentStart ? contentStart : start;
    if (partStart < end &&
        value.text.substring(partStart, end).trim().isNotEmpty) {
      edits.add(_balancedInlineEdit(
          line, lineStart, partStart - lineStart, end - lineStart, null,
          colorTarget: target, rgb: rgb));
    }
    start = lineEnd + 1;
  }
  return _applyEdits(value, edits, range.start, range.end);
}

/// Repairs a regular edit that cut a previously valid, hidden color tag.
/// Already mapped formatting commands and edits confined to text pass through.
/// Single-character deletion next to hidden tags is handled by the controller.
TextEditingValue repairChatColorEditingValue(
    TextEditingValue previous, TextEditingValue incoming) {
  bool composing(TextEditingValue value) =>
      value.composing.isValid && !value.composing.isCollapsed;
  if (previous.text == incoming.text ||
      !previous.text.contains('[[bt-style:') ||
      !incoming.selection.isValid ||
      incoming.selection.end > incoming.text.length ||
      composing(previous) ||
      composing(incoming)) {
    return incoming;
  }
  var start = 0;
  while (start < previous.text.length &&
      start < incoming.text.length &&
      previous.text[start] == incoming.text[start]) {
    start++;
  }
  var previousEnd = previous.text.length;
  var incomingEnd = incoming.text.length;
  while (previousEnd > start &&
      incomingEnd > start &&
      previous.text[previousEnd - 1] == incoming.text[incomingEnd - 1]) {
    previousEnd--;
    incomingEnd--;
  }
  if (!_damagesColorMetadata(previous.text, start, previousEnd)) {
    return incoming;
  }
  final previousVisible =
      parseChatFormattedText(previous.text).map((run) => run.text).join();
  final incomingVisible =
      parseChatFormattedText(incoming.text).map((run) => run.text).join();
  if (previousVisible == incomingVisible) return incoming;

  final old = _documentModel(previous.text);
  final plainStart = old.rawToPlain[start];
  final plainEnd = old.rawToPlain[previousEnd];
  final inherited = plainStart < old.styles.length
      ? old.styles[plainStart]
      : plainStart > 0
          ? old.styles[plainStart - 1]
          : const _ChatStyle();
  final insertedText = incoming.text.substring(start, incomingEnd);
  final inserted = (inherited.flags & 8) != 0
      ? _InlineModel(
          insertedText,
          List<_ChatStyle>.filled(insertedText.length, const _ChatStyle()),
          List<int>.generate(insertedText.length + 1, (i) => i))
      : _documentModel(insertedText);
  final visible = old.visible.substring(0, plainStart) +
      inserted.visible +
      old.visible.substring(plainEnd);
  final styles = <_ChatStyle>[
    ...old.styles.take(plainStart),
    for (final style in inserted.styles)
      _ChatStyle(
          flags: inherited.flags | style.flags,
          foregroundRgb: style.foregroundRgb ?? inherited.foregroundRgb,
          backgroundRgb: style.backgroundRgb ?? inherited.backgroundRgb),
    ...old.styles.skip(plainEnd),
  ];
  final encoded = _serializeInlineModel(visible, styles);

  int mapPlain(int offset) {
    if (offset <= start) return old.rawToPlain[offset];
    if (offset <= incomingEnd) {
      return plainStart + inserted.rawToPlain[offset - start];
    }
    final oldOffset = previousEnd + offset - incomingEnd;
    return old.rawToPlain[oldOffset] -
        (plainEnd - plainStart) +
        inserted.visible.length;
  }

  final reversed =
      incoming.selection.baseOffset > incoming.selection.extentOffset;
  final mappedStart = encoded.starts[mapPlain(incoming.selection.start)];
  final mappedEnd = incoming.selection.isCollapsed
      ? mappedStart
      : encoded.ends[mapPlain(incoming.selection.end)];
  final composition = incoming.composing.isValid
      ? TextRange.collapsed(encoded.starts[mapPlain(incoming.composing.start)])
      : incoming.composing;
  return incoming.copyWith(
      text: encoded.text,
      selection: TextSelection(
          baseOffset: reversed ? mappedEnd : mappedStart,
          extentOffset: reversed ? mappedStart : mappedEnd,
          affinity: incoming.selection.affinity,
          isDirectional: incoming.selection.isDirectional),
      composing: composition);
}

bool _damagesColorMetadata(String text, int start, int end) {
  var lineStart = 0;
  while (lineStart < text.length) {
    final newline = text.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? text.length : newline;
    final delimiters = _inlineDelimiters(text.substring(lineStart, lineEnd));
    bool affects(_Delimiter token) {
      final tokenStart = token.start + lineStart;
      final tokenEnd = token.end + lineStart;
      return (start < tokenEnd && end > tokenStart) ||
          (start == end && start > tokenStart && start < tokenEnd);
    }

    for (final opening in delimiters) {
      final closing = opening.partner;
      if (!opening.opening || !opening.isColor || closing == null) continue;
      final wholePair =
          start <= opening.start + lineStart && end >= closing.end + lineStart;
      if (!wholePair && (affects(opening) || affects(closing))) return true;
    }
    lineStart = lineEnd + 1;
  }
  return false;
}

/// Applies a reversible command while preserving selection direction and IME.
TextEditingValue formatChatSelection(
    TextEditingValue value, ChatTextFormat format) {
  final selection = value.selection;
  if (!selection.isValid ||
      selection.end > value.text.length ||
      (value.composing.isValid && !value.composing.isCollapsed)) {
    return value;
  }
  final markers = switch (format) {
    ChatTextFormat.bold => const ['**'],
    ChatTextFormat.italic => const ['_', '*'],
    ChatTextFormat.strikethrough => const ['~~'],
    ChatTextFormat.code => const ['`'],
    _ => null,
  };
  if (markers == null) return _formatBlocks(value, format);
  if (selection.isCollapsed) return value;

  final range = _wholeGraphemes(value.text, selection.start, selection.end);
  final parts = <_InlineSelection>[];
  var start = range.start;
  while (start < range.end) {
    final newline = value.text.indexOf('\n', start);
    final end = newline < 0 || newline > range.end ? range.end : newline;
    var partStart = start;
    var partEnd = end;
    // Keeping outside whitespace makes the generated delimiters unambiguous.
    while (partStart < partEnd && value.text[partStart].trim().isEmpty) {
      partStart++;
    }
    while (partEnd > partStart && value.text[partEnd - 1].trim().isEmpty) {
      partEnd--;
    }
    final actualLineStart =
        start == 0 ? 0 : value.text.lastIndexOf('\n', start - 1) + 1;
    final actualLineEnd = newline < 0 ? value.text.length : newline;
    final lineText = value.text.substring(actualLineStart, actualLineEnd);
    final block = _blockPrefix.firstMatch(lineText);
    if (block != null &&
        lineText.substring(block.end).trim().isNotEmpty &&
        partStart < actualLineStart + block.end) {
      // Inline styling never absorbs a list/quote prefix into its wrapper.
      partStart = actualLineStart + block.end;
    }
    if (partStart < partEnd) {
      var marker = markers.first;
      // Underscores stay literal inside words (snake_case). Single stars let
      // an explicitly selected word fragment receive italic without changing
      // the selection or reinterpreting existing underscores in ordinary text.
      if (format == ChatTextFormat.italic &&
          ((partStart > 0 &&
                  _wordCharacter.hasMatch(value.text[partStart - 1])) ||
              (partEnd < value.text.length &&
                  _wordCharacter.hasMatch(value.text[partEnd])))) {
        marker = '*';
      }
      var opening = -1;
      var closing = -1;
      final lineStart = actualLineStart;
      final lineEnd = newline;
      final delimiters = _inlineDelimiters(value.text
          .substring(lineStart, lineEnd < 0 ? value.text.length : lineEnd));
      _Edit? balancedEdit;
      if (_needsBalancedInline(
          delimiters, partStart - lineStart, partEnd - lineStart, format)) {
        balancedEdit = _balancedInlineEdit(
            value.text.substring(
                lineStart, lineEnd < 0 ? value.text.length : lineEnd),
            lineStart,
            partStart - lineStart,
            partEnd - lineStart,
            format);
      }
      bool isPair(String marker, int opening, int closing) =>
          delimiters.any((delimiter) =>
              delimiter.text == marker &&
              delimiter.opening &&
              delimiter.start + lineStart == opening &&
              delimiter.partner != null &&
              delimiter.partner!.start + lineStart == closing);
      for (final existingMarker in markers) {
        if (partEnd - partStart > existingMarker.length * 2 &&
            isPair(
                existingMarker, partStart, partEnd - existingMarker.length)) {
          marker = existingMarker;
          opening = partStart;
          closing = partEnd - marker.length;
          break;
        } else if (isPair(
            existingMarker, partStart - existingMarker.length, partEnd)) {
          marker = existingMarker;
          opening = partStart - marker.length;
          closing = partEnd;
          break;
        }
      }
      if (opening < 0) {
        // Nested style markers may sit between the selected content and its
        // wrapper, including the shared *** boundary of bold + italic.
        for (final delimiter in delimiters) {
          final partner = delimiter.partner;
          if (!delimiter.opening ||
              partner == null ||
              !markers.contains(delimiter.text) ||
              delimiter.end > partStart - lineStart ||
              partner.start < partEnd - lineStart) {
            continue;
          }
          if (_onlyMatchedDelimiters(
                  delimiters, delimiter.end, partStart - lineStart) &&
              _onlyMatchedDelimiters(
                  delimiters, partEnd - lineStart, partner.start)) {
            marker = delimiter.text;
            opening = delimiter.start + lineStart;
            closing = partner.start + lineStart;
            break;
          }
        }
      }
      parts.add(_InlineSelection(
          partStart, partEnd, opening, closing, marker, balancedEdit));
    }
    start = end + 1;
  }
  if (parts.isEmpty) return value;
  final remove = parts.every((part) => part.opening >= 0);
  final edits = <_Edit>[];
  for (final part in parts) {
    if (part.balancedEdit != null) {
      edits.add(part.balancedEdit!);
      continue;
    }
    final marker = part.marker;
    if (remove) {
      edits.add(_Edit(part.opening, part.opening + marker.length, ''));
      edits.add(_Edit(part.closing, part.closing + marker.length, ''));
    } else if (part.opening < 0) {
      // Reuse existing content instead of making overlapping nested pairs of
      // the same delimiter when a selection already contains styled words.
      for (final delimiter
          in _inlineDelimiters(value.text.substring(part.start, part.end))) {
        if (delimiter.matched && markers.contains(delimiter.text)) {
          edits.add(_Edit(
              part.start + delimiter.start, part.start + delimiter.end, ''));
        }
      }
      edits.add(_Edit(part.start, part.start, marker));
      edits.add(_Edit(part.end, part.end, marker));
    }
  }
  return _applyEdits(value, edits, range.start, range.end);
}

class _InlineSelection {
  const _InlineSelection(this.start, this.end, this.opening, this.closing,
      this.marker, this.balancedEdit);
  final int start;
  final int end;
  final int opening;
  final int closing;
  final String marker;
  final _Edit? balancedEdit;
}

bool _needsBalancedInline(
    List<_Delimiter> delimiters, int start, int end, ChatTextFormat format) {
  for (final opening in delimiters) {
    final closing = opening.partner;
    if (!opening.opening || closing == null) continue;
    final overlaps = start < closing.end && end > opening.start;
    if (opening.isColor && overlaps) {
      return true;
    }
    final wholePair = start <= opening.start && end >= closing.end;
    final onlyContent = start >= opening.end && end <= closing.start;
    final partialSameStyle = onlyContent &&
        _delimiterBit(opening.text) == _formatBit(format) &&
        (start != opening.end || end != closing.start);
    final codeOverStyle =
        format == ChatTextFormat.code && opening.text != '`' && overlaps;
    final insideCode = opening.text == '`' &&
        format != ChatTextFormat.code &&
        start >= opening.end &&
        end <= closing.start;
    if ((overlaps && !wholePair && !onlyContent) ||
        partialSameStyle ||
        codeOverStyle ||
        insideCode) {
      return true;
    }
  }
  return false;
}

int _formatBit(ChatTextFormat format) => switch (format) {
      ChatTextFormat.bold => 1,
      ChatTextFormat.italic => 2,
      ChatTextFormat.strikethrough => 4,
      ChatTextFormat.code => 8,
      _ => 0,
    };

int _delimiterBit(String marker) => switch (marker) {
      '**' => 1,
      '_' || '*' => 2,
      '~~' => 4,
      '`' => 8,
      _ => 0,
    };

class _InlineModel {
  const _InlineModel(this.visible, this.styles, this.rawToPlain);
  final String visible;
  final List<_ChatStyle> styles;
  final List<int> rawToPlain;
}

_InlineModel _inlineModel(String text) {
  final delimiters = _inlineDelimiters(text);
  final tokens = {
    for (final delimiter in delimiters.where((item) => item.matched))
      delimiter.start: delimiter,
  };
  final rawToPlain = List<int>.filled(text.length + 1, 0);
  final plain = StringBuffer();
  final styles = <_ChatStyle>[];
  final active = <_Delimiter>[];
  var raw = 0;
  while (raw < text.length) {
    rawToPlain[raw] = styles.length;
    final token = tokens[raw];
    if (token != null) {
      for (var i = raw; i <= token.end; i++) {
        rawToPlain[i] = styles.length;
      }
      if (token.opening) {
        active.add(token);
      } else {
        active.removeLast();
      }
      raw = token.end;
    } else {
      plain.write(text[raw]);
      styles.add(_activeStyle(active));
      rawToPlain[++raw] = styles.length;
    }
  }
  return _InlineModel(plain.toString(), styles, rawToPlain);
}

_InlineModel _documentModel(String text) {
  final visible = StringBuffer();
  final styles = <_ChatStyle>[];
  final rawToPlain = List<int>.filled(text.length + 1, 0);
  var lineStart = 0;
  while (lineStart < text.length) {
    final newline = text.indexOf('\n', lineStart);
    final lineEnd = newline < 0 ? text.length : newline;
    final line = _inlineModel(text.substring(lineStart, lineEnd));
    final offset = styles.length;
    for (var i = 0; i < line.rawToPlain.length; i++) {
      rawToPlain[lineStart + i] = offset + line.rawToPlain[i];
    }
    visible.write(line.visible);
    styles.addAll(line.styles);
    if (newline >= 0) {
      visible.write('\n');
      styles.add(const _ChatStyle());
      rawToPlain[lineEnd + 1] = styles.length;
    }
    lineStart = lineEnd + 1;
  }
  return _InlineModel(visible.toString(), styles, rawToPlain);
}

/// A selection crossing an existing wrapper cannot be wrapped locally: that
/// would create crossing, unbalanced delimiters. Rebuild this line from its
/// visible text and styles, while mapping both sides of every source boundary.
_Edit _balancedInlineEdit(
    String text, int offset, int start, int end, ChatTextFormat? format,
    {ChatTextColorTarget? colorTarget, int? rgb}) {
  final model = _inlineModel(text);
  final styles = model.styles;
  final rawToPlain = model.rawToPlain;
  final visible = model.visible;
  final selectedStart = rawToPlain[start];
  final selectedEnd = rawToPlain[end];
  final unchangedColor = colorTarget != null &&
      styles.sublist(selectedStart, selectedEnd).every((style) =>
          (colorTarget == ChatTextColorTarget.foreground
              ? style.foregroundRgb
              : style.backgroundRgb) ==
          rgb);
  if (selectedStart == selectedEnd || unchangedColor) {
    final identity = List<int>.generate(text.length + 1, (i) => i);
    return _Edit(offset, offset + text.length, text,
        startMap: identity, endMap: identity);
  }
  final bit = format == null ? 0 : _formatBit(format);
  final remove = selectedStart < selectedEnd &&
      styles
          .sublist(selectedStart, selectedEnd)
          .every((style) => (style.flags & bit) != 0);
  for (var i = selectedStart; i < selectedEnd; i++) {
    final old = styles[i];
    styles[i] = colorTarget != null
        ? _ChatStyle(
            flags: old.flags,
            foregroundRgb: colorTarget == ChatTextColorTarget.foreground
                ? rgb
                : old.foregroundRgb,
            backgroundRgb: colorTarget == ChatTextColorTarget.background
                ? rgb
                : old.backgroundRgb)
        : old.withFlags(remove ? old.flags & ~bit : old.flags | bit);
  }

  final encoded = _serializeInlineModel(visible, styles);
  return _Edit(offset, offset + text.length, encoded.text,
      startMap: rawToPlain.map((position) => encoded.starts[position]).toList(),
      endMap: rawToPlain.map((position) => encoded.ends[position]).toList());
}

({String text, List<int> starts, List<int> ends}) _serializeInlineModel(
    String visible, List<_ChatStyle> styles) {
  // When a parent style changes, its nested wrappers split too. Delimiters
  // cannot open or close on whitespace, so trim only each wrapper's edges;
  // spaces inside a continuing wrapper keep their existing styles.
  for (final level in [
    (bit: 1, parents: 0),
    (bit: 2, parents: 1),
    (bit: 4, parents: 3),
    (bit: 8, parents: 7),
  ]) {
    var position = 0;
    while (position < styles.length) {
      if ((styles[position].flags & level.bit) == 0) {
        position++;
        continue;
      }
      final parents = styles[position].flags & level.parents;
      final foreground = styles[position].foregroundRgb;
      final background = styles[position].backgroundRgb;
      var groupEnd = position + 1;
      while (groupEnd < styles.length &&
          (styles[groupEnd].flags & level.bit) != 0 &&
          (styles[groupEnd].flags & level.parents) == parents &&
          styles[groupEnd].foregroundRgb == foreground &&
          styles[groupEnd].backgroundRgb == background) {
        groupEnd++;
      }
      var first = position;
      while (first < groupEnd && visible[first].trim().isEmpty) {
        styles[first] =
            styles[first].withFlags(styles[first].flags & ~level.bit);
        first++;
      }
      var last = groupEnd;
      while (last > first && visible[last - 1].trim().isEmpty) {
        last--;
        styles[last] = styles[last].withFlags(styles[last].flags & ~level.bit);
      }
      position = groupEnd;
    }
  }

  final result = StringBuffer();
  final starts = List<int>.filled(visible.length + 1, 0);
  final ends = List<int>.filled(visible.length + 1, 0);
  var current = <String>[];
  for (var i = 0; i <= visible.length; i++) {
    final atLineEnd = i < visible.length &&
        (visible[i] == '\n' ||
            (visible[i] == '\r' &&
                i + 1 < visible.length &&
                visible[i + 1] == '\n'));
    final profile =
        i < styles.length && !atLineEnd ? styles[i] : const _ChatStyle();
    final style = profile.flags;
    final desired = <String>[];
    if (profile.foregroundRgb != null || profile.backgroundRgb != null) {
      desired.add(_styleMarker(profile));
    }
    if (style & 1 != 0) desired.add('**');
    if (style & 2 != 0) {
      var italicEnd = i + 1;
      while (italicEnd < styles.length &&
          (styles[italicEnd].flags & 2) != 0 &&
          (styles[italicEnd].flags & 1) == (style & 1) &&
          styles[italicEnd].foregroundRgb == profile.foregroundRgb &&
          styles[italicEnd].backgroundRgb == profile.backgroundRgb) {
        italicEnd++;
      }
      final intraword = (i > 0 && _wordCharacter.hasMatch(visible[i - 1])) ||
          (italicEnd < visible.length &&
              _wordCharacter.hasMatch(visible[italicEnd]));
      // Retain the chosen marker throughout a continuing italic wrapper.
      final sameParent =
          current.isNotEmpty && current.contains('**') == (style & 1 != 0);
      final priorItalic = sameParent
          ? current
              .where((marker) => marker == '_' || marker == '*')
              .firstOrNull
          : null;
      desired.add(priorItalic ?? (intraword ? '*' : '_'));
    }
    if (style & 4 != 0) desired.add('~~');
    // Code is innermost, so a later bold/italic action never writes markers
    // into literal code content.
    if (style & 8 != 0) desired.add('`');
    var shared = 0;
    while (shared < current.length &&
        shared < desired.length &&
        current[shared] == desired[shared]) {
      shared++;
    }
    for (var j = current.length - 1; j >= shared; j--) {
      result.write(_closingMarker(current[j]));
    }
    for (var j = shared; j < desired.length; j++) {
      result.write(desired[j]);
    }
    current = desired;
    starts[i] = result.length;
    if (i < visible.length) {
      result.write(visible[i]);
      ends[i + 1] = result.length;
    }
  }
  return (text: result.toString(), starts: starts, ends: ends);
}

TextRange _wholeGraphemes(String text, int start, int end) {
  var offset = 0;
  var safeStart = start;
  var safeEnd = end;
  for (final character in text.characters) {
    final next = offset + character.length;
    if (offset < start && start < next) safeStart = offset;
    if (offset < end && end < next) safeEnd = next;
    offset = next;
    if (offset >= end) break;
  }
  return TextRange(start: safeStart, end: safeEnd);
}

bool _hasBlockFormat(String prefix, ChatTextFormat format) => switch (format) {
      ChatTextFormat.quote => prefix.startsWith('>'),
      ChatTextFormat.bulletList =>
        prefix.startsWith('-') || prefix.startsWith('*'),
      ChatTextFormat.numberedList => RegExp(r'^[0-9]+\.').hasMatch(prefix),
      _ => false,
    };

TextEditingValue _formatBlocks(TextEditingValue value, ChatTextFormat format) {
  final selection = value.selection;
  final text = value.text;
  final firstLine = selection.start == 0
      ? 0
      : text.lastIndexOf('\n', selection.start - 1) + 1;
  final lastOffset = selection.isCollapsed ? selection.end : selection.end - 1;
  final lines = <({int start, int end, String indent, String prefix})>[];
  var start = firstLine;
  while (start <= lastOffset && start < text.length) {
    final newline = text.indexOf('\n', start);
    final end = newline < 0 ? text.length : newline;
    final line = text.substring(start, end);
    final prefix = _blockPrefix.firstMatch(line);
    final indent = prefix?.group(1) ?? RegExp(r'^[ \t]*').stringMatch(line)!;
    final content = line.substring(prefix?.end ?? indent.length);
    if (content.trim().isNotEmpty) {
      lines.add((
        start: start + indent.length,
        end: start + (prefix?.end ?? indent.length),
        indent: indent,
        prefix: prefix?.group(2) ?? '',
      ));
    }
    start = end + 1;
  }
  if (lines.isEmpty) return value;
  final remove = lines.every((line) => _hasBlockFormat(line.prefix, format));
  final edits = <_Edit>[];
  var number = 0;
  for (final line in lines) {
    number++;
    final prefix = remove
        ? ''
        : switch (format) {
            ChatTextFormat.quote => '> ',
            ChatTextFormat.bulletList => '- ',
            ChatTextFormat.numberedList => '$number. ',
            _ => '',
          };
    edits.add(_Edit(line.start, line.end, prefix));
  }
  return _applyEdits(value, edits, selection.start, selection.end);
}

class _Edit {
  const _Edit(this.start, this.end, this.replacement,
      {this.startMap, this.endMap});
  final int start;
  final int end;
  final String replacement;
  final List<int>? startMap;
  final List<int>? endMap;
}

TextEditingValue _applyEdits(
    TextEditingValue value, List<_Edit> edits, int start, int end) {
  if (edits.isEmpty) return value;
  edits.sort((a, b) {
    final position = a.start.compareTo(b.start);
    return position == 0 ? a.end.compareTo(b.end) : position;
  });
  final result = StringBuffer();
  var previous = 0;
  for (final edit in edits) {
    result
      ..write(value.text.substring(previous, edit.start))
      ..write(edit.replacement);
    previous = edit.end;
  }
  result.write(value.text.substring(previous));

  int mapOffset(int offset, {required bool beginning}) {
    var shift = 0;
    for (final edit in edits) {
      if (offset < edit.start) break;
      if (edit.startMap != null && offset <= edit.end) {
        final positions = beginning ? edit.startMap! : edit.endMap!;
        return edit.start + shift + positions[offset - edit.start];
      }
      if (edit.start == edit.end && offset == edit.start) {
        return offset + shift + (beginning ? edit.replacement.length : 0);
      }
      if (offset < edit.end) {
        return edit.start + shift + edit.replacement.length;
      }
      shift += edit.replacement.length - (edit.end - edit.start);
    }
    return offset + shift;
  }

  final mappedStart = mapOffset(start, beginning: true);
  final mappedEnd = mapOffset(end, beginning: value.selection.isCollapsed);
  final reversed = value.selection.baseOffset > value.selection.extentOffset;
  return value.copyWith(
      text: result.toString(),
      selection: TextSelection(
          baseOffset: reversed ? mappedEnd : mappedStart,
          extentOffset: reversed ? mappedStart : mappedEnd,
          affinity: value.selection.affinity,
          isDirectional: value.selection.isDirectional),
      composing: TextRange.empty);
}
