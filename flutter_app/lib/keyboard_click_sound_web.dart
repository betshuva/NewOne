import 'dart:js_interop';

import 'package:web/web.dart' as web;

class KeyboardClickSound {
  bool _disposed = false;

  void click() {
    if (_disposed) return;
    try {
      web.window.navigator.vibrate(10.toJS);
    } catch (_) {
      // Browsers without vibration support keep typing silent.
    }
  }

  void dispose() {
    _disposed = true;
  }
}
