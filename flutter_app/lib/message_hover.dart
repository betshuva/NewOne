import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:math' as math;

/// Shares hover/focus state with all the details of a sent object.
class MessageHover extends StatefulWidget {
  final Widget child;
  final Widget? actions;
  final Widget? sideReactions;
  final bool reactionsOnChild;
  const MessageHover(
      {super.key,
      required this.child,
      this.actions,
      this.sideReactions,
      this.reactionsOnChild = false});

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
              reactions: widget.reactionsOnChild ? widget.sideReactions : null,
              child: widget.actions == null
                  ? _object()
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      textDirection: TextDirection.rtl,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(child: _object()),
                        SizedBox(width: 30, child: widget.actions!),
                      ],
                    ),
            ),
          ),
        ),
      );

  Widget _object() => KeyedSubtree(
        key: _objectKey,
        child: !widget.reactionsOnChild && widget.sideReactions != null
            ? _ReactionOverlay(
                object: widget.child, reactions: widget.sideReactions!)
            : widget.child,
      );
}

class _MessageHoverStateScope extends InheritedWidget {
  final bool visible;
  final GlobalKey objectKey;
  final Widget? reactions;
  const _MessageHoverStateScope(
      {required this.visible,
      required this.objectKey,
      this.reactions,
      required super.child});
  @override
  bool updateShouldNotify(_MessageHoverStateScope oldWidget) =>
      visible != oldWidget.visible || reactions != oldWidget.reactions;
}

/// Attach reactions to the media itself, before captions or delivery details.
class MessageObjectReactions extends StatelessWidget {
  const MessageObjectReactions({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reactions = context
        .dependOnInheritedWidgetOfExactType<_MessageHoverStateScope>()
        ?.reactions;
    return reactions == null
        ? child
        : _ReactionOverlay(object: child, reactions: reactions);
  }
}

class _ReactionOverlay extends MultiChildRenderObjectWidget {
  _ReactionOverlay({required Widget object, required Widget reactions})
      : super(children: [object, reactions]);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReactionOverlay();
}

class _ReactionParentData extends ContainerBoxParentData<RenderBox> {}

/// The glyph overlaps by eight pixels; its transparent hit area stays inside
/// the layout. Extra rows grow below the media instead of covering more of it.
class _RenderReactionOverlay extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ReactionParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ReactionParentData> {
  static const _overlap = 14.0;
  static const _footer = 18.0;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ReactionParentData) {
      child.parentData = _ReactionParentData();
    }
  }

  BoxConstraints _objectConstraints(BoxConstraints incoming) =>
      incoming.loosen().deflate(const EdgeInsets.only(bottom: _footer));

  BoxConstraints _reactionConstraints(double width) => BoxConstraints(
      maxWidth: math.min(constraints.maxWidth, math.max(32, width)));

  @override
  void performLayout() {
    final object = firstChild!;
    final reactions = lastChild!;
    object.layout(_objectConstraints(constraints), parentUsesSize: true);
    reactions.layout(_reactionConstraints(object.size.width),
        parentUsesSize: true);
    size = constraints.constrain(Size(
        math.max(object.size.width, math.min(32, constraints.maxWidth)),
        object.size.height +
            math.max(_footer, reactions.size.height - _overlap)));
    (object.parentData! as _ReactionParentData).offset =
        Offset(size.width - object.size.width, 0);
    (reactions.parentData! as _ReactionParentData).offset = Offset(
        size.width - reactions.size.width, object.size.height - _overlap);
  }

  @override
  Size computeDryLayout(BoxConstraints incoming) {
    final object = firstChild!.getDryLayout(_objectConstraints(incoming));
    final reactions = lastChild!.getDryLayout(BoxConstraints(
        maxWidth: math.min(incoming.maxWidth, math.max(32, object.width))));
    return incoming.constrain(Size(
        math.max(object.width, math.min(32, incoming.maxWidth)),
        object.height + math.max(_footer, reactions.height - _overlap)));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
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
