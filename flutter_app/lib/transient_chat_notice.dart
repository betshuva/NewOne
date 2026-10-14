import 'package:flutter/material.dart';

/// Operational chat feedback replaces older notices instead of building a queue.
/// Delivery and moderation state remain on the message itself.
void showTransientChatNotice(
  BuildContext context,
  String message, {
  Color? backgroundColor,
  Widget? leading,
  SnackBarAction? action,
  Duration duration = const Duration(seconds: 4),
}) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final text = Text(message,
      textDirection: TextDirection.rtl, textAlign: TextAlign.right);
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      backgroundColor: backgroundColor,
      duration: duration,
      persist: false,
      showCloseIcon: true,
      action: action,
      content: leading == null
          ? text
          : Row(children: [
              leading,
              const SizedBox(width: 10),
              Expanded(child: text),
            ]),
    ));
}
