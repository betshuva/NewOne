import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Shares hover/focus state with all the details of a sent object.
class MessageHover extends StatefulWidget {
  final Widget child;
  const MessageHover({super.key, required this.child});

  static bool detailsVisible(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MessageHoverStateScope>()
          ?.visible ??
      true;

  @override
  State<MessageHover> createState() => _MessageHoverState();
}

class _MessageHoverState extends State<MessageHover> {
  bool _hovered = false;
  bool _focused = false;
  bool _touchDetails = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Focus(
          onFocusChange: (value) => setState(() => _focused = value),
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (event) {
              if (event.kind == PointerDeviceKind.touch) {
                setState(() => _touchDetails = true);
              }
            },
            child: _MessageHoverStateScope(
              visible: _hovered || _focused || _touchDetails,
              child: widget.child,
            ),
          ),
        ),
      );
}

class _MessageHoverStateScope extends InheritedWidget {
  final bool visible;
  const _MessageHoverStateScope({required this.visible, required super.child});
  @override
  bool updateShouldNotify(_MessageHoverStateScope oldWidget) =>
      visible != oldWidget.visible;
}

class MessageDetails extends StatelessWidget {
  final Widget child;
  final bool enabled;
  const MessageDetails({super.key, required this.child, this.enabled = true});
  @override
  Widget build(BuildContext context) =>
      !enabled || MessageHover.detailsVisible(context)
          ? child
          : const SizedBox.shrink();
}
