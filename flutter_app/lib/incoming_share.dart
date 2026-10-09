import 'calendar_shared_link.dart';

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

bool isSharedCalendarFile(Map file) {
  final name =
      (file['name'] ?? file['fileName'] ?? '').toString().toLowerCase();
  final mime = (file['mime'] ?? file['mimeType'] ?? '')
      .toString()
      .toLowerCase()
      .split(';')
      .first;
  return name.endsWith('.ics') ||
      mime == 'text/calendar' ||
      mime == 'application/ics';
}

bool isSharedContactFile(Map file) {
  final name =
      (file['name'] ?? file['fileName'] ?? '').toString().toLowerCase();
  final mime = (file['mime'] ?? file['mimeType'] ?? '')
      .toString()
      .toLowerCase()
      .split(';')
      .first;
  return name.endsWith('.vcf') ||
      mime == 'text/vcard' ||
      mime == 'text/x-vcard';
}

bool incomingShareHasCalendar(Map<String, dynamic> share) =>
    share['calendar'] is Map ||
    parseSharedCalendarLink(share['text']?.toString() ?? '') != null ||
    (share['text']
            ?.toString()
            .trimLeft()
            .toUpperCase()
            .startsWith('BEGIN:VCALENDAR') ??
        false) ||
    (share['files'] is List &&
        (share['files'] as List).whereType<Map>().any(isSharedCalendarFile));

/// Only images can seed a listing; the listing scanner must approve them again.
bool incomingShareCanCreateListing(Map<String, dynamic> share) {
  final files = (share['files'] as List? ?? const []).whereType<Map>().toList();
  return files.isNotEmpty &&
      files.length <= 8 &&
      files.every((file) =>
          (file['mime']?.toString() ?? '').startsWith('image/') &&
          (file['path']?.toString().isNotEmpty ?? false));
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
