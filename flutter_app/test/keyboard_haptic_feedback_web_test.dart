@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:betshuva/keyboard_click_sound_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

@JS('Object.defineProperty')
external JSObject _defineProperty(
    JSObject object, JSString name, JSObject descriptor);

@JS('Object.getOwnPropertyDescriptor')
external JSObject? _propertyDescriptor(JSObject object, JSString name);

@JS('Reflect.deleteProperty')
external JSBoolean _deleteProperty(JSObject object, JSString name);

void _withVibrate(JSAny? callback, void Function() operation) {
  final navigator = web.window.navigator;
  final name = 'vibrate'.toJS;
  final original = _propertyDescriptor(navigator, name);
  _defineProperty(
      navigator,
      name,
      {'value': callback, 'configurable': true, 'writable': true}.jsify()!
          as JSObject);
  try {
    operation();
  } finally {
    if (original == null) {
      _deleteProperty(navigator, name);
    } else {
      _defineProperty(navigator, name, original);
    }
  }
}

void main() {
  test('Web typing requests only short vibration and stops after disposal', () {
    final durations = <int>[];
    final callback = ((JSNumber duration) {
      durations.add(duration.toDartInt);
      return true.toJS;
    }).toJS;
    _withVibrate(callback, () {
      final feedback = KeyboardClickSound();
      feedback.click();
      feedback.click();
      expect(durations, [10, 10]);
      feedback.dispose();
      feedback.click();
      expect(durations, [10, 10]);
    });
  });

  test('Web typing stays silent when vibration is unsupported', () {
    _withVibrate(null, () {
      final feedback = KeyboardClickSound();
      expect(feedback.click, returnsNormally);
      feedback.dispose();
      expect(feedback.click, returnsNormally);
      expect(web.window.navigator.getProperty<JSAny?>('vibrate'.toJS), isNull);
    });
  });
}
