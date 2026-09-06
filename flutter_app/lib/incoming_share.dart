/// Translate Android's per-file metadata without assuming every share is an image.
List<Map<String, dynamic>> incomingShareMessages(Map<String, dynamic> share) {
  final messages = <Map<String, dynamic>>[];
  final text = share['text']?.toString().trim() ?? '';
  if (text.isNotEmpty) messages.add({'text': text});
  final files = share['files'];
  if (files is List) {
    for (final file in files.whereType<Map>()) {
      final path = file['path']?.toString() ?? '';
      if (path.isEmpty) continue;
      final mime = file['mime']?.toString() ?? 'application/octet-stream';
      messages.add({
        'localPath': path,
        'fileName': file['name']?.toString() ?? 'shared_file',
        'mimeType': mime,
        'fileType': mime.startsWith('image/')
            ? 'image'
            : mime.startsWith('video/')
                ? 'video'
                : mime.startsWith('audio/')
                    ? 'audio'
                    : 'document',
      });
    }
  }
  return messages;
}

String? incomingShareRecipient(Object? shortcutId, String? accountId) {
  if (shortcutId is! String || accountId == null || accountId.isEmpty) {
    return null;
  }
  final prefix = '$accountId:';
  if (!shortcutId.startsWith(prefix)) return null;
  final recipient = shortcutId.substring(prefix.length);
  return recipient.isEmpty ? null : recipient;
}
