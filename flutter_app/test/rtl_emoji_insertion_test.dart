import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:betshuva/inline_custom_emoji.dart';

void main() {
  testWidgets('first choice stays on right, new choices on left',
      (tester) async {
    for (final prefix in ['', 'שלום ']) {
      final c = InlineEmojiController(isolateEmojiRuns: true, text: prefix);
      c.selection = TextSelection.collapsed(offset: c.text.length);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
                  width: 340,
                  child: TextField(
                      controller: c,
                      textDirection: TextDirection.rtl,
                      textAlign: TextAlign.right)))));
      double? first;
      for (var id = 1; id <= 3; id++) {
        final index = c.selection.extentOffset;
        c.value = c.value.copyWith(
            text: c.text.replaceRange(index, index, inlineEmojiCharacter(id)),
            selection: TextSelection.collapsed(offset: index + 1));
        await tester.pump();
        final positions = [
          for (var n = 1; n <= id; n++)
            tester.getCenter(find.byKey(ValueKey('inline-custom-emoji-$n'))).dx
        ];
        first ??= positions.first;
        expect(positions.first, closeTo(first, 0.01));
        for (var n = 1; n < positions.length; n++)
          expect(positions[n - 1], greaterThan(positions[n]));
      }
      final editable = tester.state<EditableTextState>(find.byType(EditableText)).renderEditable;
      final lastChoice = tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-3'))).dx;
      expect(editable.getLocalRectForCaret(TextPosition(offset: c.selection.extentOffset)).left,
          lessThan(lastChoice));
      await tester.showKeyboard(find.byType(TextField));
      c.selection = TextSelection.collapsed(offset: c.text.length);
      await tester.pump();
      if (kIsWeb) {
        // DOM Backspace is delivered as an editing value, rather than a
        // synthetic Flutter key event that has no browser default action.
        final cursor = c.selection.extentOffset;
        tester.testTextInput.updateEditingValue(c.value.copyWith(
          text: c.text.replaceRange(cursor - 1, cursor, ''),
          selection: TextSelection.collapsed(offset: cursor - 1),
        ));
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      }
      await tester.pump();
      expect(encodeInlineEmojiText(c.text), '${prefix}[[bt-emoji:002]][[bt-emoji:001]]');
      // Ordinary Hebrew typed next continues on the left of the emoji run.
      final cursor = c.selection.extentOffset;
      c.value = c.value.copyWith(text: c.text.replaceRange(cursor, cursor, ' סוף'),
          selection: TextSelection.collapsed(offset: cursor + 4));
      await tester.pump();
      expect(tester.getCenter(find.byKey(const ValueKey('inline-custom-emoji-1'))).dx,
          closeTo(first!, 0.01));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    }
  });

  testWidgets('alternating artwork and Hebrew retain their editing positions', (tester) async {
    final c = InlineEmojiController(isolateEmojiRuns: true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 340,
      child: TextField(controller: c, textDirection: TextDirection.rtl, textAlign: TextAlign.right)))));
    for (final addition in [inlineEmojiCharacter(1), 'שלום', inlineEmojiCharacter(2), 'עולם',
        inlineEmojiCharacter(3), inlineEmojiCharacter(4)]) {
      final cursor=c.selection.extentOffset < 0 ? c.text.length : c.selection.extentOffset;
      c.value=c.value.copyWith(text:c.text.replaceRange(cursor,cursor,addition),
        selection:TextSelection.collapsed(offset:cursor+addition.length));
      await tester.pump();
    }
    expect(encodeInlineEmojiText(c.text),
      '[[bt-emoji:001]]שלום[[bt-emoji:002]]עולם[[bt-emoji:004]][[bt-emoji:003]]');
    final positions=[for(var id=1;id<=4;id++)
      tester.getCenter(find.byKey(ValueKey('inline-custom-emoji-$id'))).dx];
    expect(positions[0],greaterThan(positions[1]));
    expect(positions[1],greaterThan(positions[2]));
    expect(positions[2],greaterThan(positions[3]));
    await tester.pumpWidget(const SizedBox());c.dispose();
  });

  testWidgets('mixed artwork stays in insertion order across wrapped and explicit lines', (tester) async {
    for (final width in [90.0, 170.0, 340.0]) {
      for (final separator in [' שלום עולם ', '\nשלום\n']) {
        final c=InlineEmojiController(isolateEmojiRuns:true);
        await tester.pumpWidget(MaterialApp(home:Scaffold(body:SizedBox(width:width,
          child:TextField(controller:c,maxLines:null,textDirection:TextDirection.rtl,textAlign:TextAlign.right)))));
        for(final addition in [inlineEmojiCharacter(1),separator,inlineEmojiCharacter(2),separator,
          inlineEmojiCharacter(3),inlineEmojiCharacter(4),separator,inlineEmojiCharacter(5)]) {
          final at=c.selection.extentOffset < 0 ? c.text.length : c.selection.extentOffset;
          c.value=c.value.copyWith(text:c.text.replaceRange(at,at,addition),
            selection:TextSelection.collapsed(offset:at+addition.length));
          await tester.pump();
        }
        final positions=[for(var id=1;id<=5;id++)tester.getCenter(find.byKey(ValueKey('inline-custom-emoji-$id')))];
        for(var i=1;i<positions.length;i++) {
          final previous=positions[i-1],next=positions[i];
          expect(next.dy >= previous.dy - 1,true,reason:'width $width, emoji $i must not move to an earlier line');
          if((next.dy-previous.dy).abs()<1) expect(previous.dx,greaterThan(next.dx),
            reason:'width $width, emoji $i must stay to the right of the next choice');
        }
        await tester.pumpWidget(const SizedBox());c.dispose();
      }
    }
  });

  testWidgets('restored mixed drafts keep their order after resizing and caret edits', (tester) async {
    final original='[[bt-emoji:001]]שלום[[bt-emoji:002]]עולם[[bt-emoji:004]][[bt-emoji:003]]';
    final c=InlineEmojiController(isolateEmojiRuns:true,text:original);
    Future<void> show(double width) async {
      await tester.pumpWidget(MaterialApp(home:Scaffold(body:SizedBox(width:width,
        child:TextField(controller:c,maxLines:null,textDirection:TextDirection.rtl,textAlign:TextAlign.right)))));
      await tester.pumpAndSettle();
    }
    for(final width in [90.0,340.0,170.0,340.0]) {
      await show(width);
      final p=[for(var id=1;id<=4;id++)tester.getCenter(find.byKey(ValueKey('inline-custom-emoji-$id')))];
      for(var i=1;i<p.length;i++) {
        expect(p[i].dy >= p[i-1].dy-1,true);
        if((p[i].dy-p[i-1].dy).abs()<1)expect(p[i-1].dx,greaterThan(p[i].dx));
      }
      expect(encodeInlineEmojiText(c.text),original);
    }
    final cursor=c.text.indexOf('שלום')+2;
    c.value=c.value.copyWith(text:c.text.replaceRange(cursor,cursor,'חדש'),
      selection:TextSelection.collapsed(offset:cursor+3));
    await tester.pumpAndSettle();
    expect(c.selection.extentOffset,cursor+3);
    expect(encodeInlineEmojiText(c.text),original.replaceFirst('שלום','שלחדשום'));
    await tester.pumpWidget(const SizedBox());c.dispose();
  });

  testWidgets('keyboard emoji choices also progress to the left of Hebrew', (tester) async {
    final c = InlineEmojiController(isolateEmojiRuns: true, text: 'שלום ');
    c.selection = TextSelection.collapsed(offset: c.text.length);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TextField(
        controller: c, textDirection: TextDirection.rtl, textAlign: TextAlign.right))));
    for (final emoji in ['😀', '👍', '❤️']) {
      final cursor = c.selection.extentOffset;
      c.value = c.value.copyWith(text: c.text.replaceRange(cursor, cursor, emoji),
          selection: TextSelection.collapsed(offset: cursor + emoji.length));
      await tester.pump();
    }
    expect(encodeInlineEmojiText(c.text), 'שלום ❤️👍😀');
    final editable = tester.state<EditableTextState>(find.byType(EditableText)).renderEditable;
    final positions = [for (final emoji in ['😀', '👍', '❤️'])
      editable.getBoxesForSelection(TextSelection(baseOffset: c.text.indexOf(emoji),
          extentOffset: c.text.indexOf(emoji) + emoji.length)).single.left];
    expect(positions[0], greaterThan(positions[1]));
    expect(positions[1], greaterThan(positions[2]));
    // Extending a glyph with a skin tone must not detach the modifier.
    c.text = 'שלום 👍';
    c.selection = TextSelection.collapsed(offset: c.text.length);
    final cursor = c.selection.extentOffset;
    c.value = c.value.copyWith(text: c.text.replaceRange(cursor, cursor, '🏻'),
        selection: TextSelection.collapsed(offset: cursor + 2));
    expect(encodeInlineEmojiText(c.text), 'שלום 👍🏻');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
