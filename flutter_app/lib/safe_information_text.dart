import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Makes HTTPS citations in Safe Information answers individually actionable.
/// Opening a URL stays with the caller so the existing confirmation is retained.
class SafeInformationText extends StatefulWidget {
  const SafeInformationText(
    this.text, {
    super.key,
    required this.style,
    required this.onOpenUrl,
  });

  final String text;
  final TextStyle style;
  final ValueChanged<String> onOpenUrl;

  @override
  State<SafeInformationText> createState() => _SafeInformationTextState();
}

class _SafeInformationTextState extends State<SafeInformationText> {
  final _links = <_InlineLink>[];

  @override
  void initState() {
    super.initState();
    _parseLinks();
  }

  @override
  void didUpdateWidget(SafeInformationText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) {
      _disposeLinks();
      _parseLinks();
    }
  }

  void _parseLinks() {
    for (final match in _httpsUrl.allMatches(widget.text)) {
      var url = match.group(0)!.replaceFirst(_trailingPunctuation, '');
      while (url.endsWith(')') &&
          ')'.allMatches(url).length > '('.allMatches(url).length) {
        url = url.substring(0, url.length - 1);
      }
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        continue;
      }
      _links.add(_InlineLink(
        match.start,
        match.start + url.length,
        url,
        TapGestureRecognizer()..onTap = () => widget.onOpenUrl(url),
      ));
    }
  }

  void _disposeLinks() {
    for (final link in _links) {
      link.recognizer.dispose();
    }
    _links.clear();
  }

  @override
  void dispose() {
    _disposeLinks();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    var offset = 0;
    final linkStyle = widget.style.copyWith(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    for (final link in _links) {
      if (link.start > offset) {
        spans.add(TextSpan(text: widget.text.substring(offset, link.start)));
      }
      spans.add(TextSpan(
        text: link.url,
        style: linkStyle,
        recognizer: link.recognizer,
        mouseCursor: SystemMouseCursors.click,
      ));
      offset = link.end;
    }
    if (offset < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(offset)));
    }
    return SelectionArea(
      child: Text.rich(
        TextSpan(children: spans),
        style: widget.style,
        textDirection: TextDirection.rtl,
        textAlign: TextAlign.right,
      ),
    );
  }
}

final _httpsUrl =
    RegExp(r'''https://[^\s<>"\u200e\u200f]+''', caseSensitive: false);
final _trailingPunctuation = RegExp(r'''[.,;:!?…。，؛،״׳'”’\]}]+$''');

class _InlineLink {
  const _InlineLink(this.start, this.end, this.url, this.recognizer);

  final int start;
  final int end;
  final String url;
  final TapGestureRecognizer recognizer;
}
