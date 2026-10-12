import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'chat_formatting_toolbar.dart';

Future<void> pasteChatImage(
    BuildContext context, Future<bool> Function() pasteImage) async {
  final pasted = await pasteImage();
  if (!pasted && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('לא נמצאה תמונה זמינה בלוח ההעתקה')));
  }
}

Widget buildImagePasteMenu(BuildContext context, EditableTextState state,
    Future<bool> Function() pasteImage,
    {bool formattingEnabled = false}) {
  final items = [
    ...state.contextMenuButtonItems,
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
      ContextMenuButtonItem(
        label: 'הדבק תמונה',
        onPressed: () async {
          state.hideToolbar();
          await pasteChatImage(context, pasteImage);
        },
      ),
  ];
  if (formattingEnabled &&
      hasChatFormattingSelection(state.widget.controller.value)) {
    return AdaptiveTextSelectionToolbar(
      anchors: state.contextMenuAnchors,
      children: [
        SizedBox(
          width: chatContextFormattingWidth(context),
          child: ChatFormattingToolbar(
            key: const ValueKey('chat-context-formatting-toolbar'),
            controller: state.widget.controller,
            focusNode: state.widget.focusNode,
            buttonKeyPrefix: 'chat-context-format',
            onApplied: state.hideToolbar,
          ),
        ),
        ...AdaptiveTextSelectionToolbar.getAdaptiveButtons(context, items),
      ],
    );
  }
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: items,
  );
}
