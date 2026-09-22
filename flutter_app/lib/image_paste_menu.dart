import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

Future<void> pasteChatImage(
    BuildContext context, Future<bool> Function() pasteImage) async {
  final pasted = await pasteImage();
  if (!pasted && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('לא נמצאה תמונה זמינה בלוח ההעתקה')));
  }
}

Widget buildImagePasteMenu(BuildContext context, EditableTextState state,
    Future<bool> Function() pasteImage) {
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: [
      ...state.contextMenuButtonItems,
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
        ContextMenuButtonItem(
          label: 'הדבק תמונה',
          onPressed: () async {
            state.hideToolbar();
            await pasteChatImage(context, pasteImage);
          },
        ),
    ],
  );
}
