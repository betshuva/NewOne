import 'package:flutter/material.dart';

num? uploadMetadataNumber(dynamic value) {
  final number = value is num ? value : num.tryParse(value?.toString() ?? '');
  return number != null && number.isFinite && number > 0 ? number : null;
}

String uploadScanMetadata(String type, String name,
    {num? bytes, num? durationSeconds}) {
  final label = name.toLowerCase().endsWith('.gif')
      ? 'GIF'
      : switch (type) {
          'video' => 'וידאו',
          'audio' => 'הקלטה',
          'document' => 'מסמך',
          _ => 'תמונה',
        };
  final parts = <String>[label];
  if (bytes != null && bytes.isFinite && bytes > 0) {
    parts.add(bytes >= 1024 * 1024
        ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '${(bytes / 1024).ceil()} KB');
  }
  if (durationSeconds != null &&
      durationSeconds.isFinite &&
      durationSeconds > 0) {
    final seconds = durationSeconds.ceil();
    parts.add(
        'משך ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}');
  }
  return parts.join(' · ');
}

class UploadScanDetails extends StatelessWidget {
  const UploadScanDetails(
      {super.key,
      required this.name,
      required this.phase,
      required this.metadata,
      required this.elapsedSeconds,
      required this.icon,
      required this.color,
      required this.secondaryColor});
  final String name, phase, metadata;
  final int elapsedSeconds;
  final Widget icon;
  final Color color, secondaryColor;

  @override
  Widget build(BuildContext context) => Row(children: [
        icon,
        const SizedBox(width: 8),
        Expanded(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Tooltip(
                  message: '$phase: $name',
                  child: Text('$phase: $name',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700))),
              const SizedBox(height: 2),
              Row(children: [
                Expanded(
                    child: Text(metadata,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: secondaryColor))),
                const SizedBox(width: 6),
                Text('חלפו ${elapsedSeconds < 0 ? 0 : elapsedSeconds} שנ׳',
                    style: TextStyle(fontSize: 10, color: color)),
              ]),
            ])),
      ]);
}
