import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

/// Shows only a blocked marker on the image; details live in its options menu.
class BlockedImageNotice extends StatelessWidget {
  const BlockedImageNotice({
    super.key,
    required this.image,
    required this.title,
    required this.reason,
    required this.onlyYouText,
    this.recipientName,
    this.fileName,
    this.expiryText,
    this.previewExpiresAt,
    this.onMoreActions,
  });

  final Widget image;
  final String title;
  final String reason;
  final String onlyYouText;
  final String? recipientName;
  final String? fileName;
  final String? expiryText;
  final DateTime? previewExpiresAt;
  final VoidCallback? onMoreActions;

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
          color: _background,
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );

  void _showDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          key: const ValueKey('blocked-image-details'),
          title: const Text('פרטי החסימה', textAlign: TextAlign.right),
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
                  _frame([_textLine(reason)]),
                  const SizedBox(height: 7),
                  _frame([
                    _textLine(onlyYouText, size: 11),
                    if (previewExpiresAt != null) ...[
                      const SizedBox(height: 5),
                      _PreviewExpiryText(
                        expiresAt: previewExpiresAt!,
                        builder: (text) => _textLine(text, size: 11),
                      ),
                    ] else if (expiryText?.isNotEmpty == true) ...[
                      const SizedBox(height: 5),
                      _textLine(expiryText!, size: 11),
                    ],
                    if (fileName?.isNotEmpty == true) ...[
                      const SizedBox(height: 5),
                      _textLine(fileName!, size: 10),
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
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 310),
          child: LayoutBuilder(builder: (context, constraints) {
            final width = math.min(310.0, constraints.maxWidth);
            final imageWidth = math.max(0.0, width - 40);
            final imageHeight = (imageWidth * 0.75).clamp(112.0, 200.0);
            return SizedBox(
              width: width,
              child: Directionality(
                textDirection: TextDirection.rtl,
                child: Row(
                  textDirection: TextDirection.rtl,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      key: const ValueKey('blocked-image-preview'),
                      width: imageWidth,
                      height: imageHeight,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            image,
                            Positioned(
                              right: 6,
                              top: 6,
                              child: IgnorePointer(
                                child: Tooltip(
                                  message: 'התמונה נחסמה',
                                  child: Container(
                                    key: const ValueKey('blocked-image-marker'),
                                    padding: const EdgeInsets.all(5),
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFE53935),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.gpp_bad_outlined,
                                        color: Colors.white, size: 20),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: PopupMenuButton<String>(
                        key: const ValueKey('blocked-image-menu'),
                        tooltip: 'אפשרויות תמונה',
                        icon: const Icon(Icons.more_vert,
                            color: Color(0xFF1E6FA8)),
                        onSelected: (value) {
                          if (value == 'details') {
                            _showDetails(context);
                          } else {
                            onMoreActions?.call();
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'details',
                            child: Text('פרטי החסימה',
                                textAlign: TextAlign.right,
                                textDirection: TextDirection.rtl),
                          ),
                          if (onMoreActions != null)
                            const PopupMenuItem(
                              value: 'more',
                              child: Text('אפשרויות נוספות',
                                  textAlign: TextAlign.right,
                                  textDirection: TextDirection.rtl),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
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
