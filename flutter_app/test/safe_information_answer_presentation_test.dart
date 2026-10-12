import 'package:betshuva/safe_information_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _style = TextStyle(fontSize: 14, height: 1.45, color: Colors.black);
const _first = 'https://www.gov.il/first';
const _second = 'https://www.boi.org.il/second';

Map<String, dynamic> _presentation(List<Map<String, dynamic>> citations) => {
      'version': 1,
      'format': 'markdown',
      'citations': citations,
      'references': [],
    };
Map<String, dynamic> _source(int index, String url, [String? title]) => {
      'index': index,
      'url': url,
      'title': title ?? 'מקור $index בעברית',
    };

Widget _app(String text,
        {Map<String, dynamic>? presentation,
        ValueChanged<String>? onOpenUrl,
        double width = 480,
        double scale = 1}) =>
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: width,
                child: SafeInformationText(text,
                    style: _style,
                    presentation: presentation,
                    onOpenUrl: onOpenUrl ?? (_) {}),
              ),
            ),
          ),
        ),
      ),
    );

Finder get _body => find.byKey(const ValueKey('ai-answer-body'));
Finder get _sources => find.byKey(const ValueKey('ai-answer-sources'));
Finder _card(int index) => find.byKey(ValueKey('ai-source-card-$index'));
Finder _chip(int index, int occurrence) =>
    find.byKey(ValueKey('ai-citation-$index-$occurrence'));
Iterable<TextSpan> _textSpans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _textSpans(child);
    }
  }
}

Future<void> _tapUrl(WidgetTester tester, String url) async {
  final paragraphs =
      find.descendant(of: _body, matching: find.byType(RichText));
  for (final element in paragraphs.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    final plain = paragraph.text.toPlainText();
    final start = plain.indexOf(url);
    if (start < 0) continue;
    final box = paragraph
        .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 5))
        .first;
    await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
    await tester.pump();
    return;
  }
  fail('URL was not rendered: $url');
}

void main() {
  testWidgets('headings, bold, paragraphs and lists are selectable RTL text',
      (tester) async {
    await tester.pumpWidget(_app(
        '## תשובה ברורה\n\nהסבר עם **פרט חשוב**.\n\n- אפשרות ראשונה\n- אפשרות שנייה\n\n1. שלב ראשון\n2. שלב שני'));
    expect(_body, findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.text('תשובה ברורה'), findsOneWidget);
    expect(find.text('אפשרות ראשונה'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('•'), findsNWidgets(2));
    final heading = tester.widget<Text>(find.text('תשובה ברורה'));
    expect(heading.style!.fontSize, greaterThan(_style.fontSize!));
    expect(heading.style!.fontWeight, FontWeight.w700);
    final paragraph = tester.widget<Text>(find.text('הסבר עם פרט חשוב.'));
    expect(paragraph.textDirection, TextDirection.rtl);
    expect(paragraph.textAlign, TextAlign.right);
    final bold = _textSpans(paragraph.textSpan!)
        .singleWhere((span) => span.text == 'פרט חשוב');
    expect(bold.style!.fontWeight, FontWeight.w700);
    expect(_sources, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide answer is right of the source panel within its own width',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app('## מידע\nפרט ראשון ($_first).',
        width: 900, presentation: _presentation([_source(1, _first)])));
    final body = tester.getRect(_body), sources = tester.getRect(_sources);
    expect(sources.right, lessThan(body.left));
    expect(body.top, sources.top);
    expect(body.right, lessThanOrEqualTo(1200));
    expect(_chip(1, 1), findsOneWidget);
    expect(find.textContaining(_first), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px at 1.4 text scale puts sources below without overflow',
      (tester) async {
    await tester.pumpWidget(_app(
        '## מידע שימושי\n\nתשובה בעברית עם **פרטים חשובים**.\n- כדאי לבדוק את התנאים ואת שעות הפעילות ($_first).\n1. פותחים את המידע הרלוונטי.',
        width: 320,
        scale: 1.4,
        presentation: _presentation([
          _source(1, _first, 'מקור עם כותרת ארוכה המתארת את פרטי השירות בעברית')
        ])));
    final body = tester.getRect(_body), sources = tester.getRect(_sources);
    expect(sources.top, greaterThanOrEqualTo(body.bottom));
    expect(sources.width, lessThanOrEqualTo(320));
    expect(tester.getRect(_card(1)).width, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
  });

  testWidgets('each citation occurrence and card opens its exact source',
      (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_app(
        'מידע ראשון ($_first).\n\nפרט נוסף: $_second.\n\nשוב $_first',
        presentation: _presentation([_source(1, _first), _source(2, _second)]),
        onOpenUrl: opened.add));
    await tester.tap(_chip(2, 1));
    await tester.tap(_chip(1, 2));
    await tester.tap(_card(2));
    await tester.tap(_card(1));
    expect(opened, [_second, _first, _second, _first]);
    expect(find.text('www.gov.il'), findsOneWidget);
    expect(find.text('www.boi.org.il'), findsOneWidget);
    expect(find.textContaining('מאומת'), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate source URLs share one card and citation index',
      (tester) async {
    await tester.pumpWidget(_app('$_first\n\n$_first',
        presentation: _presentation([
          _source(1, _first, 'הראשון'),
          _source(2, _first, 'כפול'),
          _source(3, _second, 'השני'),
        ])));
    expect(_card(1), findsOneWidget);
    expect(_card(2), findsNothing);
    expect(_card(3), findsOneWidget);
    expect(_chip(1, 1), findsOneWidget);
    expect(_chip(1, 2), findsOneWidget);
    expect(find.text('כפול'), findsNothing);
  });

  testWidgets('five sources initially show three and expand on request',
      (tester) async {
    await tester.pumpWidget(_app('תשובה קצרה',
        presentation: _presentation([
          for (var i = 1; i <= 5; i++)
            _source(i, 'https://example.org/source-$i'),
        ])));
    expect(_card(1), findsOneWidget);
    expect(_card(3), findsOneWidget);
    expect(_card(4), findsNothing);
    await tester.tap(find.text('כל המקורות'));
    await tester.pump();
    expect(_card(4), findsOneWidget);
    expect(_card(5), findsOneWidget);
    await tester.ensureVisible(find.text('פחות מקורות'));
    await tester.tap(find.text('פחות מקורות'));
    await tester.pump();
    expect(_card(4), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsafe or malformed metadata never creates a source card',
      (tester) async {
    await tester.pumpWidget(_app('## מידע\nאין כאן מקור לשייך.',
        presentation: _presentation([
          _source(1, 'http://example.org'),
          _source(2, 'javascript:alert(1)'),
          _source(3, 'https://user:secret@example.org/private'),
          _source(4, 'https:///invalid'),
          _source(5, 'https://example.org/has space'),
          _source(6, 'https://www.facebook.com/post'),
          {'index': '7', 'url': _first, 'title': 'index must be integer'},
        ])));
    expect(_sources, findsNothing);
    expect(_chip(1, 1), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary links do not become sources even in formatted answers',
      (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_app('## פרטים\nאפשר לקרוא כאן: $_first.',
        presentation: _presentation([]), onOpenUrl: opened.add));
    expect(_sources, findsNothing);
    expect(_chip(1, 1), findsNothing);
    await _tapUrl(tester, _first);
    expect(opened, [_first]);
  });

  testWidgets('Markdown link labels use the existing URL callback',
      (tester) async {
    final opened = <String>[];
    const label = 'מידע רשמי';
    await tester.pumpWidget(_app('[$label]($_first)', onOpenUrl: opened.add));
    expect(_sources, findsNothing);
    expect(find.text(label), findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: _body, matching: find.byType(RichText)).first);
    final box = paragraph
        .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 4))
        .first;
    await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
    expect(opened, [_first]);
  });

  testWidgets('untrusted HTML, image notation and fenced URLs stay literal',
      (tester) async {
    const markup = '<img src="https://example.org/image.png">\n'
        '<script>alert(1)</script>\n'
        '![תמונה](https://example.org/image.png)\n\n'
        '```\nhttps://example.org/code\n```';
    await tester.pumpWidget(_app(markup, presentation: _presentation([])));
    expect(find.byType(Image), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    final texts = tester.widgetList<Text>(find.byType(Text));
    expect(
        texts.any((text) =>
            text.textSpan
                ?.toPlainText()
                .contains('<script>alert(1)</script>') ==
            true),
        isTrue);
    expect(
        texts
            .expand((text) => text.textSpan == null
                ? <TextSpan>[]
                : _textSpans(text.textSpan!))
            .every((span) => span.recognizer == null),
        isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('updated callbacks and metadata are used by chips and cards',
      (tester) async {
    final oldCalls = <String>[], currentCalls = <String>[];
    final data = _presentation([_source(1, _first)]);
    await tester
        .pumpWidget(_app(_first, presentation: data, onOpenUrl: oldCalls.add));
    await tester.pumpWidget(
        _app(_first, presentation: data, onOpenUrl: currentCalls.add));
    await tester.tap(_chip(1, 1));
    expect(oldCalls, isEmpty);
    expect(currentCalls, [_first]);
    data['citations'] = [_source(2, _second, 'המקור המעודכן')];
    await tester.pumpWidget(
        _app(_second, presentation: data, onOpenUrl: currentCalls.add));
    expect(_card(1), findsNothing);
    expect(_card(2), findsOneWidget);
    await tester.tap(_chip(2, 1));
    await tester.tap(_card(2));
    expect(currentCalls, [_first, _second, _second]);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('regular link recognizers update and dispose with the answer',
      (tester) async {
    final oldCalls = <String>[], currentCalls = <String>[];
    await tester.pumpWidget(_app('## קישור\n$_first', onOpenUrl: oldCalls.add));
    await tester
        .pumpWidget(_app('## קישור\n$_first', onOpenUrl: currentCalls.add));
    await _tapUrl(tester, _first);
    expect(oldCalls, isEmpty);
    expect(currentCalls, [_first]);
    await tester
        .pumpWidget(_app('## קישור\n$_second', onOpenUrl: currentCalls.add));
    await _tapUrl(tester, _second);
    expect(currentCalls, [_first, _second]);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('malformed bold markup remains visible rather than dropping text',
      (tester) async {
    await tester.pumpWidget(
        _app('## פרטים\nזה **טקסט שלא נסגר', presentation: _presentation([])));
    expect(find.text('זה **טקסט שלא נסגר'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown presentation version does not invent source metadata',
      (tester) async {
    final data = _presentation([_source(1, _first)])..['version'] = 2;
    await tester.pumpWidget(_app(_first, presentation: data));
    expect(_sources, findsNothing);
    expect(_body, findsNothing);
    expect(find.byType(Text), findsOneWidget);
  });
}
