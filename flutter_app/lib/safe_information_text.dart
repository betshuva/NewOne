import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Displays Safe Information answers without loading third-party content.
/// Opening a URL stays with the caller so the existing confirmation is retained.
class SafeInformationText extends StatefulWidget {
  const SafeInformationText(this.text,
      {super.key,
      required this.style,
      required this.onOpenUrl,
      this.presentation});

  final String text;
  final TextStyle style;
  final ValueChanged<String> onOpenUrl;
  final Map<String, dynamic>? presentation;

  @override
  State<SafeInformationText> createState() => _SafeInformationTextState();
}

class _SafeInformationTextState extends State<SafeInformationText> {
  final _links = <_InlineLink>[];
  final _recognizers = <TapGestureRecognizer>[];
  final _blocks = <_AnswerBlock>[];
  final _sources = <_AnswerSource>[];
  final _sourceByUrl = <String, _AnswerSource>{};
  final _occurrences = <int, int>{};
  String _presentationKey = '';
  bool _formatted = false;
  bool _showAllSources = false;

  @override
  void initState() {
    super.initState();
    _parseAnswer();
  }

  @override
  void didUpdateWidget(SafeInformationText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text ||
        _presentationKey != _fingerprint(widget.presentation)) {
      _disposeLinks();
      _showAllSources = false;
      _parseAnswer();
    }
  }

  TapGestureRecognizer _recognizer(String url) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => widget.onOpenUrl(url);
    _recognizers.add(recognizer);
    return recognizer;
  }

  void _parseAnswer() {
    _presentationKey = _fingerprint(widget.presentation);
    final presentation = widget.presentation;
    final hasPresentation =
        presentation?['version'] == 1 && presentation?['format'] == 'markdown';
    final entries = hasPresentation ? (presentation?['citations']) : null;
    final indices = <int>{};
    if (entries is List) {
      for (final entry in entries.take(50)) {
        if (entry is! Map) continue;
        final index = entry['index'], url = entry['url'];
        if (index is! int ||
            index < 1 ||
            index > 999 ||
            url is! String ||
            !_isHttpsUrl(url) ||
            _blockedSource(url) ||
            indices.contains(index) ||
            _sourceByUrl.containsKey(url)) {
          continue;
        }
        final title = entry['title'] is String
            ? (entry['title'] as String).replaceAll(RegExp(r'\s+'), ' ').trim()
            : '';
        final source = _AnswerSource(
            index, title.isEmpty ? Uri.parse(url).host : title, url);
        _sources.add(source);
        _sourceByUrl[url] = source;
        indices.add(index);
        if (_sources.length == 5) break;
      }
    }
    _formatted = hasPresentation || _looksFormatted(widget.text);
    if (!_formatted) {
      // Preserve the original, single selectable Text for historical messages.
      for (final match in _httpsUrl.allMatches(widget.text)) {
        final url = _trimUrl(match.group(0)!);
        if (_isHttpsUrl(url)) {
          _links.add(_InlineLink(
              match.start, match.start + url.length, url, _recognizer(url)));
        }
      }
      return;
    }
    final paragraph = <String>[];
    void flush() {
      if (paragraph.isNotEmpty) {
        _blocks.add(_AnswerBlock(_inline(paragraph.join('\n'))));
        paragraph.clear();
      }
    }

    var fenced = false;
    for (final line in widget.text.split('\n')) {
      if (line.trimLeft().startsWith('```')) {
        flush();
        fenced = !fenced;
        _blocks.add(_AnswerBlock([_AnswerPart.text(line)]));
      } else if (fenced) {
        flush();
        _blocks.add(_AnswerBlock([_AnswerPart.text(line)]));
      } else if (line.trim().isEmpty) {
        flush();
      } else {
        final heading = _heading.firstMatch(line);
        final list = _listLine.firstMatch(line);
        if (heading != null) {
          flush();
          _blocks.add(_AnswerBlock(_inline(heading.group(2)!),
              heading: heading.group(1)!.length));
        } else if (list != null) {
          flush();
          _blocks.add(_AnswerBlock(_inline(list.group(2)!),
              marker: RegExp(r'^\d').hasMatch(list.group(1)!)
                  ? list.group(1)!
                  : '•'));
        } else {
          paragraph.add(line);
        }
      }
    }
    flush();
  }

  List<_AnswerPart> _inline(String text, {bool bold = false}) {
    final parts = <_AnswerPart>[];
    var plain = '';
    void flush() {
      if (plain.isNotEmpty) {
        parts.add(_AnswerPart.text(plain, bold: bold));
        plain = '';
      }
    }

    var offset = 0;
    while (offset < text.length) {
      final literal = text.startsWith('![', offset)
          ? _imageMarkup.matchAsPrefix(text, offset)
          : text.startsWith('<', offset)
              ? _htmlMarkup.matchAsPrefix(text, offset)
              : null;
      if (literal != null) {
        plain += literal.group(0)!;
        offset = literal.end;
        continue;
      }
      if (text.startsWith('**', offset)) {
        final end = text.indexOf('**', offset + 2);
        if (end > offset + 2) {
          flush();
          parts.addAll(_inline(text.substring(offset + 2, end), bold: true));
          offset = end + 2;
          continue;
        }
      }
      final markdownLink = text.startsWith('[', offset)
          ? _markdownLink.matchAsPrefix(text, offset)
          : null;
      if (markdownLink != null && _isHttpsUrl(markdownLink.group(2)!)) {
        flush();
        final url = markdownLink.group(2)!;
        final source = _sourceByUrl[url];
        if (source == null) {
          parts.add(
              _AnswerPart.link(markdownLink.group(1)!, _recognizer(url), bold));
        } else {
          parts.add(_AnswerPart.text(markdownLink.group(1)!, bold: bold));
          parts.add(_citationPart(source));
        }
        offset = markdownLink.end;
        continue;
      }
      final match = _httpsUrl.matchAsPrefix(text, offset);
      if (match != null) {
        final url = _trimUrl(match.group(0)!);
        if (_isHttpsUrl(url)) {
          final source = _sourceByUrl[url];
          var end = offset + url.length;
          if (source != null &&
              plain.endsWith('(') &&
              end < text.length &&
              text[end] == ')') {
            plain = plain.substring(0, plain.length - 1);
            end++;
          }
          flush();
          parts.add(source == null
              ? _AnswerPart.link(url, _recognizer(url), bold)
              : _citationPart(source));
          offset = end;
          continue;
        }
      }
      plain += text[offset++];
    }
    flush();
    return parts;
  }

  _AnswerPart _citationPart(_AnswerSource source) {
    final occurrence = (_occurrences[source.index] ?? 0) + 1;
    _occurrences[source.index] = occurrence;
    return _AnswerPart.citation(source, occurrence);
  }

  void _disposeLinks() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    _links.clear();
    _blocks.clear();
    _sources.clear();
    _sourceByUrl.clear();
    _occurrences.clear();
  }

  @override
  void dispose() {
    _disposeLinks();
    super.dispose();
  }

  TextStyle _linkStyle(BuildContext context, TextStyle style) => style.copyWith(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline);

  Widget _legacy(BuildContext context) {
    final spans = <TextSpan>[];
    var offset = 0;
    for (final link in _links) {
      if (link.start > offset) {
        spans.add(TextSpan(text: widget.text.substring(offset, link.start)));
      }
      spans.add(TextSpan(
          text: link.url,
          style: _linkStyle(context, widget.style),
          recognizer: link.recognizer,
          mouseCursor: SystemMouseCursors.click));
      offset = link.end;
    }
    if (offset < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(offset)));
    }
    return SelectionArea(
        child: Text.rich(TextSpan(children: spans),
            style: widget.style,
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.right));
  }

  Widget _citation(BuildContext context, _AnswerPart part) {
    final source = part.source!,
        primary = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Tooltip(
        message: source.title,
        child: InkWell(
          key: ValueKey('ai-citation-${source.index}-${part.occurrence}'),
          onTap: () => widget.onOpenUrl(source.url),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(6)),
            child: Semantics(
              button: true,
              label: 'פתח מקור ${source.index}: ${source.title}',
              child: Text('[${source.index}]',
                  textDirection: TextDirection.ltr,
                  style: widget.style.copyWith(
                      color: primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _paragraph(BuildContext context, _AnswerBlock block) {
    final style = block.heading == 0
        ? widget.style
        : widget.style.copyWith(
            fontSize: (widget.style.fontSize ?? 14) + 8 - block.heading * 2,
            fontWeight: FontWeight.w700);
    final text = Text.rich(
        TextSpan(children: [
          for (final part in block.parts)
            if (part.source != null)
              WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: _citation(context, part))
            else
              TextSpan(
                  text: part.text,
                  style: part.recognizer != null
                      ? _linkStyle(context, style).copyWith(
                          fontWeight:
                              part.bold ? FontWeight.w700 : style.fontWeight)
                      : part.bold
                          ? style.copyWith(fontWeight: FontWeight.w700)
                          : null,
                  recognizer: part.recognizer,
                  mouseCursor: part.recognizer == null
                      ? null
                      : SystemMouseCursors.click),
        ]),
        style: style,
        textDirection: TextDirection.rtl,
        textAlign: TextAlign.right);
    if (block.marker != null) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(block.marker!, style: style, textDirection: TextDirection.ltr),
        const SizedBox(width: 9),
        Expanded(child: text),
      ]);
    }
    return Semantics(header: block.heading != 0, child: text);
  }

  Widget _answerBody(BuildContext context) => Column(
          key: const ValueKey('ai-answer-body'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < _blocks.length; i++) ...[
              if (i > 0) SizedBox(height: _blocks[i].marker != null ? 7 : 12),
              _paragraph(context, _blocks[i]),
            ],
          ]);

  Widget _sourceCard(BuildContext context, _AnswerSource source) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: ValueKey('ai-source-card-${source.index}'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => widget.onOpenUrl(source.url),
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(10)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.link, size: 19, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  Text(source.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style:
                          widget.style.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(Uri.parse(source.url).host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.right,
                      style: widget.style.copyWith(
                          fontSize: 12, color: theme.colorScheme.primary)),
                ])),
          ]),
        ),
      ),
    );
  }

  Widget _sourcePanel(BuildContext context) => Column(
          key: const ValueKey('ai-answer-sources'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('מקורות',
                textAlign: TextAlign.right,
                style: widget.style.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final source
                in _showAllSources ? _sources : _sources.take(3)) ...[
              _sourceCard(context, source),
              const SizedBox(height: 8),
            ],
            if (_sources.length > 3)
              TextButton(
                  key: const ValueKey('ai-sources-toggle'),
                  onPressed: () =>
                      setState(() => _showAllSources = !_showAllSources),
                  child: Text(_showAllSources ? 'פחות מקורות' : 'כל המקורות')),
          ]);

  @override
  Widget build(BuildContext context) {
    if (!_formatted) return _legacy(context);
    return SelectionArea(
        child: Directionality(
      textDirection: TextDirection.rtl,
      child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final body = _answerBody(context);
        if (_sources.isEmpty) return body;
        if (width >= 760) {
          return SizedBox(
              width: width,
              child: Row(
                textDirection: TextDirection.rtl,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: body),
                  const SizedBox(width: 22),
                  SizedBox(width: 238, child: _sourcePanel(context))
                ],
              ));
        }
        return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              body,
              const SizedBox(height: 18),
              _sourcePanel(context)
            ]);
      }),
    ));
  }
}

String _fingerprint(Map<String, dynamic>? presentation) {
  try {
    return jsonEncode(presentation);
  } catch (_) {
    return presentation.toString();
  }
}

bool _isHttpsUrl(String value) {
  if (value != value.trim() || RegExp(r'[\s\u0000-\u001f]').hasMatch(value)) {
    return false;
  }
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

bool _blockedSource(String value) {
  final host = Uri.parse(value).host.toLowerCase();
  return _blockedSourceDomains
      .any((domain) => host == domain || host.endsWith('.$domain'));
}

bool _looksFormatted(String text) =>
    text
        .split('\n')
        .any((line) => _heading.hasMatch(line) || _listLine.hasMatch(line)) ||
    RegExp(r'\*\*[^\n]+?\*\*').hasMatch(text) ||
    _markdownLink.hasMatch(text);

String _trimUrl(String value) {
  var url = value.replaceFirst(_trailingPunctuation, '');
  while (url.endsWith(')') &&
      ')'.allMatches(url).length > '('.allMatches(url).length) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

final _httpsUrl =
    RegExp(r'''https://[^\s<>"\u200e\u200f]+''', caseSensitive: false);
final _trailingPunctuation = RegExp(r'''[.,;:!?…。，؛،״׳'”’\]}]+$''');
final _heading = RegExp(r'^\s{0,3}(#{1,3})\s+(.+?)\s*$');
final _listLine = RegExp(r'^\s*([-*+]|\d+[.)])\s+(.+)$');
final _markdownLink = RegExp(r'\[([^\]\n]+)\]\(([^)\n]+)\)');
final _imageMarkup = RegExp(r'!\[[^\]\n]*\]\([^\n]*?\)');
final _htmlMarkup = RegExp(r'<[^>\n]*>');
const _blockedSourceDomains = [
  'facebook.com',
  'instagram.com',
  'tiktok.com',
  'twitter.com',
  'x.com',
  'reddit.com',
  'youtube.com',
  'youtu.be',
  't.me',
  'telegram.org'
];

class _AnswerSource {
  const _AnswerSource(this.index, this.title, this.url);
  final int index;
  final String title;
  final String url;
}

class _AnswerBlock {
  const _AnswerBlock(this.parts, {this.heading = 0, this.marker});
  final List<_AnswerPart> parts;
  final int heading;
  final String? marker;
}

class _AnswerPart {
  const _AnswerPart.text(this.text, {this.bold = false})
      : source = null,
        occurrence = null,
        recognizer = null;
  const _AnswerPart.link(this.text, this.recognizer, this.bold)
      : source = null,
        occurrence = null;
  const _AnswerPart.citation(this.source, this.occurrence)
      : text = '',
        bold = false,
        recognizer = null;
  final String text;
  final bool bold;
  final _AnswerSource? source;
  final int? occurrence;
  final TapGestureRecognizer? recognizer;
}

class _InlineLink {
  const _InlineLink(this.start, this.end, this.url, this.recognizer);
  final int start;
  final int end;
  final String url;
  final TapGestureRecognizer recognizer;
}
