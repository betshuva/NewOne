import 'dart:async';
import 'package:flutter/material.dart';
import 'chat_attachment_files.dart';

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

class ChatUploadBatchNotice extends StatelessWidget {
  final String text;
  const ChatUploadBatchNotice({super.key, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Align(
          alignment: Alignment.centerRight,
          child: Semantics(
            liveRegion: true,
            child: Text(text,
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: Color(0xFFFFB74D), fontWeight: FontWeight.bold)),
          ),
        ),
      );
}
