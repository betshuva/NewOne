import 'package:flutter/services.dart';

const maxKeyboardInsertedImageBytes = 10 * 1024 * 1024;
const keyboardInsertedImageMimeTypes = <String>[
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
];

class KeyboardInsertedImageException implements Exception {
  const KeyboardInsertedImageException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class KeyboardInsertedImage {
  const KeyboardInsertedImage({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
  });

  final Uint8List bytes;
  final String mimeType;
  final String fileName;
}

/// Keyboard URIs have temporary permissions. Use only bytes already read by
/// Flutter; never fetch an arbitrary URI or read unrelated clipboard content.
KeyboardInsertedImage parseKeyboardInsertedImage(
    KeyboardInsertedContent content) {
  final bytes = content.data;
  if (bytes == null) {
    throw const KeyboardInsertedImageException('missing_data',
        'לא ניתן לקרוא את התמונה מהמקלדת. אפשר להדביק אותה או לצרף קובץ.');
  }
  if (bytes.isEmpty) {
    throw const KeyboardInsertedImageException('empty_data',
        'התמונה מהמקלדת ריקה. אפשר לבחור תמונה אחרת או לצרף קובץ.');
  }
  if (bytes.length > maxKeyboardInsertedImageBytes) {
    throw const KeyboardInsertedImageException(
        'too_large', 'התמונה מהמקלדת גדולה מדי. ניתן לשלוח תמונה עד 10MB.');
  }

  final mimeType = content.mimeType.toLowerCase();
  final extension = switch (mimeType) {
    'image/png' => 'png',
    'image/jpeg' => 'jpg',
    'image/webp' => 'webp',
    'image/gif' => 'gif',
    _ => null,
  };
  if (extension == null) {
    throw const KeyboardInsertedImageException('unsupported_type',
        'סוג התמונה מהמקלדת אינו נתמך. אפשר לשלוח PNG, JPEG, WebP או GIF.');
  }

  final matchesSignature = switch (mimeType) {
    'image/png' => _startsWith(bytes, [137, 80, 78, 71, 13, 10, 26, 10]),
    'image/jpeg' => _startsWith(bytes, [255, 216, 255]),
    'image/gif' => _startsWith(bytes, [71, 73, 70, 56, 55, 97]) ||
        _startsWith(bytes, [71, 73, 70, 56, 57, 97]),
    'image/webp' => _startsWith(bytes, [82, 73, 70, 70]) &&
        _startsWith(bytes, [87, 69, 66, 80], offset: 8),
    _ => false,
  };
  if (!matchesSignature) {
    throw const KeyboardInsertedImageException('mismatch',
        'לא ניתן לזהות את התמונה מהמקלדת או שהסוג שלה שגוי. אפשר לצרף את הקובץ מחדש.');
  }

  // Actual image decoding and moderation remain authoritative on the server.
  return KeyboardInsertedImage(
    bytes: bytes,
    mimeType: mimeType,
    fileName: 'keyboard-image.$extension',
  );
}

bool _startsWith(Uint8List bytes, List<int> signature, {int offset = 0}) {
  if (bytes.length < offset + signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[offset + index] != signature[index]) return false;
  }
  return true;
}
