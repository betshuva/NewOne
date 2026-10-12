import 'package:betshuva/chat_text_formatting.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

String rendered(String text) =>
    parseChatFormattedText(text).map((run) => run.text).join();

TextEditingValue selected(String text, {int? start, int? end}) =>
    TextEditingValue(
        text: text,
        selection: TextSelection(
            baseOffset: start ?? 0, extentOffset: end ?? text.length));

void main() {
  group('message formatting parser', () {
    test(
        'ordinary Hebrew, URLs, HTML, unmatched and escaped markers stay plain',
        () {
      for (final text in [
        'שלום עולם 😀\nשורה שנייה',
        'snake_case and _another_name and Hebrew_שם',
        'https://example.com/snake_case?q=שלום',
        '<b>שלום</b> [link](https://example.com)',
        '**missing close',
        'missing close~~',
        '_missing close',
        '`missing close',
        r'\**escaped** and \_escaped_ and \~~escaped~~ and \`code`',
        r'\*escaped* and \***escaped***',
        '**two words **',
        '  > ',
        '- ',
        '1. ',
      ]) {
        final runs = parseChatFormattedText(text);
        expect(runs.map((run) => run.text).join(), text, reason: text);
        expect(
            runs.any((run) =>
                run.bold || run.italic || run.strikethrough || run.code),
            isFalse,
            reason: text);
      }
    });

    test('balanced nested styles render together and code stays literal', () {
      final runs = parseChatFormattedText(
          '**שלום _נטוי ~~מחוק~~_** וגם `**קוד** _פשוט_`');
      expect(runs.map((run) => run.text).join(),
          'שלום נטוי מחוק וגם **קוד** _פשוט_');
      final nested = runs.singleWhere((run) => run.text == 'מחוק');
      expect(nested.bold && nested.italic && nested.strikethrough, isTrue);
      final code = runs.singleWhere((run) => run.code);
      expect(code.text, '**קוד** _פשוט_');
      expect(code.bold || code.italic || code.strikethrough, isFalse);
    });

    test('single star italic nests with bold and shared triple star boundaries',
        () {
      final runs =
          parseChatFormattedText('**before *inside* after** and ***both***');
      expect(
          runs.map((run) => run.text).join(), 'before inside after and both');
      for (final word in ['inside', 'both']) {
        final run = runs.singleWhere((run) => run.text == word);
        expect(run.bold && run.italic, isTrue);
      }
      final reverse = parseChatFormattedText('*before **inside** after*');
      expect(reverse.map((run) => run.text).join(), 'before inside after');
      expect(reverse.every((run) => run.italic), isTrue);
      expect(reverse.singleWhere((run) => run.text == 'inside').bold, isTrue);
      for (final text in [
        '***both***',
        '**before *inside* after**',
        '*before **inside** after*',
        r'\***escaped*** and he*ll*o snake_case',
      ]) {
        expect(
            parseChatFormattedText(text, preserveMarkers: true)
                .map((run) => run.text)
                .join(),
            text);
      }
    });

    test('each repeated pair has its own style without leaking into plain text',
        () {
      final runs = parseChatFormattedText('**א** רגיל **ב** _ג_ ~~ד~~');
      expect(runs.where((run) => run.bold).map((run) => run.text).join(), 'אב');
      expect(runs.singleWhere((run) => run.italic).text, 'ג');
      expect(runs.singleWhere((run) => run.strikethrough).text, 'ד');
      expect(
          runs.singleWhere((run) => run.text.contains('רגיל')).bold, isFalse);
    });

    test('quotes, indented lists and CRLF preserve line and whitespace layout',
        () {
      const text = '> **שלום**\r\n  - ראשון\n\n2. שני\n  רגיל\n';
      final runs = parseChatFormattedText(text);
      expect(runs.map((run) => run.text).join(),
          '│ שלום\r\n  • ראשון\n\n2. שני\n  רגיל\n');
      expect(runs.singleWhere((run) => run.text == 'שלום').quote, isTrue);
      expect(runs.last.quote, isFalse);
    });

    test('editor run lengths and joined source preserve all UTF-16 offsets',
        () {
      for (final text in [
        '> **שם _מודגש_**\r\n- \u2066👩🏽‍💻\u2069 ~~משהו~~\n',
        '`**קוד**`  \u2066😀\u2069',
        r'\**רגיל** _נטוי_ snake_case',
        '**סיום**\n\n',
        '\r',
        '',
      ]) {
        final runs = parseChatFormattedText(text, preserveMarkers: true);
        expect(runs.map((run) => run.text).join(), text);
        expect(runs.fold<int>(0, (sum, run) => sum + run.text.length),
            text.length);
      }
      final editor = parseChatFormattedText('**שלום**', preserveMarkers: true);
      expect(editor.where((run) => run.marker).map((run) => run.text).join(),
          '****');
      expect(editor.singleWhere((run) => !run.marker).bold, isTrue);
    });
  });

  group('selection formatting', () {
    test('inline commands wrap the selection and reverse without losing caret',
        () {
      for (final entry in {
        ChatTextFormat.bold: '**',
        ChatTextFormat.italic: '_',
        ChatTextFormat.strikethrough: '~~',
        ChatTextFormat.code: '`',
      }.entries) {
        final original = selected('פתיחה שלום סיום', start: 6, end: 10);
        final formatted = formatChatSelection(original, entry.key);
        expect(formatted.text, 'פתיחה ${entry.value}שלום${entry.value} סיום');
        expect(formatted.selection.textInside(formatted.text), 'שלום');
        expect(formatChatSelection(formatted, entry.key), original);
      }
    });

    test('italic applies to a selected word fragment and preserves snake_case',
        () {
      for (final entry in [
        (text: 'שלום', start: 1, end: 3, expected: 'ש*לו*ם'),
        (text: 'hello', start: 2, end: 4, expected: 'he*ll*o'),
        (text: 'hello', start: 0, end: 2, expected: '*he*llo'),
        (text: 'hello', start: 3, end: 5, expected: 'hel*lo*'),
      ]) {
        final original =
            selected(entry.text, start: entry.start, end: entry.end);
        final result = formatChatSelection(original, ChatTextFormat.italic);
        expect(result.text, entry.expected);
        expect(rendered(result.text), original.text);
        final styled = parseChatFormattedText(result.text)
            .singleWhere((run) => run.italic);
        expect(styled.text, original.selection.textInside(original.text));
        expect(result.selection.textInside(result.text), styled.text);
        expect(formatChatSelection(result, ChatTextFormat.italic), original);
      }
      expect(
          rendered('he_ll_o snake_case ש_לו_ם'), 'he_ll_o snake_case ש_לו_ם');
      final normal =
          formatChatSelection(selected('שלום'), ChatTextFormat.italic);
      expect(normal.text, '_שלום_');
    });

    test('bold wraps an italic word fragment using shared star boundaries', () {
      final original = selected('hello', start: 2, end: 4);
      final italic = formatChatSelection(original, ChatTextFormat.italic);
      final bold = formatChatSelection(italic, ChatTextFormat.bold);
      expect(bold.text, 'he***ll***o');
      expect(rendered(bold.text), original.text);
      final run =
          parseChatFormattedText(bold.text).singleWhere((run) => run.bold);
      expect(run.text, 'll');
      expect(run.italic, isTrue);
      expect(formatChatSelection(bold, ChatTextFormat.bold), italic);
    });

    test('backward selection keeps base, extent, affinity and direction', () {
      final original = TextEditingValue(
          text: 'א \u2066👨‍👩‍👧‍👦\u2069 ב',
          selection: const TextSelection(
              baseOffset: 15,
              extentOffset: 2,
              affinity: TextAffinity.upstream,
              isDirectional: true));
      final result = formatChatSelection(original, ChatTextFormat.bold);
      expect(result.selection.baseOffset,
          greaterThan(result.selection.extentOffset));
      expect(result.selection.affinity, TextAffinity.upstream);
      expect(result.selection.isDirectional, isTrue);
      expect(formatChatSelection(result, ChatTextFormat.bold), original);
      expect(rendered(result.text), original.text);
    });

    test('selection including existing wrappers toggles them off', () {
      final result =
          formatChatSelection(selected('**שלום**'), ChatTextFormat.bold);
      expect(result.text, 'שלום');
      expect(result.selection,
          const TextSelection(baseOffset: 0, extentOffset: 4));
    });

    test('partial UTF-16 selection expands over the whole emoji grapheme', () {
      const emoji = '👩🏽‍💻';
      final source = selected('א $emoji ב', start: 3, end: 5);
      final result = formatChatSelection(source, ChatTextFormat.bold);
      expect(result.text, 'א **$emoji** ב');
      expect(result.selection.textInside(result.text), emoji);
      expect(rendered(result.text), source.text);
      final clean = formatChatSelection(result, ChatTextFormat.bold);
      expect(clean.text, source.text);
      expect(clean.selection.textInside(clean.text), emoji);
    });

    test('Hebrew combining marks and custom emoji preserve graphemes', () {
      final hebrew = formatChatSelection(
          selected('שָׁלוֹם', start: 1, end: 2), ChatTextFormat.code);
      expect(hebrew.text, '`שָׁ`לוֹם');
      expect(hebrew.selection.textInside(hebrew.text), 'שָׁ');
      const source = '\u2066😀\u2069 שלום';
      final result = formatChatSelection(selected(source), ChatTextFormat.bold);
      expect(rendered(result.text), source);
      expect(formatChatSelection(result, ChatTextFormat.bold).text, source);
    });

    test('active composition and invalid selections are never mutated', () {
      final composing = TextEditingValue(
          text: 'שלום',
          selection: const TextSelection(baseOffset: 0, extentOffset: 4),
          composing: const TextRange(start: 1, end: 3));
      final invalid = const TextEditingValue(text: 'שלום');
      final outside = TextEditingValue(
          text: 'שלום',
          selection: const TextSelection(baseOffset: 0, extentOffset: 99));
      for (final format in ChatTextFormat.values) {
        for (final value in [composing, invalid, outside]) {
          expect(identical(formatChatSelection(value, format), value), isTrue);
        }
      }
    });

    test('empty selections never produce inline marker-only text', () {
      for (final text in ['', 'שלום', '  \n ']) {
        final value = TextEditingValue(
            text: text, selection: const TextSelection.collapsed(offset: 0));
        for (final format in [
          ChatTextFormat.bold,
          ChatTextFormat.italic,
          ChatTextFormat.strikethrough,
          ChatTextFormat.code,
        ]) {
          expect(formatChatSelection(value, format), value);
        }
      }
      for (final format in ChatTextFormat.values) {
        final empty = selected('  \n\t');
        expect(formatChatSelection(empty, format), empty);
      }
    });

    test(
        'multiline inline selection formats content while preserving whitespace',
        () {
      final source = selected('  שלום \r\n\n עולם\t');
      final result = formatChatSelection(source, ChatTextFormat.bold);
      expect(result.text, '  **שלום** \r\n\n **עולם**\t');
      expect(rendered(result.text), source.text);
      expect(formatChatSelection(result, ChatTextFormat.bold), source);
    });

    test('a second style nests correctly within the first style', () {
      final bold = formatChatSelection(selected('שלום'), ChatTextFormat.bold);
      final italic = formatChatSelection(bold, ChatTextFormat.italic);
      expect(italic.text, '**_שלום_**');
      final content = parseChatFormattedText(italic.text).single;
      expect(content.bold && content.italic, isTrue);
      expect(formatChatSelection(italic, ChatTextFormat.italic), bold);
    });

    test(
        'extending formatting over already styled words avoids overlapping pairs',
        () {
      for (final text in ['שלום **עולם**', '**שלום** וגם **עולם**']) {
        final result = formatChatSelection(selected(text), ChatTextFormat.bold);
        final expected = rendered(text);
        expect(result.text, '**$expected**');
        expect(rendered(result.text), expected);
        expect(result.selection.textInside(result.text), expected);
        expect(parseChatFormattedText(result.text).every((run) => run.bold),
            isTrue);
        expect(formatChatSelection(result, ChatTextFormat.bold).text, expected);
      }
    });

    test('a whole selection has to be one balanced pair to toggle its wrapper',
        () {
      final original = selected('**א** באמצע **ב**');
      final result = formatChatSelection(original, ChatTextFormat.bold);
      expect(result.text, '**א באמצע ב**');
      expect(rendered(result.text), rendered(original.text));
      expect(result.selection.textInside(result.text), 'א באמצע ב');
    });

    test('formatting across a wrapper boundary preserves all visible content',
        () {
      for (final entry in [
        (
          text: '**hello** world',
          start: 4,
          end: 12,
          format: ChatTextFormat.bold
        ),
        (
          text: '_hello_ world',
          start: 3,
          end: 10,
          format: ChatTextFormat.italic
        ),
        (text: '_hello_ world', start: 3, end: 10, format: ChatTextFormat.bold),
        (
          text: '**hello** world',
          start: 4,
          end: 12,
          format: ChatTextFormat.italic
        ),
        (
          text: 'a **hello** world',
          start: 0,
          end: 7,
          format: ChatTextFormat.bold
        ),
        (
          text: 'a **hello** world',
          start: 0,
          end: 7,
          format: ChatTextFormat.italic
        ),
        (
          text: 'a _hello_ world',
          start: 0,
          end: 6,
          format: ChatTextFormat.bold
        ),
        (
          text: 'a _hello_ world',
          start: 0,
          end: 6,
          format: ChatTextFormat.italic
        ),
        (
          text: 'before _hello world_',
          start: 0,
          end: 13,
          format: ChatTextFormat.bold
        ),
        (
          text: 'before **hello world**',
          start: 0,
          end: 14,
          format: ChatTextFormat.italic
        ),
      ]) {
        final original =
            selected(entry.text, start: entry.start, end: entry.end);
        final result = formatChatSelection(original, entry.format);
        expect(rendered(result.text), rendered(original.text),
            reason: result.text);
        final runs = parseChatFormattedText(result.text);
        final formatted = runs.where((run) => switch (entry.format) {
              ChatTextFormat.bold => run.bold,
              ChatTextFormat.italic => run.italic,
              _ => false,
            });
        expect(formatted, isNotEmpty, reason: result.text);
        var position = 0;
        for (final run
            in parseChatFormattedText(result.text, preserveMarkers: true)) {
          final runStart = position;
          position += run.text.length;
          if (run.marker ||
              runStart >= result.selection.end ||
              position <= result.selection.start) {
            continue;
          }
          final overlapStart = result.selection.start > runStart
              ? result.selection.start - runStart
              : 0;
          final overlapEnd = result.selection.end < position
              ? result.selection.end - runStart
              : run.text.length;
          if (run.text.substring(overlapStart, overlapEnd).trim().isEmpty) {
            continue;
          }
          expect(entry.format == ChatTextFormat.bold ? run.bold : run.italic,
              isTrue,
              reason: '${result.text}: ${run.text}');
        }
        expect(result.selection.isValid, isTrue);
        expect(result.selection.end, lessThanOrEqualTo(result.text.length));
        expect(
            parseChatFormattedText(result.text, preserveMarkers: true)
                .map((run) => run.text)
                .join(),
            result.text);
      }
    });

    test('balanced rewrite maps the selected visible slice in either direction',
        () {
      for (final backwards in [false, true]) {
        final original = selected('**hello** world',
            start: backwards ? 12 : 4, end: backwards ? 4 : 12);
        final result = formatChatSelection(original, ChatTextFormat.bold);
        expect(result.text, '**hello wo**rld');
        expect(result.selection.textInside(result.text), 'llo wo');
        expect(result.selection.baseOffset > result.selection.extentOffset,
            backwards);
      }
    });

    test(
        'toggling a partial styled prefix, middle or suffix preserves other text',
        () {
      for (final entry in [
        (marker: '**', format: ChatTextFormat.bold),
        (marker: '_', format: ChatTextFormat.italic),
        (marker: '~~', format: ChatTextFormat.strikethrough),
        (marker: '`', format: ChatTextFormat.code),
      ]) {
        for (final range in [
          (start: 0, end: 2),
          (start: 1, end: 4),
          (start: 1, end: 5)
        ]) {
          final original = selected(
              '${entry.marker}hello${entry.marker} _world_',
              start: entry.marker.length + range.start,
              end: entry.marker.length + range.end);
          final result = formatChatSelection(original, entry.format);
          expect(rendered(result.text), 'hello world', reason: result.text);
          expect(result.selection.textInside(result.text),
              'hello'.substring(range.start, range.end));
          var position = 0;
          for (final run
              in parseChatFormattedText(result.text, preserveMarkers: true)) {
            final runStart = position;
            position += run.text.length;
            if (run.marker ||
                runStart >= result.selection.end ||
                position <= result.selection.start) {
              continue;
            }
            final active = switch (entry.format) {
              ChatTextFormat.bold => run.bold,
              ChatTextFormat.italic => run.italic,
              ChatTextFormat.strikethrough => run.strikethrough,
              ChatTextFormat.code => run.code,
              _ => false,
            };
            expect(active, isFalse, reason: result.text);
          }
          expect(
              parseChatFormattedText(result.text)
                  .singleWhere((run) => run.text == 'world')
                  .italic,
              isTrue);
        }
      }
      final result = formatChatSelection(
          selected('**hello** _world_', start: 3, end: 7), ChatTextFormat.bold);
      expect(result.text, '**h**ello _world_');
    });

    test('bold goes outside existing code and code content remains literal',
        () {
      final source = selected('שלום');
      final code = formatChatSelection(source, ChatTextFormat.code);
      final bold = formatChatSelection(code, ChatTextFormat.bold);
      expect(bold.text, '**`שלום`**');
      final run = parseChatFormattedText(bold.text).single;
      expect(run.text, 'שלום');
      expect(run.bold && run.code, isTrue);
      expect(bold.selection.textInside(bold.text), 'שלום');
      expect(formatChatSelection(bold, ChatTextFormat.bold).text, code.text);
      const typedSource = '`**typed literal** snake_case`';
      final typed = formatChatSelection(
          selected(typedSource, start: 1, end: typedSource.length - 1),
          ChatTextFormat.bold);
      expect(rendered(typed.text), '**typed literal** snake_case');
      final typedRun = parseChatFormattedText(typed.text).single;
      expect(typedRun.code && typedRun.bold, isTrue);
    });

    test(
        'code over whole existing wrappers keeps styles outside literal content',
        () {
      for (final text in [
        '**hello world**',
        '_hello world_',
        '~~hello world~~',
        '**_hello world_**',
        '- **hello world**',
        '> **_hello world_**',
        '1. _hello world_',
      ]) {
        final result = formatChatSelection(selected(text), ChatTextFormat.code);
        expect(rendered(result.text), rendered(text), reason: result.text);
        final content = parseChatFormattedText(result.text)
            .where((run) => run.text.contains('hello'));
        expect(content, isNotEmpty);
        expect(content.every((run) => run.code), isTrue);
        final clean = formatChatSelection(result, ChatTextFormat.code);
        expect(rendered(clean.text), rendered(text), reason: clean.text);
        expect(
            parseChatFormattedText(clean.text).any((run) => run.code), isFalse);
      }
      final nested = formatChatSelection(
          selected('**_hello world_**', start: 2, end: 15),
          ChatTextFormat.code);
      expect(nested.text, '**_`hello world`_**');
      final runs = parseChatFormattedText(nested.text);
      expect(runs.single.text, 'hello world');
      expect(
          runs.single.bold && runs.single.italic && runs.single.code, isTrue);
    });

    test(
        'balanced rewrite retains emoji, combining marks and isolate characters',
        () {
      const text = '**שָׁלוֹם \u2066👩🏽‍💻\u2069** עולם ';
      final start = text.indexOf('לוֹ');
      final end = text.indexOf('עולם') + 2;
      final original = selected(text, start: end, end: start);
      final result = formatChatSelection(original, ChatTextFormat.italic);
      expect(rendered(result.text), rendered(text));
      expect(
          result.selection.baseOffset > result.selection.extentOffset, isTrue);
      expect(result.text, contains('👩🏽‍💻'));
      expect(result.text, contains('\u2066'));
      expect(result.text, contains('\u2069'));
      expect(result.text, contains(''));
    });
  });

  group('chat colors', () {
    test(
        'valid colors style content and metadata remains source-exact and separate',
        () {
      const source =
          '[[bt-style:fg=1976d2;bg=FFF59D]]**שלום**[[/bt-style]] רגיל';
      final runs = parseChatFormattedText(source);
      expect(runs.map((run) => run.text).join(), 'שלום רגיל');
      final colored = runs.first;
      expect(colored.bold, isTrue);
      expect(colored.foregroundRgb, 0x1976d2);
      expect(colored.backgroundRgb, 0xfff59d);
      expect(runs.last.foregroundRgb, isNull);
      final editor = parseChatFormattedText(source, preserveMarkers: true);
      expect(editor.map((run) => run.text).join(), source);
      final metadata =
          editor.where((run) => run.marker && run.text.startsWith('[['));
      expect(metadata.map((run) => run.text).toList(), [
        '[[bt-style:fg=1976d2;bg=FFF59D]]',
        '[[/bt-style]]',
      ]);
      expect(metadata.every((run) => run.foregroundRgb == 0x1976d2), isTrue);
      expect(editor.where((run) => run.marker && run.text == '**').length, 2);
    });

    test('invalid, unmatched and escaped color tags stay literal', () {
      for (final source in [
        '[[bt-style:fg=xyzxyz]]שלום[[/bt-style]]',
        '[[bt-style:fg=12345]]שלום[[/bt-style]]',
        '[[bt-style:fg=123456;fg=654321]]שלום[[/bt-style]]',
        '[[bt-style:bg=123456;bg=654321]]שלום[[/bt-style]]',
        '[[bt-style:html=123456]]שלום[[/bt-style]]',
        '[[bt-style:fg=123456]]שלום',
        'שלום[[/bt-style]]',
        r'\[[bt-style:fg=123456]]שלום[[/bt-style]]',
      ]) {
        final runs = parseChatFormattedText(source);
        expect(runs.map((run) => run.text).join(), source);
        expect(
            runs.every((run) =>
                run.foregroundRgb == null && run.backgroundRgb == null),
            isTrue);
      }
      const literal = '[[bt-style:fg=123456]]שלום[[/bt-style]]';
      final code = parseChatFormattedText('`$literal`');
      expect(code.single.text, literal);
      expect(code.single.code, isTrue);
      expect(code.single.foregroundRgb, isNull);
      const empty = '[[bt-style:fg=123456]][[/bt-style]]';
      expect(rendered(empty), '');
      expect(
          parseChatFormattedText(empty, preserveMarkers: true)
              .map((run) => run.text)
              .join(),
          empty);
    });

    test('nested colors inherit missing attributes and restore the outer color',
        () {
      const source =
          '[[bt-style:fg=000000]]א[[bt-style:bg=FFF59D]]ב[[/bt-style]]ג[[/bt-style]]';
      final runs = parseChatFormattedText(source);
      expect(runs.map((run) => run.text).join(), 'אבג');
      expect(runs.every((run) => run.foregroundRgb == 0), isTrue);
      expect(
          runs.singleWhere((run) => run.text == 'ב').backgroundRgb, 0xfff59d);
      expect(runs.first.backgroundRgb, isNull);
      expect(runs.last.backgroundRgb, isNull);
    });

    test(
        'both colors can be set and independently cleared with backward selection',
        () {
      final original = selected('שלום עולם', start: 4, end: 0);
      final fg = colorChatSelection(original, ChatTextColorTarget.foreground,
          rgb: 0x1976d2);
      expect(fg.text, '[[bt-style:fg=1976D2]]שלום[[/bt-style]] עולם');
      expect(fg.selection.textInside(fg.text), 'שלום');
      expect(fg.selection.baseOffset > fg.selection.extentOffset, isTrue);
      final bg =
          colorChatSelection(fg, ChatTextColorTarget.background, rgb: 0xfff59d);
      expect(bg.text, '[[bt-style:fg=1976D2;bg=FFF59D]]שלום[[/bt-style]] עולם');
      final clearFg = colorChatSelection(bg, ChatTextColorTarget.foreground);
      expect(clearFg.text, '[[bt-style:bg=FFF59D]]שלום[[/bt-style]] עולם');
      expect(parseChatFormattedText(clearFg.text).first.foregroundRgb, isNull);
      expect(
          parseChatFormattedText(clearFg.text).first.backgroundRgb, 0xfff59d);
      expect(colorChatSelection(clearFg, ChatTextColorTarget.background),
          original);
    });

    test(
        'partial color replacement and clearing preserve colors outside the selection',
        () {
      final colored = colorChatSelection(
          selected('hello world'), ChatTextColorTarget.foreground,
          rgb: 0x1976d2);
      final contentStart = colored.text.indexOf('hello');
      final partial = selected(colored.text,
          start: contentStart + 1, end: contentStart + 4);
      final replaced = colorChatSelection(
          partial, ChatTextColorTarget.foreground,
          rgb: 0xd32f2f);
      expect(rendered(replaced.text), 'hello world');
      expect(replaced.selection.textInside(replaced.text), 'ell');
      final runs = parseChatFormattedText(replaced.text);
      expect(
          runs.singleWhere((run) => run.text == 'ell').foregroundRgb, 0xd32f2f);
      expect(runs.first.foregroundRgb, 0x1976d2);
      expect(runs.last.foregroundRgb, 0x1976d2);
      final clear =
          colorChatSelection(replaced, ChatTextColorTarget.foreground);
      expect(rendered(clear.text), 'hello world');
      expect(
          parseChatFormattedText(clear.text)
              .singleWhere((run) => run.text == 'ell')
              .foregroundRgb,
          isNull);
    });

    test(
        'inline formats preserve colors before and after color actions and toggles',
        () {
      for (final format in [
        ChatTextFormat.bold,
        ChatTextFormat.italic,
        ChatTextFormat.strikethrough,
        ChatTextFormat.code,
      ]) {
        final original = selected('שלום');
        final fg = colorChatSelection(original, ChatTextColorTarget.foreground,
            rgb: 0x1976d2);
        final colorFirst = formatChatSelection(fg, format);
        final formatFirst = colorChatSelection(
            formatChatSelection(original, format),
            ChatTextColorTarget.foreground,
            rgb: 0x1976d2);
        for (final result in [colorFirst, formatFirst]) {
          expect(rendered(result.text), original.text);
          final run = parseChatFormattedText(result.text).single;
          expect(run.foregroundRgb, 0x1976d2);
          expect(
              switch (format) {
                ChatTextFormat.bold => run.bold,
                ChatTextFormat.italic => run.italic,
                ChatTextFormat.strikethrough => run.strikethrough,
                ChatTextFormat.code => run.code,
                _ => false,
              },
              isTrue);
          expect(result.selection.textInside(result.text), original.text);
          final clean = formatChatSelection(result, format);
          expect(rendered(clean.text), original.text);
          expect(parseChatFormattedText(clean.text).single.foregroundRgb,
              0x1976d2);
        }
      }
    });

    test(
        'style selections crossing either color boundary retain visible text and color',
        () {
      const source = 'a [[bt-style:fg=1976D2]]hello[[/bt-style]] world';
      final hello = source.indexOf('hello');
      final end = source.indexOf('world') + 2;
      for (final format in [
        ChatTextFormat.bold,
        ChatTextFormat.italic,
        ChatTextFormat.strikethrough,
        ChatTextFormat.code,
      ]) {
        for (final original in [
          selected(source, start: hello + 1, end: end),
          selected(source, start: 0, end: hello + 3),
        ]) {
          final result = formatChatSelection(original, format);
          expect(rendered(result.text), 'a hello world', reason: result.text);
          expect(
              parseChatFormattedText(result.text)
                  .where((run) => run.foregroundRgb == 0x1976d2)
                  .map((run) => run.text)
                  .join(),
              'hello');
          expect(
              parseChatFormattedText(result.text, preserveMarkers: true)
                  .map((run) => run.text)
                  .join(),
              result.text);
        }
      }
    });

    test(
        'color selection crossing bold retains original bold and highlights only selection',
        () {
      const source = '**hello** world';
      final result = colorChatSelection(
          selected(source, start: 4, end: 12), ChatTextColorTarget.background,
          rgb: 0xfff59d);
      final runs = parseChatFormattedText(result.text);
      expect(runs.map((run) => run.text).join(), 'hello world');
      expect(
          runs.where((run) => run.bold).map((run) => run.text).join(), 'hello');
      expect(
          runs
              .where((run) => run.backgroundRgb == 0xfff59d)
              .map((run) => run.text)
              .join(),
          'llo wo');
    });

    test('literal code remains literal under color and subsequent bold', () {
      const literal = '**typed literal** snake_case';
      final colored = colorChatSelection(
          selected('`$literal`', start: 1, end: literal.length + 1),
          ChatTextColorTarget.foreground,
          rgb: 0x1976d2);
      final bold = formatChatSelection(colored, ChatTextFormat.bold);
      final run = parseChatFormattedText(bold.text).single;
      expect(run.text, literal);
      expect(run.code && run.bold, isTrue);
      expect(run.foregroundRgb, 0x1976d2);
      expect(bold.text.startsWith('[[bt-style:'), isTrue);
    });

    test(
        'block commands retain colors and keep metadata after the block prefix',
        () {
      for (final format in [
        ChatTextFormat.bulletList,
        ChatTextFormat.numberedList,
        ChatTextFormat.quote,
      ]) {
        final colored = colorChatSelection(
            selected('שלום'), ChatTextColorTarget.background,
            rgb: 0xfff59d);
        final block = formatChatSelection(colored, format);
        expect(block.text.indexOf('[[bt-style:'), greaterThan(0));
        expect(
            parseChatFormattedText(block.text)
                .singleWhere((run) => run.text == 'שלום')
                .backgroundRgb,
            0xfff59d);
        final after = colorChatSelection(
            selected(block.text), ChatTextColorTarget.foreground,
            rgb: 0x1976d2);
        expect(after.text.indexOf('[[bt-style:'), greaterThan(0));
        expect(rendered(after.text), rendered(block.text));
        final clean = formatChatSelection(after, format);
        expect(rendered(clean.text), 'שלום');
        final run = parseChatFormattedText(clean.text).single;
        expect(run.foregroundRgb, 0x1976d2);
        expect(run.backgroundRgb, 0xfff59d);
      }
    });

    test('multiline colors preserve whitespace, CRLF and editor source exactly',
        () {
      final original = selected('  שלום \r\n\n עולם\t');
      final result = colorChatSelection(
          original, ChatTextColorTarget.background,
          rgb: 0xfff59d);
      expect(rendered(result.text), original.text);
      expect(
          parseChatFormattedText(result.text, preserveMarkers: true)
              .map((run) => run.text)
              .join(),
          result.text);
      expect(
          colorChatSelection(result, ChatTextColorTarget.background), original);
    });

    test(
        'coloring expands graphemes and preserves RTL isolates and backward direction',
        () {
      const text = 'א \u2066👩🏽‍💻\u2069 שָׁלוֹם \uE123';
      final result = colorChatSelection(
          selected(text, start: 5, end: 3), ChatTextColorTarget.foreground,
          rgb: 0x1976d2);
      expect(rendered(result.text), text);
      expect(result.selection.textInside(result.text), '👩🏽‍💻');
      expect(
          result.selection.baseOffset > result.selection.extentOffset, isTrue);
      expect(result.text, contains('\u2066'));
      expect(result.text, contains('\u2069'));
      expect(result.text, contains('\uE123'));
    });

    test(
        'IME, empty selection, invalid RGB and metadata-only selections do not mutate',
        () {
      final composing = TextEditingValue(
          text: 'שלום',
          selection: const TextSelection(baseOffset: 0, extentOffset: 4),
          composing: const TextRange(start: 1, end: 3));
      const empty = TextEditingValue(
          text: 'שלום', selection: TextSelection.collapsed(offset: 2));
      for (final target in ChatTextColorTarget.values) {
        for (final original in [composing, empty, selected(' \n\t')]) {
          expect(colorChatSelection(original, target, rgb: 0x1976d2), original);
        }
        for (final rgb in [-1, 0x1000000]) {
          final original = selected('שלום');
          expect(colorChatSelection(original, target, rgb: rgb), original);
        }
      }
      const source = '[[bt-style:fg=1976D2]]שלום[[/bt-style]]';
      final metadata = selected(source, start: 0, end: source.indexOf('שלום'));
      expect(
          colorChatSelection(metadata, ChatTextColorTarget.background,
              rgb: 0xfff59d),
          metadata);
      final unchanged = selected('**שלום**');
      expect(colorChatSelection(unchanged, ChatTextColorTarget.foreground),
          unchanged);
    });
  });

  group('editing hidden color metadata', () {
    TextEditingValue incomingEdit(
        TextEditingValue previous, String replacement) {
      final selection = previous.selection;
      return TextEditingValue(
          text: previous.text
              .replaceRange(selection.start, selection.end, replacement),
          selection: TextSelection.collapsed(
              offset: selection.start + replacement.length));
    }

    const source =
        'לפני [[bt-style:fg=1976D2;bg=FFF59D]]שלום[[/bt-style]] אחרי';

    test('delete and replace across an opening preserve the colored suffix',
        () {
      final end = source.indexOf('שלום') + 2;
      for (final replacement in ['', 'חדש']) {
        final previous = selected(source, start: 2, end: end);
        final incoming = incomingEdit(previous, replacement);
        final repaired = repairChatColorEditingValue(previous, incoming);
        expect(rendered(repaired.text), 'לפ$replacementום אחרי');
        final suffix = parseChatFormattedText(repaired.text)
            .singleWhere((run) => run.text == 'ום');
        expect(suffix.foregroundRgb, 0x1976d2);
        expect(suffix.backgroundRgb, 0xfff59d);
        expect(repaired.selection.isCollapsed, isTrue);
        expect(repaired.selection.end, lessThanOrEqualTo(repaired.text.length));
        expect(
            parseChatFormattedText(repaired.text, preserveMarkers: true)
                .map((run) => run.text)
                .join(),
            repaired.text);
      }
    });

    test('delete and replace across a closing preserve the colored prefix', () {
      final start = source.indexOf('שלום') + 2;
      final end = source.indexOf('[[/bt-style]]') + '[[/bt-style]]'.length + 1;
      for (final replacement in ['', 'חדש']) {
        final previous = selected(source, start: start, end: end);
        final repaired = repairChatColorEditingValue(
            previous, incomingEdit(previous, replacement));
        expect(rendered(repaired.text), 'לפני של$replacementאחרי');
        final colored = parseChatFormattedText(repaired.text)
            .where((run) => run.foregroundRgb == 0x1976d2);
        expect(colored.map((run) => run.text).join().startsWith('של'), isTrue);
        expect(colored.every((run) => run.backgroundRgb == 0xfff59d), isTrue);
      }
    });

    test('crossing adjacent wrappers keeps both surviving colors and styles',
        () {
      const text = 'a [[bt-style:fg=D32F2F]]**one**[[/bt-style]] '
          '[[bt-style:bg=FFF59D]]_two_[[/bt-style]] z';
      final previous = selected(text,
          start: text.indexOf('one') + 1, end: text.indexOf('two') + 2);
      final repaired =
          repairChatColorEditingValue(previous, incomingEdit(previous, ''));
      expect(rendered(repaired.text), 'a oo z');
      final runs = parseChatFormattedText(repaired.text);
      final red = runs.singleWhere((run) => run.foregroundRgb == 0xd32f2f);
      expect(red.text, 'o');
      expect(red.bold, isTrue);
      final yellow = runs.singleWhere((run) => run.backgroundRgb == 0xfff59d);
      expect(yellow.text, 'o');
      expect(yellow.italic, isTrue);
    });

    test('repair maps backward replacement selection and collapsed composing',
        () {
      final end = source.indexOf('שלום') + 2;
      final previous = selected(source, start: end, end: 2);
      final raw = incomingEdit(previous, 'חדש');
      final incoming = raw.copyWith(
          selection: const TextSelection(
              baseOffset: 5,
              extentOffset: 2,
              isDirectional: true,
              affinity: TextAffinity.upstream),
          composing: const TextRange.collapsed(5));
      final repaired = repairChatColorEditingValue(previous, incoming);
      expect(rendered(repaired.text), 'לפחדשום אחרי');
      expect(repaired.selection.textInside(repaired.text), 'חדש');
      expect(repaired.selection.baseOffset > repaired.selection.extentOffset,
          isTrue);
      expect(repaired.selection.isDirectional, isTrue);
      expect(repaired.selection.affinity, TextAffinity.upstream);
      expect(repaired.composing.isCollapsed, isTrue);
      expect(repaired.composing.start, lessThanOrEqualTo(repaired.text.length));
    });

    test('multiline replacement balances surviving metadata around CRLF', () {
      final end = source.indexOf('שלום') + 2;
      final previous = selected(source, start: 2, end: end);
      final repaired = repairChatColorEditingValue(
          previous, incomingEdit(previous, 'חדש\r\nשני'));
      expect(rendered(repaired.text), 'לפחדש\r\nשניום אחרי');
      final suffix = parseChatFormattedText(repaired.text)
          .singleWhere((run) => run.text == 'ום');
      expect(suffix.foregroundRgb, 0x1976d2);
      expect(suffix.backgroundRgb, 0xfff59d);
      expect(
          parseChatFormattedText(repaired.text, preserveMarkers: true)
              .map((run) => run.text)
              .join(),
          repaired.text);
    });

    test('deletion across metadata retains emoji and combining graphemes', () {
      const text =
          'a [[bt-style:fg=1976D2]]שָׁ\u2066👩🏽‍💻\u2069ום[[/bt-style]] z';
      final end = text.indexOf('שָׁ') + 'שָׁ'.length;
      final previous = selected(text, start: 0, end: end);
      final repaired =
          repairChatColorEditingValue(previous, incomingEdit(previous, ''));
      expect(rendered(repaired.text), '\u2066👩🏽‍💻\u2069ום z');
      expect(repaired.text, contains('👩🏽‍💻'));
      expect(repaired.text, contains('\u2066'));
      expect(repaired.text, contains('\u2069'));
      expect(
          parseChatFormattedText(repaired.text).first.foregroundRgb, 0x1976d2);
    });

    test(
        'ordinary edits, mapped commands, whole-pair deletion and IME pass through',
        () {
      final previous = selected(source,
          start: source.indexOf('שלום'), end: source.indexOf('שלום') + 2);
      final ordinary = incomingEdit(previous, 'חדש');
      expect(
          identical(repairChatColorEditingValue(previous, ordinary), ordinary),
          isTrue);
      final bold = formatChatSelection(previous, ChatTextFormat.bold);
      expect(
          identical(repairChatColorEditingValue(previous, bold), bold), isTrue);
      final colored = colorChatSelection(
          previous, ChatTextColorTarget.foreground,
          rgb: 0xd32f2f);
      expect(identical(repairChatColorEditingValue(previous, colored), colored),
          isTrue);
      final whole = selected(source,
          start: source.indexOf('[[bt-style:'),
          end: source.indexOf('[[/bt-style]]') + '[[/bt-style]]'.length);
      final removed = incomingEdit(whole, '');
      expect(identical(repairChatColorEditingValue(whole, removed), removed),
          isTrue);
      final crossing =
          selected(source, start: 2, end: source.indexOf('שלום') + 2);
      final active = incomingEdit(crossing, 'חדש')
          .copyWith(composing: const TextRange(start: 2, end: 5));
      expect(identical(repairChatColorEditingValue(crossing, active), active),
          isTrue);
    });
  });

  group('line formatting', () {
    test('inline styling keeps list and quote prefixes outside their wrappers',
        () {
      for (final format in [
        ChatTextFormat.bulletList,
        ChatTextFormat.numberedList,
        ChatTextFormat.quote,
      ]) {
        final source = selected('שלום');
        final block = formatChatSelection(source, format);
        final wholeBlock = selected(block.text);
        final bold = formatChatSelection(wholeBlock, ChatTextFormat.bold);
        final prefix =
            block.text.substring(0, block.text.length - 'שלום'.length);
        expect(bold.text, '$prefix**שלום**');
        expect(rendered(bold.text), rendered(block.text));
        expect(formatChatSelection(bold, ChatTextFormat.bold).text, block.text);
        final boldFirst = formatChatSelection(source, ChatTextFormat.bold);
        final blockSecond = formatChatSelection(boldFirst, format);
        expect(blockSecond.text, bold.text);
      }
      final prefixOnly = selected('- שלום', start: 0, end: 2);
      expect(formatChatSelection(prefixOnly, ChatTextFormat.bold), prefixOnly);
    });

    test('partial selection affects complete lines and toggles back', () {
      final source = selected('לפני\nראשון\nשני\nאחרי', start: 6, end: 12);
      final result = formatChatSelection(source, ChatTextFormat.bulletList);
      expect(result.text, 'לפני\n- ראשון\n- שני\nאחרי');
      expect(formatChatSelection(result, ChatTextFormat.bulletList), source);
    });

    test('end at following line start does not format that unselected line',
        () {
      final source = selected('אחד\nשניים\nשלוש', start: 0, end: 10);
      final result = formatChatSelection(source, ChatTextFormat.quote);
      expect(result.text, '> אחד\n> שניים\nשלוש');
      expect(formatChatSelection(result, ChatTextFormat.quote), source);
    });

    test('numbering skips blank lines and retains indentation, CRLF and emoji',
        () {
      final source = selected('  ראשון\r\n\n\t😀 שני\nשלישי');
      final result = formatChatSelection(source, ChatTextFormat.numberedList);
      expect(result.text, '  1. ראשון\r\n\n\t2. 😀 שני\n3. שלישי');
      expect(formatChatSelection(result, ChatTextFormat.numberedList), source);
    });

    test('backward block selection keeps its direction through toggling', () {
      final source = selected('שלום\nעולם', start: 9, end: 1);
      final result = formatChatSelection(source, ChatTextFormat.quote);
      expect(result.text, '> שלום\n> עולם');
      expect(result.selection.baseOffset,
          greaterThan(result.selection.extentOffset));
      expect(formatChatSelection(result, ChatTextFormat.quote), source);
    });

    test(
        'collapsed caret formats its nonempty line without creating a blank item',
        () {
      final source = TextEditingValue(
          text: 'שלום\n\nעולם',
          selection: const TextSelection.collapsed(offset: 2));
      final result = formatChatSelection(source, ChatTextFormat.quote);
      expect(result.text, '> שלום\n\nעולם');
      expect(result.selection, const TextSelection.collapsed(offset: 4));
      expect(formatChatSelection(result, ChatTextFormat.quote), source);
      final blank =
          source.copyWith(selection: const TextSelection.collapsed(offset: 5));
      expect(formatChatSelection(blank, ChatTextFormat.bulletList), blank);
    });

    test('changing block style replaces existing prefixes without stacking',
        () {
      final source = selected('  - אחד\n> שני\n7. שלוש');
      final numbered = formatChatSelection(source, ChatTextFormat.numberedList);
      expect(numbered.text, '  1. אחד\n2. שני\n3. שלוש');
      final quoted = formatChatSelection(numbered, ChatTextFormat.quote);
      expect(quoted.text, '  > אחד\n> שני\n> שלוש');
      final plain = formatChatSelection(quoted, ChatTextFormat.quote);
      expect(plain.text, '  אחד\nשני\nשלוש');
    });
  });
}
