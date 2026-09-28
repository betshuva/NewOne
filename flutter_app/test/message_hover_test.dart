import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:betshuva/message_hover.dart';

void main() {
  testWidgets('reactions stay left of the object without changing its width',
      (tester) async {
    final reactions = ValueNotifier<bool>(false);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.topRight,
      child: MessageHover(
        actions: const SizedBox(width: 30, height: 30),
        sideReactions: ValueListenableBuilder<bool>(
            valueListenable: reactions,
            builder: (_, visible, __) => visible
                ? const Text('❤️ 2', key: ValueKey('reaction'))
                : const SizedBox.shrink()),
        child: const SizedBox(key: ValueKey('object'), width: 220, height: 150),
      ),
    ))));
    final object = tester.getRect(find.byKey(const ValueKey('object')));
    reactions.value = true;
    await tester.pump();
    final reaction = tester.getRect(find.byKey(const ValueKey('reaction')));
    expect(reaction.right, lessThanOrEqualTo(object.left));
    expect(reaction.top, lessThan(object.bottom));
    expect(tester.getRect(find.byKey(const ValueKey('object'))), object);
    reactions.value = false;
    await tester.pump();
    expect(tester.getRect(find.byKey(const ValueKey('object'))), object);
    await tester.pumpWidget(const SizedBox());
    reactions.dispose();
  });
  testWidgets('hover never resizes an object or moves the next message',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.topRight,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        MessageHover(
            actions: const SizedBox(width: 30, height: 30),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  key: const ValueKey('image'),
                  width: 220,
                  height: 150,
                  color: Colors.blue),
              const MessageDetails(
                  child: SizedBox(
                      width: 220, height: 40, child: Text('file details'))),
            ])),
        const SizedBox(key: ValueKey('next-message'), width: 220, height: 150),
      ]),
    ))));
    final objectRect = tester.getRect(find.byType(MessageHover));
    final imageRect = tester.getRect(find.byKey(const ValueKey('image')));
    final nextRect = tester.getRect(find.byKey(const ValueKey('next-message')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 500));
    for (var i = 0; i < 3; i++) {
      for (final point in [imageRect.center, const Offset(1, 500)]) {
        await mouse.moveTo(point);
        await tester.pump();
        expect(tester.getRect(find.byType(MessageHover)), objectRect);
        expect(tester.getRect(find.byKey(const ValueKey('image'))), imageRect);
        expect(tester.getRect(find.byKey(const ValueKey('next-message'))),
            nextRect);
      }
    }
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });
  testWidgets('details appear on hover and disappear when the pointer leaves',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: MessageHover(
      child: SizedBox(
          width: 200,
          height: 200,
          child: Column(children: [
            Text('12:34'),
            MessageDetails(child: Text('options')),
          ])),
    ))));
    expect(find.text('12:34'), findsOneWidget);
    expect(tester.widget<Visibility>(find.byType(Visibility)).visible, isFalse);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(300, 300));
    await mouse.moveTo(const Offset(100, 100));
    await tester.pump();
    expect(find.text('options'), findsOneWidget);
    await mouse.moveTo(const Offset(300, 300));
    await tester.pump();
    expect(tester.widget<Visibility>(find.byType(Visibility)).visible, isFalse);
    await mouse.removePointer();
    await tester.tapAt(const Offset(100, 100));
    await tester.pump();
    expect(find.text('options'), findsOneWidget);
  });

  testWidgets('details outside messages and generic file labels remain visible',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Column(children: [
      MessageDetails(child: Text('preview actions')),
      MessageHover(
          child: MessageDetails(enabled: false, child: Text('file.zip'))),
    ])));
    expect(find.text('preview actions'), findsOneWidget);
    expect(find.text('file.zip'), findsOneWidget);
  });
}
