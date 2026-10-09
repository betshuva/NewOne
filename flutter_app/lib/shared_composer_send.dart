import 'package:flutter/widgets.dart';

/// Sends a separately shared item while preserving an existing text draft.
/// The caller isolates and restores edit/reply context alongside this value.
Future<void> sendSeparateComposerText(
  TextEditingController controller,
  String text, {
  required bool Function() canRestore,
  required VoidCallback isolateContext,
  required VoidCallback restoreContext,
  required Future<void> Function() send,
}) async {
  if (!canRestore()) return;
  final draft = controller.value;
  isolateContext();
  controller.text = text;
  try {
    await send();
  } finally {
    if (canRestore() && (controller.text.isEmpty || controller.text == text)) {
      controller.value = draft;
      restoreContext();
    }
  }
}
