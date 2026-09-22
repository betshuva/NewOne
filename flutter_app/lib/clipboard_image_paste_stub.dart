import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

typedef ClipboardImageCallback = Future<void> Function(
    Uint8List bytes, String fileName, String mimeType);

class ClipboardImagePasteListener {
  final ClipboardImageCallback onImage;
  bool _disposed = false;
  bool _handling = false;
  ClipboardImagePasteListener({
    required FocusNode focusNode,
    required this.onImage,
  });

  Future<bool> pasteImage() async {
    if (_disposed || _handling) return false;
    _handling = true;
    try {
      final image = await const MethodChannel('com.betshuva.app/media')
          .invokeMapMethod<String, dynamic>('pasteImage');
      if (_disposed || image == null) return false;
      final bytes = image['bytes'];
      final mime = image['mimeType'];
      final name = image['fileName'];
      if (bytes is! Uint8List ||
          bytes.isEmpty ||
          mime is! String ||
          !mime.startsWith('image/') ||
          name is! String) {
        return false;
      }
      await onImage(bytes, name, mime);
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } finally {
      _handling = false;
    }
  }

  void dispose() {
    _disposed = true;
  }
}
