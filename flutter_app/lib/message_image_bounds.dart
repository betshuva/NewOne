import 'package:flutter/widgets.dart';

/// Portrait camera photos need enough height to remain readable in a chat.
/// Uploaded stickers retain their compact presentation; inline emoji use a
/// separate text renderer and never pass through these bounds.
Size chatImageMaxSize({bool group = false, String? fileName}) {
  final name = (fileName ?? '').toLowerCase();
  final sticker = name.startsWith('betshuva-sticker-') ||
      name.startsWith('sticker_') ||
      name.startsWith('betshuva_');
  if (sticker) return group ? const Size(200, 160) : const Size(220, 180);
  return group ? const Size(200, 360) : const Size(220, 380);
}

/// Keeps a decoded image's aspect ratio without adding a letterboxed frame.
/// The image child must omit explicit width/height so RenderImage can choose
/// its natural size within these caps.
class MessageImageBounds extends StatelessWidget {
  const MessageImageBounds({
    super.key,
    required this.child,
    required this.maxWidth,
    required this.maxHeight,
  });

  final Widget child;
  final double maxWidth, maxHeight;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: child,
      );
}
