import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

Future<String?> readWebOtp() async {
  try {
    final credentials =
        web.window.navigator.getProperty<JSObject?>('credentials'.toJS);
    if (credentials == null) return null;
    final options = {
      'otp': {
        'transport': ['sms']
      }
    }.jsify() as JSObject;
    final promise =
        credentials.callMethod<JSPromise<JSAny?>>('get'.toJS, options);
    final result = await promise.toDart;
    if (result == null) return null;
    final code =
        (result as JSObject).getProperty<JSString?>('code'.toJS)?.toDart;
    return code != null && RegExp(r'^\d{6}$').hasMatch(code) ? code : null;
  } catch (_) {
    return null;
  }
}
