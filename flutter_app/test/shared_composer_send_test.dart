import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:betshuva/shared_composer_send.dart';

void main() {
  test(
      'separate shared message preserves draft selection and edit/reply context',
      () async {
    final controller = TextEditingController.fromValue(const TextEditingValue(
        text: 'טיוטה', selection: TextSelection.collapsed(offset: 2)));
    addTearDown(controller.dispose);
    var editing = true, replying = true;
    await sendSeparateComposerText(controller, 'מיקום משותף',
        canRestore: () => true,
        isolateContext: () {
          editing = false;
          replying = false;
        },
        restoreContext: () {
          editing = true;
          replying = true;
        },
        send: () async {
          expect(editing, isFalse);
          expect(replying, isFalse);
          expect(controller.text, 'מיקום משותף');
          controller.clear();
        });
    expect(controller.text, 'טיוטה');
    expect(controller.selection.baseOffset, 2);
    expect(editing && replying, isTrue);
  });

  test('typing while a share is sent is never overwritten', () async {
    final controller = TextEditingController(text: 'טיוטה');
    addTearDown(controller.dispose);
    var restored = false;
    final gate = Completer<void>();
    final sending = sendSeparateComposerText(controller, 'שיתוף',
        canRestore: () => true,
        isolateContext: () {},
        restoreContext: () => restored = true,
        send: () => gate.future);
    controller.text = 'טקסט חדש';
    gate.complete();
    await sending;
    expect(controller.text, 'טקסט חדש');
    expect(restored, isFalse);
  });

  test('exceptions restore draft; changed or disposed accounts do not',
      () async {
    final controller = TextEditingController(text: 'טיוטה');
    addTearDown(controller.dispose);
    await expectLater(
        sendSeparateComposerText(controller, 'שיתוף',
            canRestore: () => true,
            isolateContext: () {},
            restoreContext: () {},
            send: () async => throw StateError('network')),
        throwsStateError);
    expect(controller.text, 'טיוטה');
    var current = true, restored = false;
    await sendSeparateComposerText(controller, 'שיתוף',
        canRestore: () => current,
        isolateContext: () {},
        restoreContext: () => restored = true,
        send: () async {
          controller.clear();
          current = false;
        });
    expect(restored, isFalse);
    expect(controller.text, isEmpty);
  });
}
