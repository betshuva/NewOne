import 'package:betshuva/ai_answer_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = 'https://www.gov.il/first?q=%D7%A9%D7%9C%D7%95%D7%9D#details';
const _second = 'https://www.boi.org.il/second';
Map<String, dynamic> _source(int index, String url,
        [dynamic title = 'מידע רשמי']) =>
    {'index': index, 'title': title, 'url': url};
Map<String, dynamic> _presentation(List<dynamic> sources) => {
      'version': 1,
      'format': 'markdown',
      'citations': sources,
      'references': [
        {'index': 1, 'start': -100, 'end': 999999}
      ],
    };
Map<String, dynamic>? _normalize(Map<String, dynamic> presentation) =>
    normalizeAiAnswerPresentation(
        {'aiPresentation': presentation}, safeInformationAssistantId);

void main() {
  test('presentation requires the actual information assistant sender', () {
    final message = {
      'from': safeInformationAssistantId,
      'sender_id': safeInformationAssistantId,
      'aiPresentation': _presentation([_source(1, _first)]),
    };
    for (final sender in <String?>[
      null,
      '',
      'ordinary-user',
      '00000000-0000-4000-8000-000000000002',
      ' $safeInformationAssistantId',
    ]) {
      expect(normalizeAiAnswerPresentation(message, sender), isNull);
    }
    expect(normalizeAiAnswerPresentation(message, safeInformationAssistantId),
        isNotNull);
    expect(normalizeAiAnswerPresentation(null, safeInformationAssistantId),
        isNull);
    expect(
        normalizeAiAnswerPresentation([], safeInformationAssistantId), isNull);
    expect(normalizeAiAnswerPresentation('text', safeInformationAssistantId),
        isNull);
  });

  test('history, live and delivery-summary aliases yield the same contract',
      () {
    final value = _presentation([_source(1, _first)]);
    final messages = [
      {'aiPresentation': value},
      {'ai_presentation': value},
      {
        'delivery_summary': {'aiPresentation': value}
      },
      {
        'deliverySummary': {'aiPresentation': value}
      },
    ];
    for (final message in messages) {
      expect(
          normalizeAiAnswerPresentation(message, safeInformationAssistantId), {
        'version': 1,
        'format': 'markdown',
        'citations': [_source(1, _first)],
        'references': [],
      });
    }
  });

  test('only supported format, version and citation list are carried', () {
    final base = _presentation([_source(1, _first)]);
    for (final value in [
      {...base, 'version': 2},
      {...base, 'version': '1'},
      {...base, 'format': 'html'},
      {...base, 'format': null},
      {...base, 'citations': 'sources'},
      {...base, 'citations': {}},
      {...base, 'citations': null},
    ]) {
      expect(_normalize(value), isNull);
    }
    expect(
        normalizeAiAnswerPresentation(
            {'aiPresentation': 'text'}, safeInformationAssistantId),
        isNull);
  });

  test('explicit malformed presentation does not borrow a nested presentation',
      () {
    expect(
        normalizeAiAnswerPresentation({
          'aiPresentation': {'version': 2},
          'delivery_summary': {
            'aiPresentation': _presentation([_source(1, _first)])
          },
        }, safeInformationAssistantId),
        isNull);
  });

  test('invalid URL schemes, hosts, credentials and whitespace are discarded',
      () {
    for (final url in [
      'http://example.org/page',
      'javascript:alert(1)',
      'data:text/plain,hello',
      '//example.org/page',
      'https:///invalid',
      'https://user:secret@example.org/private',
      'https://user%3Asecret@example.org/private',
      'https://example.org/has space',
      'https://example.org/line\nbreak',
      'https://example.org/\u202eevil',
      ' https://example.org/page',
      'https://example.org/page ',
    ]) {
      expect(_normalize(_presentation([_source(1, url)])), isNull, reason: url);
    }
    expect(
        _normalize(_presentation([
          _source(1, 'https://example.org/has%20space'),
        ]))!['citations'],
        [_source(1, 'https://example.org/has%20space')]);
  });

  test('accepted URL is preserved exactly including query and fragment', () {
    final actual = _normalize(_presentation([_source(1, _first)]))!;
    expect((actual['citations'] as List).single['url'], _first);
  });

  test('URL and index duplicates preserve the first eligible citation', () {
    final actual = _normalize(_presentation([
      _source(1, _first, 'ראשון'),
      _source(2, _first, 'URL כפול'),
      _source(1, _second, 'index כפול'),
      _source(3, _second, 'שני'),
    ]))!;
    expect(actual['citations'], [
      _source(1, _first, 'ראשון'),
      _source(3, _second, 'שני'),
    ]);
  });

  test('bad records neither reserve an index nor a URL', () {
    final actual = _normalize(_presentation([
      'not a citation',
      null,
      {'index': '1', 'url': _first},
      {'index': 1.0, 'url': _first},
      {'index': 1, 'url': 42},
      _source(1, 'http://example.org'),
      _source(0, _first),
      _source(-1, _first),
      _source(6, _first),
      _source(1, _first),
    ]))!;
    expect(actual['citations'], [_source(1, _first)]);
  });

  test('at most five valid numbered sources are retained', () {
    final actual = _normalize(_presentation([
      for (var index = 1; index <= 20; index++)
        _source(index, 'https://example.org/$index'),
    ]))!;
    expect(actual['citations'], [
      for (var index = 1; index <= 5; index++)
        _source(index, 'https://example.org/$index'),
    ]);
  });

  test('titles discard control and directional override characters', () {
    final actual = _normalize(_presentation([
      _source(1, _first, '  משרד\n ממשלתי\u0000 \u202eקישור\u2069  '),
    ]))!;
    expect((actual['citations'] as List).single['title'], 'משרד ממשלתי קישור');
  });

  test(
      'missing or blank titles use the actual URL host and long titles are bound',
      () {
    final longTitle = List.filled(200, 'א').join();
    final actual = _normalize(_presentation([
      _source(1, _first, null),
      _source(2, _second, '\n\u0000 '),
      _source(3, 'https://example.org/3', 17),
      _source(4, 'https://example.org/4', longTitle),
    ]))!;
    final citations = actual['citations'] as List;
    expect(citations[0]['title'], 'www.gov.il');
    expect(citations[1]['title'], 'www.boi.org.il');
    expect(citations[2]['title'], 'example.org');
    expect(citations[3]['title'], List.filled(160, 'א').join());
  });

  test(
      'normalization copies citations and ignores raw offsets without mutation',
      () {
    final citation = _source(1, _first, '  משרד ממשלתי  ');
    final presentation = _presentation([citation]);
    final actual = _normalize(presentation)!;
    expect(actual['references'], isEmpty);
    expect((presentation['references'] as List).single['start'], -100);
    expect(citation['title'], '  משרד ממשלתי  ');
    (actual['citations'] as List).single['title'] = 'changed locally';
    expect(citation['title'], '  משרד ממשלתי  ');
  });

  test('an empty or completely rejected citation list has no presentation', () {
    expect(_normalize(_presentation([])), isNull);
    expect(_normalize(_presentation([null, _source(0, _first)])), isNull);
    expect(
        normalizeAiAnswerPresentation(
            {'delivery_summary': 'not a map'}, safeInformationAssistantId),
        isNull);
  });
}
