String? _uploadKey(Map<String, dynamic> message) {
  final key = message['clientUploadId']?.toString();
  return key == null || key.isEmpty ? null : key;
}

/// Prefer request identity; a shared URL cannot merge distinct uploads.
/// Legacy records without a request ID can still match an exact nonempty URL.
int chatUploadIndex(List<Map<String, dynamic>> messages,
    Map<String, dynamic> upload) {
  final key = _uploadKey(upload);
  if (key != null) {
    final index = messages.indexWhere((message) =>
        message['isUploadBatchNotice'] != true && _uploadKey(message) == key);
    if (index >= 0) return index;
  }
  final url = upload['fileUrl']?.toString();
  if (url == null || url.isEmpty) return -1;
  return messages.indexWhere((message) =>
      message['isUploadBatchNotice'] != true &&
      message['fileUrl'] == url &&
      (key == null || _uploadKey(message) == null));
}

bool _resolvedUpload(Map<String, dynamic> message) =>
    message['scanStopped'] == true ||
    const [
      'sent', 'received', 'delivered', 'read', 'scan_approved',
      'rejected_scan', 'stopped_scan', 'awaiting_contact_approval',
      'rejected_request', 'blocked_content',
    ].contains(message['status']);

bool hasResolvedChatUpload(List<Map<String, dynamic>> messages,
    Map<String, dynamic> upload) {
  final index = chatUploadIndex(messages, upload);
  return index >= 0 && _resolvedUpload(messages[index]);
}

/// Unchanged server history still needs to repair stale local upload progress.
bool chatUploadHistoryNeedsReconciliation(
    List<Map<String, dynamic>> history, List<Map<String, dynamic>> local) {
  for (final message in local) {
    if (!const ['uploading', 'pending_scan'].contains(message['status'])) {
      continue;
    }
    final index = chatUploadIndex(history, message);
    if (index < 0) continue;
    final saved = history[index];
    if (message['status'] == 'uploading') {
      if (_resolvedUpload(saved)) return true;
    } else {
      for (final field in const ['id', 'status', 'fileUrl', 'filterHidden',
          'moderationStatus', 'scanStopped', 'scanReason']) {
        if (message[field] != saved[field]) return true;
      }
    }
  }
  return false;
}

/// Merge an upload's local progress with its owner-only server scan record.
/// Use request identity, never filenames: two simultaneous uploads may have
/// exactly the same name. Hidden media deliberately has no playable URL.
List<Map<String, dynamic>> mergeChatUploadHistory(
  List<Map<String, dynamic>> history,
  List<Map<String, dynamic>> local, {
  bool matchLegacyText = false,
}) {
  final activeKeys = local
      .where((message) => message['status'] == 'uploading' &&
          !hasResolvedChatUpload(history, message))
      .map(_uploadKey)
      .whereType<String>()
      .where((key) => key.isNotEmpty)
      .toSet();
  final merged = history
      .where((message) => message['isUploadBatchNotice'] != true &&
          !activeKeys.contains(_uploadKey(message)))
      .toList();
  for (final message in local) {
    if (message['isUploadBatchNotice'] == true) continue;
    if (message['status'] == 'uploading' &&
        !hasResolvedChatUpload(history, message)) {
      merged.add(message);
      continue;
    }
    final key = _uploadKey(message);
    final saved = chatUploadIndex(history, message) >= 0 || history.any((entry) =>
        (message['outboxId'] != null &&
            entry['clientMessageId'] == message['outboxId']) ||
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
        (uploadIds.contains(_uploadKey(message)) ||
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
