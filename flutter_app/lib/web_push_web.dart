// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:js_util' as js_util;

Future<String?> getBetshuvaWebPushToken() async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (js_util.hasProperty(html.window, 'betshuvaGetWebPushToken')) {
      final promise = js_util.callMethod<Object?>(
          html.window, 'betshuvaGetWebPushToken', const []);
      final token = await js_util.promiseToFuture<Object?>(promise!);
      return token?.toString();
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}
