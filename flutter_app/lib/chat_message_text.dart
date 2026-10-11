/// Remove empty lines while preserving breaks and indentation in actual text.
String normalizeOutgoingMessageText(String text) => text
    .split(RegExp(r'\r\n?|\n'))
    .where((line) => line.trim().isNotEmpty)
    .join('\n')
    .trim();
