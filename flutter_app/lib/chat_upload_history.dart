/// Merge an upload's local progress with its owner-only server scan record.
/// Use request identity, never filenames: two simultaneous uploads may have
/// exactly the same name. Hidden media deliberately has no playable URL.
List<Map<String, dynamic>> mergeChatUploadHistory(
  List<Map<String, dynamic>> history,
  List<Map<String, dynamic>> local, {
  bool matchLegacyText = false,
}) {
  String? uploadKey(Map<String, dynamic> message) =>
      message['clientUploadId']?.toString();
  final activeKeys = local
      .where((message) => message['status'] == 'uploading')
      .map(uploadKey)
      .whereType<String>()
      .where((key) => key.isNotEmpty)
      .toSet();
  final merged = history
      .where((message) => message['isUploadBatchNotice'] != true &&
          !activeKeys.contains(uploadKey(message)))
      .toList();
  for (final message in local) {
    if (message['isUploadBatchNotice'] == true) continue;
    if (message['status'] == 'uploading') {
      merged.add(message);
      continue;
    }
    final key = uploadKey(message);
    final saved = history.any((entry) =>
        (key != null && key.isNotEmpty && uploadKey(entry) == key) ||
        (message['outboxId'] != null &&
            entry['clientMessageId'] == message['outboxId']) ||
        (message['fileUrl'] != null &&
            entry['fileUrl'] == message['fileUrl']) ||
        (matchLegacyText &&
            key == null &&
            message['outboxId'] == null &&
            message['fileUrl'] == null &&
            entry['text'] == message['text']));
    if (!saved) merged.add(message);
  }
  // Keep local queue boundaries around their files after a server refresh.
  // Notices have no server counterpart and must not be deduplicated by text.
  final notices = <dynamic, Map<String, dynamic>>{
    for (final notice in [...history, ...local]
        .where((m) => m['isUploadBatchNotice'] == true)) notice['id']: notice,
  };
  for (final notice in notices.values) {
    final time = DateTime.tryParse(notice['createdAt']?.toString() ?? '');
    final (uploadIds, messageIds) = _batchAnchors(notice, notices.values, merged);
    final lastFile = merged.lastIndexWhere((message) =>
        message['isUploadBatchNotice'] != true &&
        (uploadIds.contains(uploadKey(message)) ||
            messageIds.contains(message['id']?.toString())));
    final index = lastFile >= 0 ? lastFile + 1 : time == null
        ? -1
        : merged.indexWhere((message) {
            final other =
                DateTime.tryParse(message['createdAt']?.toString() ?? '');
            return other != null && other.isAfter(time);
          });
    merged.insert(index < 0 ? merged.length : index, notice);
  }
  return merged;
}

bool isPendingOwnUpload(Map<String, dynamic> message) =>
    message['id']?.toString().startsWith('scan_') == true &&
    message['status'] == 'pending_scan' &&
    message['contentPurged'] != true &&
    const [null, 'pending', 'pending_scan']
        .contains(message['moderationStatus']);

(Set<dynamic>, Set<dynamic>) _batchAnchors(
  Map<String, dynamic> notice,
  Iterable<Map<String, dynamic>> notices,
  List<Map<String, dynamic>> messages,
) {
  final time = DateTime.tryParse(notice['createdAt']?.toString() ?? '');
    final uploadIds = (notice['uploadIds'] as List? ?? []).toSet();
    final messageIds = (notice['messageIds'] as List? ?? []).toSet();
    // Older notices lack anchors. Recover only a complete, unambiguous batch
    // using the request IDs' device timestamp, never filenames/server clocks.
    if (uploadIds.isEmpty && messageIds.isEmpty && time != null) {
      final end = RegExp(r'^סוף העלאת (\d+) קבצים$')
          .firstMatch(notice['text']?.toString() ?? '');
      if (end != null) {
        DateTime? start;
        String? startText;
        for (final candidate in notices) {
          if (!(candidate['text']?.toString() ?? '').startsWith('מעלה ')) continue;
          final date = DateTime.tryParse(candidate['createdAt']?.toString() ?? '');
          if (date != null && !date.isAfter(time) &&
              (start == null || date.isAfter(start))) {
            start = date; startText = candidate['text']?.toString();
          }
        }
        if (start != null && startText == 'מעלה ${end.group(1)} קבצים') {
          final candidates = <String>{};
          for (final message in messages) {
            final key = message['clientUploadId']?.toString();
            if (key == null || !key.startsWith('uploading_')) continue;
            final match = RegExp(r'(\d{16})_\d+$').firstMatch(key);
            final micros = int.tryParse(match?.group(1) ?? '');
            if (micros != null && micros >= start.microsecondsSinceEpoch &&
                micros <= time.microsecondsSinceEpoch) {
              candidates.add(key);
            }
          }
          if (candidates.length == int.parse(end.group(1)!)) {
            uploadIds.addAll(candidates);
          }
        }
      }
    }

  return (uploadIds, messageIds);
}

/// Resolve a batch by stable request/message IDs, including complete legacy
/// batches. Names and neighbouring messages never establish membership.
List<Map<String, dynamic>> chatUploadBatchMembers(
    Map<String, dynamic> notice, List<Map<String, dynamic>> messages) {
  final (uploads, ids) = _batchAnchors(notice,
      messages.where((m) => m['isUploadBatchNotice'] == true), messages);
  final members = <String, Map<String, dynamic>>{};
  for (final message in messages) {
    if (message['isUploadBatchNotice'] == true) continue;
    final upload = message['clientUploadId']?.toString();
    final id = message['id']?.toString();
    if (!uploads.contains(upload) && !ids.contains(id)) continue;
    final key = upload?.isNotEmpty == true ? 'upload:$upload' : 'message:$id';
    members[key] = message;
  }
  return members.values.toList();
}
