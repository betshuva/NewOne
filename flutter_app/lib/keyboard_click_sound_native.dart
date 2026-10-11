import 'package:flutter/services.dart';

class KeyboardClickSound {
  bool _disposed = false;
  bool _vibrating = false;

  void click() {
    if (_disposed || _vibrating) return;
    _vibrate();
  }

  Future<void> _vibrate() async {
    _vibrating = true;
    try {
      await HapticFeedback.selectionClick();
    } catch (_) {
      // Devices without vibration support keep typing silent.
    } finally {
      _vibrating = false;
    }
  }

  void dispose() {
    _disposed = true;
  }
}
