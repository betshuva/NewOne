import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'media_pointer_barrier.dart';

enum ChatAttachmentAction {
  upload,
  capture,
  photo,
  video,
  audio,
  scan,
  contact,
  myContact,
  paste
}

Future<ChatAttachmentAction?> showChatAttachmentMenu({
  required BuildContext context,
  required GlobalKey anchorKey,
  required bool imagesAllowed,
  required bool videoAllowed,
  required bool textAllowed,
  required String blockedLabel,
  bool allowPaste = false,
}) {
  final overlay = Navigator.of(context, rootNavigator: true)
      .overlay!
      .context
      .findRenderObject()! as RenderBox;
  Rect anchorRect() {
    final box = anchorKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return Rect.zero;
    return box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  }

  return showGeneralDialog<ChatAttachmentAction>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: 'סגירת תפריט הצירוף',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (menuContext, animation, secondaryAnimation) =>
        MediaPointerBarrier(
            child: Directionality(
      textDirection: TextDirection.rtl,
      child: CustomSingleChildLayout(
        delegate: _AttachmentMenuLayout(
          anchorRect(),
          MediaQuery.of(menuContext).padding,
          MediaQuery.of(menuContext).viewInsets.bottom,
        ),
        child: _AttachmentMenu(
          imagesAllowed: imagesAllowed,
          videoAllowed: videoAllowed,
          textAllowed: textAllowed,
          blockedLabel: blockedLabel,
          allowPaste: allowPaste,
        ),
      ),
    )),
    transitionBuilder: (context, animation, secondaryAnimation, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _AttachmentMenuLayout extends SingleChildLayoutDelegate {
  const _AttachmentMenuLayout(this.anchor, this.padding, this.keyboard);
  final Rect anchor;
  final EdgeInsets padding;
  final double keyboard;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final top = padding.top + 8;
    final bottom =
        constraints.maxHeight - math.max(padding.bottom, keyboard) - 8;
    final above = anchor.top - 8 - top;
    final below = bottom - anchor.bottom - 8;
    return BoxConstraints(
      maxWidth: math.min(
          244, math.max(0, constraints.maxWidth - padding.horizontal - 16)),
      maxHeight: math.max(0, math.max(above, below)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final top = padding.top + 8;
    final bottom = size.height - math.max(padding.bottom, keyboard) - 8;
    final above = anchor.top - 8 - childSize.height;
    final y = above >= top ? above : anchor.bottom + 8;
    return Offset(
      (anchor.right - childSize.width).clamp(
          padding.left + 8,
          math.max(padding.left + 8,
              size.width - padding.right - childSize.width - 8)),
      y.clamp(top, math.max(top, bottom - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_AttachmentMenuLayout old) =>
      anchor != old.anchor ||
      padding != old.padding ||
      keyboard != old.keyboard;
}

class _AttachmentMenu extends StatefulWidget {
  const _AttachmentMenu(
      {required this.imagesAllowed,
      required this.videoAllowed,
      required this.textAllowed,
      required this.blockedLabel,
      required this.allowPaste});
  final bool imagesAllowed, videoAllowed, textAllowed, allowPaste;
  final String blockedLabel;

  @override
  State<_AttachmentMenu> createState() => _AttachmentMenuState();
}

class _AttachmentMenuState extends State<_AttachmentMenu> {
  String? _section;

  Widget _item(
    String label,
    IconData icon,
    Color color, {
    ChatAttachmentAction? action,
    String? section,
    bool allowed = true,
  }) =>
      ListTile(
        dense: true,
        minTileHeight: 48,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14),
        horizontalTitleGap: 12,
        leading: Icon(icon, color: allowed ? color : Colors.grey, size: 21),
        title: Text(label, style: const TextStyle(fontSize: 14)),
        subtitle: allowed
            ? null
            : Text(widget.blockedLabel, style: const TextStyle(fontSize: 11)),
        trailing: section != null
            ? const Icon(Icons.chevron_left,
                size: 18, textDirection: TextDirection.ltr)
            : allowed
                ? null
                : const Icon(Icons.lock_outline, size: 15),
        onTap: () {
          if (section != null) {
            setState(() => _section = section);
          } else {
            Navigator.of(context).pop(action);
          }
        },
      );

  @override
  Widget build(BuildContext context) => PopScope<ChatAttachmentAction>(
        canPop: _section == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(() => _section = null);
        },
        child: Semantics(
          scopesRoute: true,
          explicitChildNodes: true,
          namesRoute: true,
          label: 'צירוף לשיחה',
          child: Material(
            key: const ValueKey('chat-attachment-menu'),
            color: Theme.of(context).colorScheme.surface,
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (_section != null) ...[
                    ListTile(
                      dense: true,
                      minTileHeight: 44,
                      leading: const Icon(Icons.arrow_forward,
                          size: 20, textDirection: TextDirection.ltr),
                      title: Text('שיתוף איש קשר',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      onTap: () => setState(() => _section = null),
                    ),
                    const Divider(height: 1),
                  ],
                  if (_section == null) ...[
                    _item('העלאת קבצים', Icons.upload_file, Colors.blue,
                        action: ChatAttachmentAction.upload),
                    _item('צילום', Icons.camera_alt_outlined, Colors.pink,
                        action: ChatAttachmentAction.capture,
                        allowed: widget.imagesAllowed || widget.videoAllowed),
                    _item('סריקת מסמך', Icons.document_scanner_outlined,
                        Colors.orange,
                        action: ChatAttachmentAction.scan,
                        allowed: widget.textAllowed),
                    _item('שיתוף איש קשר', Icons.contact_phone_outlined,
                        Colors.teal,
                        section: 'contact'),
                    if (widget.allowPaste)
                      _item('הדבק תמונה', Icons.paste, Colors.blue,
                          action: ChatAttachmentAction.paste,
                          allowed: widget.imagesAllowed),
                    const Divider(height: 8),
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      child: Text('הקבצים עוברים סינון לפני השליחה',
                          style: TextStyle(fontSize: 11, color: Colors.grey)),
                    ),
                  ] else ...[
                    _item('שתף איש קשר', Icons.contact_phone_outlined,
                        Colors.teal,
                        action: ChatAttachmentAction.contact,
                        allowed: widget.textAllowed),
                    _item(
                        'שתף את הפרטים שלי', Icons.badge_outlined, Colors.blue,
                        action: ChatAttachmentAction.myContact,
                        allowed: widget.textAllowed),
                  ],
                ]),
              ),
            ),
          ),
        ),
      );
}
