// Legacy DOM bridge required by the current Flutter web plugin interface.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

typedef ClipboardImageCallback = Future<void> Function(
    Uint8List bytes, String fileName, String mimeType);

class ClipboardImagePasteListener {
  final FocusNode focusNode;
  final ClipboardImageCallback onImage;
  late final void Function(html.Event) _listener;
  bool _handling = false;

  ClipboardImagePasteListener({
    required this.focusNode,
    required this.onImage,
  }) {
    _listener = _handlePaste;
    html.document.addEventListener('paste', _listener);
  }

  Future<void> _handlePaste(html.Event event) async {
    if (!focusNode.hasFocus || _handling || event is! html.ClipboardEvent) {
      return;
    }
    final items = event.clipboardData?.items;
    if (items == null) return;
    for (var index = 0; index < (items.length ?? 0); index++) {
      final item = items[index];
      final mimeType = item.type ?? '';
      if (item.kind != 'file' || !mimeType.startsWith('image/')) continue;
      final file = item.getAsFile();
      if (file == null) continue;
      event.preventDefault();
      _handling = true;
      try {
        final reader = html.FileReader()..readAsArrayBuffer(file);
        await reader.onLoad.first;
        final result = reader.result;
        final bytes =
            result is ByteBuffer ? Uint8List.view(result) : result as Uint8List;
        final extension = mimeType == 'image/gif'
            ? 'gif'
            : mimeType == 'image/webp'
                ? 'webp'
                : mimeType == 'image/jpeg'
                    ? 'jpg'
                    : 'png';
        await onImage(
            bytes,
            'clipboard-${DateTime.now().millisecondsSinceEpoch}.$extension',
            mimeType);
      } finally {
        _handling = false;
      }
      return;
    }
  }

  void dispose() {
    html.document.removeEventListener('paste', _listener);
  }
}
