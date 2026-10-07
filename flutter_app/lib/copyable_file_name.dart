import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Copies the full filename even when its displayed label is truncated.
class CopyableFileName extends StatelessWidget {
  const CopyableFileName(this.fileName,
      {super.key, this.style, this.maxLines, this.overflow});

  final String fileName;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  Future<void> _copy(BuildContext context) async {
    var message = 'שם הקובץ הועתק';
    try {
      await Clipboard.setData(ClipboardData(text: fileName));
    } catch (_) {
      message = 'לא ניתן להעתיק את שם הקובץ. אפשר לנסות שוב.';
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(message), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'העתקת שם הקובץ',
        child: Semantics(
          button: true,
          child: InkWell(
            onTap: () => _copy(context),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(fileName,
                  textAlign: TextAlign.right,
                  style: style,
                  maxLines: maxLines,
                  overflow: overflow),
            ),
          ),
        ),
      );
}
