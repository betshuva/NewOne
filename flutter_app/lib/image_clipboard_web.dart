import 'dart:js_interop';

@JS('betshuvaCopyImage')
external JSPromise<JSString> _copyImage(JSString imageUrl);

Future<String?> copyImageToClipboard(String imageUrl) async {
  try {
    final result = (await _copyImage(imageUrl.toJS).toDart).toDart;
    return result.isEmpty ? null : result;
  } catch (_) {
    return 'לא ניתן להעתיק את התמונה. נסה לפתוח אותה שוב';
  }
}
