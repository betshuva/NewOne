import 'package:flutter/material.dart';

/// Recording replaces text entry, keeping both actions reachable on phones.
class VoiceRecordingBar extends StatelessWidget {
  const VoiceRecordingBar(
      {super.key,
      required this.timeLabel,
      required this.onSend,
      required this.onCancel});
  final String timeLabel;
  final VoidCallback onSend, onCancel;

  @override
  Widget build(BuildContext context) => Row(
        textDirection: TextDirection.rtl,
        children: [
          IconButton(
              tooltip: 'סיים ושלח',
              onPressed: onSend,
              icon: const Icon(Icons.stop_circle, color: Colors.red)),
          Expanded(
              child: Text('זמן הקלטה: $timeLabel · עד שעתיים',
                  textDirection: TextDirection.rtl,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.red, fontSize: 12))),
          IconButton(
              tooltip: 'בטל הקלטה',
              onPressed: onCancel,
              icon: const Icon(Icons.delete_outline, color: Colors.red)),
        ],
      );
}
