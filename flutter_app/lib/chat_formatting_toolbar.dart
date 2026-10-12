import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chat_text_formatting.dart';
import 'inline_custom_emoji.dart';

const _tools = <(ChatTextFormat, String, IconData)>[
  (ChatTextFormat.bold, 'מודגש', Icons.format_bold),
  (ChatTextFormat.italic, 'נטוי', Icons.format_italic),
  (ChatTextFormat.strikethrough, 'קו חוצה', Icons.strikethrough_s),
  (ChatTextFormat.code, 'קוד', Icons.code),
  (ChatTextFormat.bulletList, 'רשימת תבליטים', Icons.format_list_bulleted),
  (ChatTextFormat.numberedList, 'רשימה ממוספרת', Icons.format_list_numbered),
  (ChatTextFormat.quote, 'ציטוט', Icons.format_quote),
];

const _textColors = <(int, String)>[
  (0x1A2734, 'כהה'),
  (0x1976D2, 'כחול'),
  (0x245D83, 'כחול כהה'),
  (0x00796B, 'טורקיז'),
  (0x2E7D32, 'ירוק'),
  (0x7B1FA2, 'סגול'),
  (0xAD1457, 'ורוד'),
  (0xC62828, 'אדום'),
  (0xE65100, 'כתום'),
  (0x6D4C41, 'חום'),
];

const _backgroundColors = <(int, String)>[
  (0xFFF59D, 'צהוב בהיר'),
  (0xBBDEFB, 'כחול בהיר'),
  (0xC8E6C9, 'ירוק בהיר'),
  (0xE1BEE7, 'סגול בהיר'),
  (0xF8BBD0, 'ורוד בהיר'),
  (0xFFCDD2, 'אדום בהיר'),
  (0xFFE0B2, 'כתום בהיר'),
  (0xB2DFDB, 'טורקיז בהיר'),
  (0xE7EEF5, 'אפור בהיר'),
  (0xFFFFFF, 'לבן'),
];

class _ColorChoice {
  const _ColorChoice(this.rgb);
  final int? rgb;
}

({int? foreground, int? background}) _selectedColors(TextEditingValue value) {
  final foreground = <int?>{};
  final background = <int?>{};
  var offset = 0;
  for (final run in parseChatFormattedText(value.text, preserveMarkers: true)) {
    final end = offset + run.text.length;
    if (!run.marker &&
        offset < value.selection.end &&
        end > value.selection.start &&
        inlineEmojiPlainText(run.text).trim().isNotEmpty) {
      foreground.add(run.foregroundRgb);
      background.add(run.backgroundRgb);
    }
    offset = end;
  }
  return (
    foreground: foreground.length == 1 ? foreground.first : null,
    background: background.length == 1 ? background.first : null,
  );
}

String chatFormattedVisibleText(String text) =>
    parseChatFormattedText(text).map((run) => run.text).join();

bool hasChatComposerText(String text) =>
    inlineEmojiPlainText(chatFormattedVisibleText(text)).trim().isNotEmpty;

bool hasChatFormattingSelection(TextEditingValue value) {
  if (!value.selection.isValid ||
      value.selection.end > value.text.length ||
      value.selection.isCollapsed) {
    return false;
  }
  var offset = 0;
  for (final run in parseChatFormattedText(value.text, preserveMarkers: true)) {
    final end = offset + run.text.length;
    if (!run.marker &&
        offset < value.selection.end &&
        end > value.selection.start) {
      final startInRun = math.max(0, value.selection.start - offset);
      final endInRun = math.min(run.text.length, value.selection.end - offset);
      if (inlineEmojiPlainText(run.text.substring(startInRun, endInRun))
          .trim()
          .isNotEmpty) {
        return true;
      }
    }
    offset = end;
  }
  return false;
}

/// Toolbar clicks preserve both text focus and the selected character range.
class ChatFormattingToolbar extends StatelessWidget {
  const ChatFormattingToolbar({
    super.key,
    required this.controller,
    required this.focusNode,
    this.compact = false,
    this.enabled = true,
    this.onApplied,
    this.buttonKeyPrefix = 'chat-format',
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool compact, enabled;
  final VoidCallback? onApplied;
  final String buttonKeyPrefix;

  static double preferredWidth({bool compact = false}) =>
      (_tools.length + 2) * (compact ? 30.0 : 32.0);

  Future<void> _pickColor(ChatTextColorTarget target) async {
    final original = controller.value;
    if (!enabled ||
        !hasChatFormattingSelection(original) ||
        (original.isComposingRangeValid && !original.composing.isCollapsed)) {
      return;
    }
    // The toolbar may be rebuilt while its dialog has keyboard focus. Keep
    // the field's context, which also guards against a closed conversation.
    final fieldContext = focusNode.context;
    if (fieldContext == null || !fieldContext.mounted) return;
    final colors = _selectedColors(original);
    final foreground = target == ChatTextColorTarget.foreground;
    final selected = foreground ? colors.foreground : colors.background;
    onApplied?.call();
    final choice = await showDialog<_ColorChoice>(
      context: fieldContext,
      builder: (dialogContext) => TextFieldTapRegion(
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            key: const ValueKey('chat-color-picker'),
            backgroundColor: Colors.white,
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(children: [
              Icon(
                  foreground
                      ? Icons.format_color_text
                      : Icons.format_color_fill,
                  color: const Color(0xFF245D83)),
              const SizedBox(width: 10),
              Text(foreground ? 'צבע טקסט' : 'צבע רקע',
                  style: const TextStyle(fontSize: 18)),
            ]),
            content: SizedBox(
              width: 280,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color:
                            Color(0xFF000000 | (colors.background ?? 0xF0F7FD)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text('כך ייראה הטקסט',
                          key: const ValueKey('chat-color-preview'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Color(
                                  0xFF000000 | (colors.foreground ?? 0x1A2734)),
                              fontSize: 16)),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final (rgb, label)
                            in foreground ? _textColors : _backgroundColors)
                          Semantics(
                            button: true,
                            selected: selected == rgb,
                            label: label,
                            child: Tooltip(
                              message: label,
                              child: Material(
                                color: Color(0xFF000000 | rgb),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    side: BorderSide(
                                        width: selected == rgb ? 2 : 1,
                                        color: selected == rgb
                                            ? const Color(0xFF245D83)
                                            : const Color(0xFFD8E5EF))),
                                child: InkWell(
                                  key: ValueKey(
                                      'chat-color-swatch-${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}'),
                                  borderRadius: BorderRadius.circular(10),
                                  onTap: () => Navigator.of(dialogContext)
                                      .pop(_ColorChoice(rgb)),
                                  child: SizedBox.square(
                                    dimension: 36,
                                    child: selected == rgb
                                        ? Icon(Icons.check,
                                            size: 20,
                                            color: ThemeData
                                                        .estimateBrightnessForColor(
                                                            Color(0xFF000000 |
                                                                rgb)) ==
                                                    Brightness.dark
                                                ? Colors.white
                                                : const Color(0xFF245D83))
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text('הצבע יחול על הטקסט המסומן',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(color: Color(0xFF607D8B), fontSize: 12)),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton.icon(
                key: const ValueKey('chat-color-clear'),
                onPressed: () =>
                    Navigator.of(dialogContext).pop(const _ColorChoice(null)),
                icon: const Icon(Icons.format_color_reset, size: 18),
                label: const Text('ללא צבע'),
              ),
              TextButton(
                key: const ValueKey('chat-color-cancel'),
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('ביטול'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!fieldContext.mounted || controller.text != original.text) return;
    if (controller.value.isComposingRangeValid &&
        !controller.value.composing.isCollapsed) {
      return;
    }
    controller.value = choice == null
        ? controller.value.copyWith(selection: original.selection)
        : colorChatSelection(original, target, rgb: choice.rgb);
    focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final composing =
                  value.isComposingRangeValid && !value.composing.isCollapsed;
              final canApply =
                  enabled && hasChatFormattingSelection(value) && !composing;
              final height = compact ? 24.0 : 36.0;
              return Material(
                color: const Color(0xFFFFFFFF),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: const BorderSide(color: Color(0xFFD8E5EF))),
                clipBehavior: Clip.antiAlias,
                child: SizedBox(
                  height: height,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      textDirection: TextDirection.rtl,
                      children: [
                        for (final target in ChatTextColorTarget.values)
                          ExcludeFocus(
                            child: IconButton(
                              key: ValueKey('$buttonKeyPrefix-${target.name}'),
                              tooltip: target == ChatTextColorTarget.foreground
                                  ? 'צבע טקסט'
                                  : 'צבע רקע',
                              icon: Icon(
                                  target == ChatTextColorTarget.foreground
                                      ? Icons.format_color_text
                                      : Icons.format_color_fill,
                                  size: compact ? 17 : 20),
                              color: const Color(0xFF245D83),
                              padding: EdgeInsets.all(compact ? 3 : 6),
                              constraints: BoxConstraints.tightFor(
                                  width: compact ? 30 : 32, height: height),
                              style: const ButtonStyle(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed:
                                  canApply ? () => _pickColor(target) : null,
                            ),
                          ),
                        for (final (format, label, icon) in _tools)
                          ExcludeFocus(
                            child: IconButton(
                              key: ValueKey('$buttonKeyPrefix-${format.name}'),
                              tooltip: label,
                              icon: Icon(icon, size: compact ? 17 : 20),
                              color: const Color(0xFF245D83),
                              padding: EdgeInsets.all(compact ? 3 : 6),
                              constraints: BoxConstraints.tightFor(
                                  width: compact ? 30 : 32, height: height),
                              style: const ButtonStyle(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: !canApply
                                  ? null
                                  : () {
                                      final next = formatChatSelection(
                                          controller.value, format);
                                      if (next == controller.value) return;
                                      controller.value = next;
                                      onApplied?.call();
                                      focusNode.requestFocus();
                                    },
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
}

/// Leaves space for the platform toolbar's copy/paste overflow controls.
double chatContextFormattingWidth(BuildContext context) =>
    math.max(120, math.min(280, MediaQuery.sizeOf(context).width - 96));
