import 'chat_design_settings.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'message_action_bar.dart';
import 'message_reaction_picker.dart';
import 'message_reactions.dart';

Future<void> showMessageOptionsMenu({
  required BuildContext context,
  BuildContext? anchorContext,
  required String api,
  required String token,
  required Map<String, dynamic> message,
  required List<Widget> items,
}) async {
  final design = ChatDesignStore.shared.value;
  final presentation = design.choice('messageMenuPresentation', 'auto');
  final orderedItems = design.orderedItems(
      'messageMenuOrder',
      items,
      (item) => item is CompactMessageMenuItem && item.title is Text
          ? (item.title as Text).data ?? ''
          : '');
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
    barrierDismissible: design.flag('messageMenuDismissOnOutsideTap'),
    barrierLabel: 'סגור אפשרויות הודעה',
    barrierColor: presentation == 'auto' ? Colors.transparent : Colors.black26,
    transitionDuration: const Duration(milliseconds: 100),
    pageBuilder: (menuContext, _, __) => Directionality(
      textDirection: TextDirection.rtl,
      child: CustomSingleChildLayout(
        delegate: _MessageMenuLayout(
            anchor,
            MediaQuery.of(menuContext).padding,
            MediaQuery.of(menuContext).viewInsets.bottom,
            presentation == 'sheet'
                ? 450
                : presentation == 'dialog'
                    ? 320
                    : canReactToMessage(message)
                        ? 246
                        : 208,
            presentation),
        child: Material(
          key: const ValueKey('message-options-menu'),
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (canReactToMessage(message)) ...[
                _MessageReactionRow(
                    onSelected: (emoji) => Navigator.of(menuContext).pop(emoji),
                    onMore: () async {
                      final menuRoute = ModalRoute.of(menuContext);
                      final selected =
                          await showMessageReactionEmojiPicker(menuContext);
                      if (menuContext.mounted &&
                          selected != null &&
                          menuRoute?.isCurrent == true) {
                        Navigator.of(menuContext).pop(selected);
                      }
                    }),
                const Divider(height: 5),
              ],
              ...orderedItems,
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

class _MessageReactionRow extends StatelessWidget {
  const _MessageReactionRow({required this.onSelected, required this.onMore});

  final ValueChanged<String> onSelected;
  final VoidCallback onMore;
  static const _choices = ['👍', '❤️', '😂', '😮', '😢', '🙏'];
  static const _assets = {
    '👍': '1f44d',
    '❤️': '2764',
    '😂': '1f602',
    '😮': '1f62e',
    '😢': '1f622',
    '🙏': '1f64f',
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final width = math.min(32.0, constraints.maxWidth / 7);
          Widget button({
            required Key key,
            required String tooltip,
            required VoidCallback onPressed,
            required Widget icon,
          }) =>
              IconButton(
                key: key,
                tooltip: tooltip,
                onPressed: onPressed,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tightFor(width: width, height: 40),
                style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                icon: icon,
              );

          return Row(
            key: const ValueKey('message-reaction-quick-row'),
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            textDirection: TextDirection.rtl,
            children: [
              for (final emoji in _choices)
                button(
                    key: ValueKey('select-message-reaction-$emoji'),
                    tooltip: 'תגובה $emoji',
                    onPressed: () => onSelected(emoji),
                    icon: SvgPicture.asset(
                        'assets/twemoji/svg/${_assets[emoji]}.svg',
                        width: 24,
                        height: 24,
                        excludeFromSemantics: true)),
              button(
                  key: const ValueKey('message-reaction-more'),
                  tooltip: 'כל האימוג׳י',
                  onPressed: onMore,
                  icon: const Icon(Icons.add, size: 24)),
            ],
          );
        },
      );
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
  const _MessageMenuLayout(
      this.anchor, this.padding, this.keyboard, this.desiredWidth,
      [this.presentation = 'auto']);
  final String presentation;
  final Rect anchor;
  final EdgeInsets padding;
  final double keyboard;
  final double desiredWidth;
  double get top => padding.top + 6;
  double bottom(double height) =>
      height - math.max(padding.bottom, keyboard) - 6;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(desiredWidth,
        math.max(0.0, constraints.maxWidth - padding.horizontal - 12));
    return BoxConstraints.tightFor(width: width)
        .copyWith(maxHeight: math.max(0, bottom(constraints.maxHeight) - top));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    if (presentation != 'auto') {
      return Offset(
          (size.width - childSize.width) / 2,
          presentation == 'sheet'
              ? math.max(top, bottom(size.height) - childSize.height)
              : top +
                  math.max(
                      0, (bottom(size.height) - top - childSize.height) / 2));
    }
    return Offset(
        (anchor.left - childSize.width - 4).clamp(
            padding.left + 6,
            math.max(padding.left + 6,
                size.width - padding.right - childSize.width - 6)),
        anchor.top
            .clamp(top, math.max(top, bottom(size.height) - childSize.height)));
  }

  @override
  bool shouldRelayout(_MessageMenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      padding != oldDelegate.padding ||
      keyboard != oldDelegate.keyboard ||
      desiredWidth != oldDelegate.desiredWidth ||
      presentation != oldDelegate.presentation;
}
