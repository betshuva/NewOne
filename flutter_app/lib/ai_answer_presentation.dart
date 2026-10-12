const safeInformationAssistantId = '00000000-0000-4000-8000-000000000003';

/// Carries server supplied citations only for the actual information assistant.
/// Both history and live messages use the same normalized presentation shape.
Map<String, dynamic>? normalizeAiAnswerPresentation(
    dynamic message, String? senderId) {
  if (senderId != safeInformationAssistantId || message is! Map) return null;
  final summary = message['delivery_summary'] ?? message['deliverySummary'];
  final value = message['aiPresentation'] ??
      message['ai_presentation'] ??
      (summary is Map ? summary['aiPresentation'] : null);
  if (value is! Map || value['version'] != 1 || value['format'] != 'markdown') {
    return null;
  }
  final rawCitations = value['citations'];
  if (rawCitations is! List) return null;
  final citations = <Map<String, dynamic>>[];
  final indexes = <int>{};
  final urls = <String>{};
  for (final raw in rawCitations) {
    if (raw is! Map || raw['index'] is! int || raw['url'] is! String) continue;
    final index = raw['index'] as int;
    final url = raw['url'] as String;
    final uri = Uri.tryParse(url);
    if (index < 1 ||
        index > 5 ||
        url != url.trim() ||
        RegExp(r'[\s\x00-\x1f\x7f\u200e\u200f\u202a-\u202e\u2066-\u2069]')
            .hasMatch(url) ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        indexes.contains(index) ||
        urls.contains(url)) {
      continue;
    }
    final title = (raw['title'] is String ? raw['title'] as String : uri.host)
        .replaceAll(RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    indexes.add(index);
    urls.add(url);
    citations.add({
      'index': index,
      'title': title.isEmpty
          ? uri.host
          : title.substring(0, title.length > 160 ? 160 : title.length),
      'url': url,
    });
    if (citations.length == 5) break;
  }
  if (citations.isEmpty) return null;
  return {
    'version': 1,
    'format': 'markdown',
    'citations': citations,
    // The displayed body may omit internal application links. The renderer
    // matches citation URLs rather than trusting offsets from the raw body.
    'references': const <Map<String, dynamic>>[],
  };
}
