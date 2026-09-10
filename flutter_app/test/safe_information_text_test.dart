import 'package:betshuva/safe_information_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _style = TextStyle(fontSize: 14, height: 1.45, color: Colors.black);

Widget _app(String text, ValueChanged<String> onOpenUrl) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 480,
          child: SafeInformationText(text, style: _style, onOpenUrl: onOpenUrl),
        ),
      ),
    );

List<TextSpan> _spans(WidgetTester tester) =>
    (tester.widget<Text>(find.byType(Text)).textSpan! as TextSpan)
        .children!
        .cast<TextSpan>();

Future<void> _tapLink(WidgetTester tester, String text, String url) async {
  final paragraph = tester.renderObject<RenderParagraph>(find.byType(RichText));
  final start = text.indexOf(url);
  final box = paragraph
      .getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: start + 5))
      .first;
  await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
  await tester.pump();
}

void main() {
  testWidgets(
      'HTTPS citations open their own URL through the provided callback',
      (tester) async {
    const first = 'https://example.org/news';
    const second = 'https://example.org/details?q=he';
    const message = 'פרט ראשון ($first).\nפרט נוסף: $second.';
    final opened = <String>[];
    await tester.pumpWidget(_app(message, opened.add));

    expect(find.text(message), findsOneWidget);
    expect(
        _spans(tester)
            .where((span) => span.recognizer != null)
            .map((span) => span.text),
        [first, second]);
    expect(opened, isEmpty);
    await _tapLink(tester, message, second);
    expect(opened, [second]);
    await _tapLink(tester, message, first);
    expect(opened, [second, first]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary and listing text is preserved without invented sources',
      (tester) async {
    for (final message in [
      'מידע כללי בעברית.\nאפשר להמשיך לשאול.',
      'מצאתי שתי מודעות פעילות.\nשולחן למסירה בחיפה.\nלפרטים פתח את המודעה.',
      'javascript:alert(1) http://example.org https:///invalid',
    ]) {
      await tester.pumpWidget(_app(message, (_) => fail('Unexpected link')));
      final text = tester.widget<Text>(find.text(message));
      expect(text.style, _style);
      expect(text.textDirection, TextDirection.rtl);
      expect(text.textAlign, TextAlign.right);
      expect(_spans(tester).every((span) => span.recognizer == null), isTrue);
      expect(find.textContaining('מקור'), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('answer and callback updates use the current link and callback',
      (tester) async {
    const first = 'https://example.org/first';
    const second = 'https://example.org/second';
    final originalCalls = <String>[];
    final currentCalls = <String>[];
    await tester.pumpWidget(_app(first, originalCalls.add));
    await tester.pumpWidget(_app(first, currentCalls.add));
    await _tapLink(tester, first, first);
    expect(originalCalls, isEmpty);
    expect(currentCalls, [first]);

    await tester.pumpWidget(_app(second, currentCalls.add));
    await _tapLink(tester, second, second);
    expect(currentCalls, [first, second]);
    expect(
        _spans(tester).where((span) => span.recognizer != null), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
