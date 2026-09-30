// Legacy DOM bridge required by the current Flutter web plugin interface.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';
import 'web_chat_attachments_web.dart';
import 'chat_attachment_files.dart';
import 'attachment_read_error.dart';

import 'package:flutter/widgets.dart';
import 'package:file_picker/file_picker.dart';

typedef ClipboardImageCallback = Future<void> Function(
    Uint8List bytes, String fileName, String mimeType);

class ClipboardImagePasteListener {
  final FocusNode focusNode;
  final ClipboardImageCallback onImage;
  final Future<void> Function(List<PlatformFile> files)? onFiles;
  final ValueChanged<int>? onTooManyFiles;
  late final void Function(html.Event) _listener;
  bool _handling = false;
  bool _disposed = false;

  ClipboardImagePasteListener({
    required this.focusNode,
    required this.onImage,
    this.onFiles,
    this.onTooManyFiles,
  }) {
    _listener = _handlePaste;
    html.document.addEventListener('paste', _listener);
  }

  Future<void> _handlePaste(html.Event event) async {
    if (_disposed ||
        !focusNode.hasFocus ||
        _handling ||
        event is! html.ClipboardEvent) {
      return;
    }
    final items = event.clipboardData?.items;
    if (items == null) return;
    final batchSize = List.generate(items.length ?? 0, (index) => items[index])
        .where((item) => item.kind == 'file').length;
    // Reject the whole paste before capturing handles or reading any bytes.
    if (batchSize > maxChatAttachments) {
      event.preventDefault();
      onTooManyFiles?.call(batchSize);
      return;
    }
    final handleFiles = onFiles;
    if (handleFiles != null) {
      final files = <PlatformFile>[];
      for (var index = 0; index < (items.length ?? 0); index++) {
        final item = items[index];
        if (item.kind != 'file') continue;
        final file = item.getAsFile();
        if (file != null) {
          final diagnostics = ClipboardReadDiagnostics(
              batchSize: batchSize, index: files.length);
          files.add(WebChatAttachmentFile.clipboard(file,
                  diagnostics: diagnostics,
                  fallback: clipboardFileFromItem(item, diagnostics: diagnostics)));
        }
      }
      // Text/HTML paste keeps its normal behavior in the message input.
      if (files.isEmpty) return;
      event.preventDefault();
      _handling = true;
      try {
        await handleFiles(files);
      } finally {
        releaseWebChatAttachments(files);
        _handling = false;
      }
      return;
    }
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
        if (_disposed) return;
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

  Future<bool> pasteImage() async => false;

  void dispose() {
    _disposed = true;
    html.document.removeEventListener('paste', _listener);
  }
}
