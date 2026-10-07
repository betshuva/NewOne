import 'package:flutter/widgets.dart';

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
