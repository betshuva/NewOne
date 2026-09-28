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
  return merged;
}

bool isPendingOwnUpload(Map<String, dynamic> message) =>
    message['id']?.toString().startsWith('scan_') == true &&
    message['status'] == 'pending_scan' &&
    message['contentPurged'] != true &&
    const [null, 'pending', 'pending_scan']
        .contains(message['moderationStatus']);
