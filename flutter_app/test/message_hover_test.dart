import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:betshuva/message_hover.dart';

void main() {
  testWidgets('reactions sit at the right bottom without changing object width',
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
                ? const SizedBox(
                    key: ValueKey('reaction'), width: 32, height: 32)
                : const SizedBox.shrink()),
        child: const SizedBox(key: ValueKey('object'), width: 220, height: 150),
      ),
    ))));
    final object = tester.getRect(find.byKey(const ValueKey('object')));
    reactions.value = true;
    await tester.pump();
    final reaction = tester.getRect(find.byKey(const ValueKey('reaction')));
    expect(reaction.right, closeTo(object.right, 0.001));
    expect(reaction.top, closeTo(object.bottom - 14, 0.001));
    expect(reaction.bottom, closeTo(object.bottom + 18, 0.001));
    expect(tester.getRect(find.byKey(const ValueKey('object'))), object);
    reactions.value = false;
    await tester.pump();
    expect(tester.getRect(find.byKey(const ValueKey('object'))), object);
    await tester.pumpWidget(const SizedBox());
    reactions.dispose();
  });

  for (final direction in [TextDirection.rtl, TextDirection.ltr]) {
    testWidgets('corner hit target and glyph fit the media in $direction',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Directionality(
        textDirection: direction,
        child: Align(
          alignment: Alignment.topRight,
          child: MessageHover(
            key: const ValueKey('hover'),
            reactionsOnChild: true,
            actions:
                const SizedBox(key: ValueKey('actions'), width: 30, height: 30),
            sideReactions: GestureDetector(
              key: const ValueKey('hit-target'),
              behavior: HitTestBehavior.opaque,
              onTap: () => taps++,
              child: const SizedBox(
                  width: 32,
                  height: 32,
                  child: Center(
                      child: SizedBox(
                          key: ValueKey('glyph'), width: 20, height: 20))),
            ),
            child: const Column(mainAxisSize: MainAxisSize.min, children: [
              MessageObjectReactions(
                  child: SizedBox(
                      key: ValueKey('media'), width: 220, height: 150)),
              SizedBox(key: ValueKey('caption'), width: 220, height: 40),
            ]),
          ),
        ),
      ))));
      final media = tester.getRect(find.byKey(const ValueKey('media')));
      final hit = tester.getRect(find.byKey(const ValueKey('hit-target')));
      final glyph = tester.getRect(find.byKey(const ValueKey('glyph')));
      final hover = tester.getRect(find.byKey(const ValueKey('hover')));
      final caption = tester.getRect(find.byKey(const ValueKey('caption')));
      expect(hit.size, const Size(32, 32));
      expect(hit.right, closeTo(media.right, 0.001));
      expect(glyph.right, closeTo(media.right - 6, 0.001));
      expect(glyph.top, closeTo(media.bottom - 8, 0.001));
      expect(hit.bottom, closeTo(media.bottom + 18, 0.001));
      expect(caption.top, closeTo(hit.bottom, 0.001));
      expect(hover.contains(hit.bottomRight - const Offset(1, 1)), isTrue);
      expect(tester.getSize(find.byKey(const ValueKey('actions'))).width, 30);
      await tester.tapAt(Offset(hit.center.dx, media.bottom + 15));
      await tester.pump();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('wrapped reaction rows grow below a narrow object',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Align(
      alignment: Alignment.topRight,
      child: MessageHover(
        key: const ValueKey('narrow-hover'),
        sideReactions: Wrap(
            spacing: 4,
            runSpacing: 2,
            textDirection: TextDirection.rtl,
            children: [
              for (var i = 0; i < 6; i++)
                SizedBox(key: ValueKey('reaction-$i'), width: 32, height: 32),
            ]),
        child: const SizedBox(
            key: ValueKey('narrow-object'), width: 70, height: 100),
      ),
    ))));
    final object = tester.getRect(find.byKey(const ValueKey('narrow-object')));
    final hover = tester.getRect(find.byKey(const ValueKey('narrow-hover')));
    final first = tester.getRect(find.byKey(const ValueKey('reaction-0')));
    final third = tester.getRect(find.byKey(const ValueKey('reaction-2')));
    expect(first.top, closeTo(object.bottom - 14, 0.001));
    expect(third.top, greaterThan(object.bottom));
    expect(hover.width, object.width);
    for (var i = 0; i < 6; i++) {
      final rect = tester.getRect(find.byKey(ValueKey('reaction-$i')));
      expect(rect.left, greaterThanOrEqualTo(hover.left));
      expect(rect.right, lessThanOrEqualTo(hover.right));
      expect(rect.bottom, lessThanOrEqualTo(hover.bottom));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('media wrapper has no layout effect outside a reaction scope',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Align(
            alignment: Alignment.topRight,
            child: MessageObjectReactions(
                child: SizedBox(width: 220, height: 150)))));
    expect(tester.getSize(find.byType(MessageObjectReactions)),
        const Size(220, 150));
    expect(tester.takeException(), isNull);
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
