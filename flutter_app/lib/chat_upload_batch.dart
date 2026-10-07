import 'dart:async';
import 'package:flutter/material.dart';
import 'chat_attachment_files.dart';
import 'chat_upload_history.dart';

/// Stable identities keep a completion notice after its files when server
/// timestamps change during background scanning or differ from the device.
class ChatUploadBatchOrder {
  final uploadIds = <String>{};
  final messageIds = <String>{};
  void recordResult(Map<String, dynamic> data) {
    final id = data['_sentMessageId']?.toString();
    if (id != null && id.isNotEmpty) messageIds.add(id);
  }
  Map<String, dynamic> get noticeFields => {
    'uploadIds': uploadIds.toList(), 'messageIds': messageIds.toList(),
  };
}

void showChatUploadLimitExceeded(BuildContext context, int count) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('נבחרו $count קבצים. ניתן להעלות עד $maxChatAttachments '
        'קבצים בכל פעם. הפעולה בוטלה.'),
  ));
}

Future<bool> confirmChatUploadBatch(BuildContext context, int count) async {
  if (count <= 2) return true;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('אישור העלאת קבצים'),
          content: Text('אתה עומד להעלות $count קבצים. האם אתה בטוח?',
              textDirection: TextDirection.rtl),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('ביטול')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('כן, העלה')),
          ],
        ),
      ) ??
      false;
}

/// Reports a clean completion only when every attempt completed successfully.
Future<void> runChatUploadBatch({
  required int count,
  required FutureOr<void> Function(String text) onNotice,
  required Future<void> Function() upload,
  int Function()? failedCount,
}) async {
  if (count == 0) return;
  await onNotice('מעלה $count קבצים');
  try {
    await upload();
  } catch (_) {
    await onNotice('העלאת $count קבצים הופסקה');
    rethrow;
  }
  final failed = (failedCount?.call() ?? 0).clamp(0, count);
  await onNotice(failed == 0
      ? 'סוף העלאת $count קבצים'
      : 'סוף תור ההעלאה: ${count - failed} מתוך $count הושלמו, $failed נכשלו');
}

String? chatUploadBatchSummary(
    Map<String, dynamic> notice, List<Map<String, dynamic>> messages) {
  final text = notice['text']?.toString() ?? '';
  final completed = RegExp(r'^סוף העלאת (\d+) קבצים$').firstMatch(text);
  final partial = RegExp(r'^סוף תור ההעלאה: (\d+) מתוך (\d+) הושלמו, (\d+) נכשלו$')
      .firstMatch(text);
  final interrupted = RegExp(r'^העלאת (\d+) קבצים הופסקה$').firstMatch(text);
  final total = int.tryParse(completed?.group(1) ?? partial?.group(2) ??
      interrupted?.group(1) ?? '');
  if (total == null || total <= 0) return null;
  var sent = 0, blocked = 0, pending = 0, failed = 0;
  for (final message in chatUploadBatchMembers(notice, messages)) {
    final status = message['status']?.toString();
    final moderation = message['moderationStatus']?.toString();
    if (message['scanStopped'] == true ||
        const ['stopped', 'stopped_scan', 'rejected', 'rejected_scan', 'blocked_content']
            .contains(status) ||
        const ['stopped', 'rejected'].contains(moderation)) {
      blocked++;
    } else if (status == 'failed') {
      failed++;
    } else if (const ['uploading', 'sending', 'pending', 'pending_scan',
        'awaiting_contact_approval'].contains(status) || moderation == 'pending') {
      pending++;
    } else if (const ['sent', 'received', 'delivered', 'read'].contains(status)) {
      sent++;
    }
  }
  // Failed requests may have no message row. The persisted queue result is
  // authoritative for these failures, including files rejected before upload.
  final declaredFailures = int.tryParse(partial?.group(3) ?? '') ?? 0;
  if (declaredFailures > failed) failed = declaredFailures;
  // Queue completion alone is not scan/delivery completion. Incomplete history
  // also cannot establish that every operation finished.
  final unknown = total - sent - blocked - pending - failed;
  if (pending > 0 || unknown != 0) return null;
  return [
    'סיכום: נשלחו $sent',
    'נחסמו $blocked',
    if (failed > 0) 'נכשלו בהעלאה $failed',
  ].join(' · ');
}

class ChatUploadBatchNotice extends StatelessWidget {
  final String text;
  final String? summary;
  const ChatUploadBatchNotice({super.key, required this.text, this.summary});

  @override
  Widget build(BuildContext context) {
    final display = text.startsWith('מעלה ') ? text : summary;
    if (display == null) return const SizedBox.shrink();
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Align(
          alignment: Alignment.centerRight,
          child: Semantics(
            liveRegion: true,
            child: Text(display,
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: Color(0xFFFFB74D), fontWeight: FontWeight.bold),
            ),
          ),
        ),
      );
  }
}
