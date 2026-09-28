import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Shares hover/focus state with all the details of a sent object.
class MessageHover extends StatefulWidget {
  final Widget child;
  final Widget? actions;
  final Widget? sideReactions;
  const MessageHover(
      {super.key, required this.child, this.actions, this.sideReactions});

  static bool detailsVisible(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MessageHoverStateScope>()
          ?.visible ??
      true;

  static BuildContext? objectContext(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_MessageHoverStateScope>()
      ?.objectKey
      .currentContext;

  @override
  State<MessageHover> createState() => _MessageHoverState();
}

class _MessageHoverState extends State<MessageHover> {
  final _objectKey = GlobalKey();
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
              objectKey: _objectKey,
              visible: _hovered || _focused || _touchDetails,
              child: widget.actions == null
                  ? widget.child
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      textDirection: TextDirection.rtl,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                            child: KeyedSubtree(
                                key: _objectKey, child: widget.child)),
                        // Reserve a stable side column: reaction updates and
                        // hover must not change the object's available width.
                        if (widget.sideReactions != null)
                          SizedBox(
                              width: 72,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                textDirection: TextDirection.ltr,
                                children: [
                                  widget.actions!,
                                  widget.sideReactions!
                                ],
                              ))
                        else
                          widget.actions!,
                      ],
                    ),
            ),
          ),
        ),
      );
}

class _MessageHoverStateScope extends InheritedWidget {
  final bool visible;
  final GlobalKey objectKey;
  const _MessageHoverStateScope(
      {required this.visible, required this.objectKey, required super.child});
  @override
  bool updateShouldNotify(_MessageHoverStateScope oldWidget) =>
      visible != oldWidget.visible;
}

class MessageDetails extends StatelessWidget {
  final Widget child;
  final bool enabled;
  const MessageDetails({super.key, required this.child, this.enabled = true});
  @override
  Widget build(BuildContext context) => Visibility(
        visible: !enabled || MessageHover.detailsVisible(context),
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        child: child,
      );
}
