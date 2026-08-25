import 'dart:typed_data';

import 'package:flutter/widgets.dart';

typedef ClipboardImageCallback = Future<void> Function(
    Uint8List bytes, String fileName, String mimeType);

class ClipboardImagePasteListener {
  ClipboardImagePasteListener({
    required FocusNode focusNode,
    required ClipboardImageCallback onImage,
  });

  void dispose() {}
}
