import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:betshuva/message_hover.dart';

void main() {
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
    expect(find.text('options'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(300, 300));
    await mouse.moveTo(const Offset(100, 100));
    await tester.pump();
    expect(find.text('options'), findsOneWidget);
    await mouse.moveTo(const Offset(300, 300));
    await tester.pump();
    expect(find.text('options'), findsNothing);
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
