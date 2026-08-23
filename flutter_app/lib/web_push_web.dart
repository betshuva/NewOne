// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

Future<String?> getBetshuvaWebPushToken() async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (globalContext.has('betshuvaGetWebPushToken')) {
      final promise = globalContext.callMethod<JSPromise<JSString?>>(
        'betshuvaGetWebPushToken'.toJS,
      );
      final token = await promise.toDart;
      return token?.toDart;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}
