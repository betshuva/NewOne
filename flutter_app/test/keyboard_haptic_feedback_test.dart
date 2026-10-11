@TestOn('vm')
library;

import 'package:betshuva/keyboard_click_sound_native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('typing uses vibration and stops after disposal', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final feedback = KeyboardClickSound();
    feedback.click();
    feedback.click();
    await tester.pump();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'HapticFeedback.vibrate');
    expect(calls.single.arguments, 'HapticFeedbackType.selectionClick');
    feedback.click();
    await tester.pump();
    expect(calls, hasLength(2));
    feedback.dispose();
    feedback.click();
    await tester.pump();
    expect(calls, hasLength(2));
  });
}
