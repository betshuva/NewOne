import 'moderation_user_reason.dart';
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

  List<Widget> _classificationMarkers() {
    final detected = classification?['detectedCategories'];
    final categories = detected is List && detected.isNotEmpty
        ? detected.toSet()
        : {
            if (classification?['uncertain'] != true)
              classification?['category']
          };
    return [
      for (final category in ['men', 'children'])
        if (categories.contains(category))
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Tooltip(
              message: category == 'men' ? 'גברים' : 'ילדים',
              triggerMode: TooltipTriggerMode.tap,
              child: Container(
                key: ValueKey('image-category-$category'),
                width: 30,
                height: 30,
                decoration: const BoxDecoration(
                  color: Color(0xFFF7FBFF),
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 3)],
                ),
                child: Icon(
                  category == 'men' ? Icons.man : Icons.child_care,
                  size: 20,
                  color: const Color(0xFF1E6FA8),
                ),
              ),
            ),
          ),
    ];
  }

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
      showDialog<void>(
          context: context,
          builder: (dialogContext) => Directionality(
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
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Directionality(
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
                              right: 40,
                              top: 6,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: _classificationMarkers(),
                              ),
                            ),
                            if (_filterOnly)
                              const Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: ColoredBox(
                                  color: Color(0xFFFFF4D7),
                                  child: Padding(
                                    padding: EdgeInsets.all(5),
                                    child: Text('לא נשלחה — הגדרות סינון',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF765000))),
                                  ),
                                ),
                              ),
                            Positioned(
                              right: 6,
                              top: 6,
                              child: GestureDetector(
                                onTap: () => _showDetails(context),
                                child: Tooltip(
                                  message: _filterOnly
                                      ? filterOnlyMessage
                                      : 'התמונה נחסמה',
                                  child: Container(
                                    key: const ValueKey('blocked-image-marker'),
                                    padding: const EdgeInsets.all(5),
                                    decoration: BoxDecoration(
                                      color: _filterOnly
                                          ? const Color(0xFFB77900)
                                          : const Color(0xFFE53935),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                        _filterOnly
                                            ? Icons.filter_alt_outlined
                                            : Icons.gpp_bad_outlined,
                                        color: Colors.white,
                                        size: 20),
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
                      child: onMoreActions != null
                          ? IconButton(
                              key: const ValueKey('blocked-image-menu'),
                              tooltip: 'אפשרויות תמונה',
                              icon: const Icon(Icons.more_vert,
                                  color: Color(0xFF1E6FA8)),
                              onPressed: onMoreActions,
                            )
                          : PopupMenuButton<String>(
                              key: const ValueKey('blocked-image-menu'),
                              tooltip: 'אפשרויות תמונה',
                              icon: const Icon(Icons.more_vert,
                                  color: Color(0xFF1E6FA8)),
                              onSelected: (value) {
                                if (value == 'details') {
                                  _showDetails(context);
                                }
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'details',
                                  child: Text(
                                      _filterOnly
                                          ? 'פרטי הסינון'
                                          : 'פרטי החסימה',
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
