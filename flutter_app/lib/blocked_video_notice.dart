import 'package:flutter/material.dart';
import 'copyable_file_name.dart';

const blockedVideoMessage = 'הסירטון נחסם';

/// User-facing result shared by rejected and stopped video scans.
class BlockedVideoNotice extends StatelessWidget {
  const BlockedVideoNotice({super.key, this.fileName});

  final String? fileName;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(maxWidth: 280),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0xFFF0F5F9),
            borderRadius: BorderRadius.circular(10)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (fileName?.trim().isNotEmpty == true) ...[
            CopyableFileName(fileName!,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
          ],
          const Icon(Icons.block),
          const SizedBox(height: 6),
          const Text(blockedVideoMessage, textAlign: TextAlign.center),
        ]),
      );
}
