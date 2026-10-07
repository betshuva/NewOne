import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'message_action_bar.dart';
import 'message_reactions.dart';

Future<void> showMessageOptionsMenu({
  required BuildContext context,
  BuildContext? anchorContext,
  required String api,
  required String token,
  required Map<String, dynamic> message,
  required List<Widget> items,
}) async {
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final box = anchorContext?.findRenderObject();
  final anchor = box is RenderBox && box.attached
      ? box.localToGlobal(Offset.zero, ancestor: overlay) & box.size
      : Rect.fromCenter(
          center: overlay.size.center(Offset.zero), width: 0, height: 0);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final selected = await showGeneralDialog<String>(
    context: context,
    useRootNavigator: false,
    barrierDismissible: true,
    barrierLabel: 'סגור אפשרויות הודעה',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 100),
    pageBuilder: (menuContext, _, __) => Directionality(
      textDirection: TextDirection.rtl,
      child: CustomSingleChildLayout(
        delegate: _MessageMenuLayout(anchor, MediaQuery.of(menuContext).padding,
            MediaQuery.of(menuContext).viewInsets.bottom),
        child: Material(
          key: const ValueKey('message-options-menu'),
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (canReactToMessage(message)) ...[
                MessageReactions(
                    api: api,
                    token: token,
                    messageId: message['id'].toString(),
                    showExistingReactions: false,
                    onReactionSelected: (emoji) =>
                        Navigator.of(menuContext).pop(emoji)),
                const Divider(height: 5),
              ],
              ...items,
            ]),
          ),
        ),
      ),
    ),
    transitionBuilder: (_, animation, __, child) =>
        FadeTransition(opacity: animation, child: child),
  );
  if (selected == null || !context.mounted) return;
  try {
    await updateMessageReaction(
        api: api,
        token: token,
        messageId: message['id'].toString(),
        emoji: selected);
  } catch (_) {
    if (messenger != null && messenger.mounted) {
      messenger.showSnackBar(
          const SnackBar(content: Text('לא ניתן לעדכן את התגובה כרגע')));
    }
  }
}

class CompactMessageMenuItem extends StatelessWidget {
  const CompactMessageMenuItem(
      {super.key,
      required this.leading,
      required this.title,
      required this.onTap});
  final Widget leading, title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
          child: Row(children: [
            IconTheme.merge(
                data: const IconThemeData(size: 16), child: leading),
            const SizedBox(width: 7),
            Expanded(
                child: DefaultTextStyle.merge(
                    style: const TextStyle(fontSize: 12, height: 1.25),
                    child: title)),
          ]),
        ),
      );
}

class _MessageMenuLayout extends SingleChildLayoutDelegate {
  const _MessageMenuLayout(this.anchor, this.padding, this.keyboard);
  final Rect anchor;
  final EdgeInsets padding;
  final double keyboard;
  double get top => padding.top + 6;
  double bottom(double height) =>
      height - math.max(padding.bottom, keyboard) - 6;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(
        208.0, math.max(0.0, constraints.maxWidth - padding.horizontal - 12));
    return BoxConstraints.tightFor(width: width)
        .copyWith(maxHeight: math.max(0, bottom(constraints.maxHeight) - top));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
        (anchor.left - childSize.width - 4).clamp(
            padding.left + 6,
            math.max(padding.left + 6,
                size.width - padding.right - childSize.width - 6)),
        anchor.top
            .clamp(top, math.max(top, bottom(size.height) - childSize.height)),
      );

  @override
  bool shouldRelayout(_MessageMenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      keyboard != oldDelegate.keyboard;
}
