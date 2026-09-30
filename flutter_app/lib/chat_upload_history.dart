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
      .where((message) => !activeKeys.contains(uploadKey(message)))
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
  for (final notice in local.where((m) => m['isUploadBatchNotice'] == true)) {
    if (merged.any((entry) => entry['id'] == notice['id'])) continue;
    final time = DateTime.tryParse(notice['createdAt']?.toString() ?? '');
    final index = time == null
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
