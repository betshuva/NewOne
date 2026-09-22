import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

Future<String?> copyImageToClipboard(String imageUrl) async {
  try {
    final response = await http
        .get(Uri.parse(imageUrl))
        .timeout(const Duration(seconds: 30));
    final mime = response.headers['content-type']?.split(';').first ?? '';
    if (response.statusCode != 200 ||
        !mime.startsWith('image/') ||
        response.bodyBytes.isEmpty ||
        response.bodyBytes.length > 50 * 1024 * 1024) {
      return 'לא ניתן להעתיק את התמונה';
    }
    final copied = await const MethodChannel('com.betshuva.app/media')
        .invokeMethod<bool>('copyImage', {
      'bytes': response.bodyBytes,
      'mimeType': mime,
    });
    return copied == true ? null : 'לא ניתן להעתיק את התמונה';
  } catch (_) {
    return 'לא ניתן להעתיק את התמונה. נסה שוב';
  }
}
