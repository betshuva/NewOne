import 'package:betshuva/chat_history_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'search result opens at the selected message before unread messages',
      (tester) async {
    final controller = ChatHistoryController();
    addTearDown(controller.dispose);
    controller.openSearchMessage('target', '2026-01-01T00:00:00Z');
    expect(
        controller.queryParameters, {'historySince': '2026-01-01T00:00:00Z'});
    final messages = [
      {'id': 'target', 'createdAt': '2026-01-01T00:00:00Z'},
      ...List.generate(80, (i) => {'id': '$i', 'isUnread': true}),
    ];
    controller.captureInitialHistory(messages);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChatHistoryList(
      controller: controller,
      itemCount: messages.length,
      anchorIndex: controller.anchorIndex(messages),
      itemBuilder: (_, i) =>
          SizedBox(height: 120, child: Text(messages[i]['id'].toString())),
    ))));
    await tester.pumpAndSettle();
    expect(find.text('target').hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(find.text('target')).dy, closeTo(0, 1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  for (final unread in [true, false]) {
    testWidgets(
        'opens at ${unread ? 'first unread' : 'latest'} with variable heights',
        (tester) async {
      final controller = ChatHistoryController();
      addTearDown(controller.dispose);
      final messages = List.generate(
          120,
          (i) => <String, dynamic>{
                'id': '$i',
                'isUnread': unread && i >= 23,
              });
      controller.captureInitialHistory(messages);
      var expanded = false;
      Widget view() => MaterialApp(
              home: Scaffold(
                  body: ChatHistoryList(
            controller: controller,
            itemCount: messages.length,
            anchorIndex: controller.anchorIndex(messages),
            itemBuilder: (_, i) => SizedBox(
              height: (expanded && i == 22) ? 360 : (i % 3 == 0 ? 150 : 70),
              child: Text('message-$i'),
            ),
          )));
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      final target = find.text(unread ? 'message-23' : 'message-119');
      expect(target.hitTestable(), findsOneWidget);
      if (unread) expect(tester.getTopLeft(target).dy, closeTo(0, 1));
      final openingOffset = controller.offset;
      // A media item above the anchor can change height without moving it.
      expanded = true;
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(target.hitTestable(), findsOneWidget);
      expect(controller.offset, openingOffset);
      for (final message in messages) {
        message['isUnread'] = false;
      }
      expect(controller.captureInitialHistory(messages), isFalse);
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(target.hitTestable(), findsOneWidget);
      if (unread) {
        controller.scrollToLatest();
        await tester.pumpAndSettle();
        expect(target.hitTestable(), findsOneWidget);
      } else {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, 450));
        await tester.pumpAndSettle();
        final readingOffset = controller.offset;
        expect(find.text('message-119').hitTestable(), findsNothing);
        controller.scrollToLatest();
        await tester.pumpAndSettle();
        expect(controller.offset, readingOffset);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
