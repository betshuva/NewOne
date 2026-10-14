import 'remote_card_notice.dart';
import 'chat_design_settings.dart';
import 'moderation_user_reason.dart';
import 'copyable_file_name.dart';
import 'scan_explanation.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

/// Shows the delivery marker and saved people categories on the image.
class BlockedImageNotice extends StatelessWidget {
  const BlockedImageNotice({
    super.key,
    required this.image,
    required this.title,
    required this.reason,
    required this.onlyYouText,
    this.classification,
    this.recipientName,
    this.fileName,
    this.expiryText,
    this.previewExpiresAt,
    this.onMoreActions,
  });

  final Map<String, dynamic>? classification;
  final Widget image;
  final String title;
  final String reason;
  final String onlyYouText;
  final String? recipientName;
  final String? fileName;
  final String? expiryText;
  final DateTime? previewExpiresAt;
  final VoidCallback? onMoreActions;

  bool get _filterOnly => isFilterBlockReason(reason);

  static const _border = Color(0xFFF0B8B8);
  static const _background = Color(0xFFFFF7F7);
  static const _text = Color(0xFF243746);

  Widget _textLine(String text, {double size = 12, bool bold = false}) => Text(
        text,
        textAlign: TextAlign.right,
        textDirection: TextDirection.rtl,
        style: TextStyle(
          fontSize: size,
          height: 1.4,
          color: _text,
          fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
        ),
      );

  Widget _frame(List<Widget> children) => Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: _filterOnly ? const Color(0xFFFFF8E8) : _background,
          border: Border.all(
              color: _filterOnly ? const Color(0xFFF2D28B) : _border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );

  void _showDetails(BuildContext context) {
    if (isModestyBlockReason(reason)) {
      showDesignCardDetails<void>(
          context,
          (dialogContext) => Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                key: const ValueKey('blocked-image-details'),
                content: const Text(modestyImageMessage),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('סגור'))
                ],
              )));
      return;
    }
    showDesignCardDetails<void>(
      context,
      (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          key: const ValueKey('blocked-image-details'),
          title: Text(_filterOnly ? 'פרטי הסינון' : 'פרטי החסימה',
              textAlign: TextAlign.right),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _frame([
                    _textLine(title, size: 13, bold: true),
                    if (recipientName?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 5),
                      _textLine('נמען: ${recipientName!.trim()}', bold: true),
                    ],
                  ]),
                  const SizedBox(height: 7),
                  _frame([
                    _textLine(reason),
                    if (classification != null)
                      _textLine(
                          'זוהו: ${scanClassificationText(classification)}')
                  ]),
                  const SizedBox(height: 7),
                  _frame([
                    _textLine(onlyYouText, size: 11),
                    if (_filterOnly &&
                        !reason.contains(retainedFilterFileMessage))
                      _textLine(retainedFilterFileMessage, size: 11),
                    if (!_filterOnly && previewExpiresAt != null) ...[
                      const SizedBox(height: 5),
                      _PreviewExpiryText(
                        expiresAt: previewExpiresAt!,
                        builder: (text) => _textLine(text, size: 11),
                      ),
                    ] else if (!_filterOnly &&
                        expiryText?.isNotEmpty == true) ...[
                      const SizedBox(height: 5),
                      _textLine(expiryText!, size: 11),
                    ],
                    if (fileName?.isNotEmpty == true) ...[
                      const SizedBox(height: 5),
                      CopyableFileName(fileName!,
                          style: const TextStyle(
                              fontSize: 10, height: 1.4, color: _text)),
                    ],
                  ]),
                ],
              ),
            ),
          ),
          actionsAlignment: MainAxisAlignment.start,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('סגירה', textAlign: TextAlign.right),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => !ChatDesignStore.shared.value
          .flag('compactBlockedMedia')
      ? InkWell(
          onTap:
              ChatDesignStore.shared.value.choice('cardTapAction', 'details') ==
                      'none'
                  ? null
                  : () => _showDetails(context),
          onLongPress:
              designCardLongPress(() => _showDetails(context), onMoreActions),
          child: _frame([
            _textLine(_filterOnly ? 'לא נשלחה — הגדרות סינון' : 'התמונה נחסמה',
                bold: true),
            if (fileName?.isNotEmpty == true) _textLine(fileName!),
            _textLine(reason),
          ]))
      : Align(
          alignment: Alignment.centerRight,
          heightFactor: 1,
          child: InkWell(
            onTap: ChatDesignStore.shared.value
                        .choice('cardTapAction', 'details') ==
                    'none'
                ? null
                : () => _showDetails(context),
            onLongPress:
                designCardLongPress(() => _showDetails(context), onMoreActions),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                textDirection: TextDirection.rtl,
                children: [
                  Icon(_filterOnly ? Icons.filter_alt_outlined : Icons.block,
                      key: const ValueKey('blocked-image-marker'),
                      size: 18,
                      color:
                          _filterOnly ? const Color(0xFFB77900) : Colors.red),
                  const SizedBox(width: 6),
                  Flexible(
                      child: Text(
                          _filterOnly
                              ? 'לא נשלחה — הגדרות סינון'
                              : 'התמונה נחסמה',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textDirection: TextDirection.rtl,
                          style: TextStyle(
                              fontSize: ChatDesignStore.shared.value
                                  .number('noticeFontSize', 12)))),
                ],
              ),
            ),
          ),
        );
}

class _PreviewExpiryText extends StatefulWidget {
  const _PreviewExpiryText({required this.expiresAt, required this.builder});

  final DateTime expiresAt;
  final Widget Function(String text) builder;

  @override
  State<_PreviewExpiryText> createState() => _PreviewExpiryTextState();
}

class _PreviewExpiryTextState extends State<_PreviewExpiryText> {
  Timer? _timer;

  int get _secondsLeft =>
      math.max(0, widget.expiresAt.difference(clock.now()).inSeconds);

  @override
  void initState() {
    super.initState();
    _startTicker();
  }

  @override
  void didUpdateWidget(covariant _PreviewExpiryText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expiresAt != widget.expiresAt) _startTicker();
  }

  void _startTicker() {
    _timer?.cancel();
    if (_secondsLeft <= 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsLeft <= 0) timer.cancel();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secondsLeft = _secondsLeft;
    if (secondsLeft <= 0) {
      return widget.builder('תצוגת התמונה הסתיימה והקובץ נמחק');
    }
    final minutes = secondsLeft ~/ 60;
    final seconds = (secondsLeft % 60).toString().padLeft(2, '0');
    return widget.builder('מוצגת רק לך ותימחק בעוד $minutes:$seconds');
  }
}
