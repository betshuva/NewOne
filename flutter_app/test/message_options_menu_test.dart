import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:betshuva/message_action_bar.dart';
import 'package:betshuva/message_options_menu.dart';
import 'package:betshuva/message_hover.dart';
import 'package:betshuva/message_reactions.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  for (final fail in [false, true]) {
    testWidgets('emoji closes menu before response and handles failure=$fail',
        (tester) async {
      final id = '00000000-0000-4000-8000-00000000090${fail ? 2 : 1}';
      final response = Completer<http.Response>();
      final writes = <dynamic>[];
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: Builder(
          builder: (context) => Column(children: [
            TextButton(
                onPressed: () => showMessageOptionsMenu(
                    context: context,
                    api: 'https://test/api',
                    token: 'close-menu',
                    message: {'id': id},
                    items: const []),
                child: const Text('open')),
            MessageReactions(
                api: 'https://test/api',
                token: 'close-menu',
                messageId: id,
                showAddButton: false),
          ]),
        ))));
        await tester.pumpAndSettle();
        expect(find.text('👍'), findsOneWidget);
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(
            find.descendant(
                of: find.byKey(const ValueKey('message-options-menu')),
                matching: find.byType(ActionChip)),
            findsNothing);
        expect(find.byTooltip('תגובה ❤️'), findsNothing);
        expect(find.byIcon(Icons.add_reaction_outlined), findsOneWidget);
        expect(writes, isEmpty);
        await tester.tap(find.byTooltip('הוספת תגובה'));
        await tester.pumpAndSettle();
        expect(writes, isEmpty);
        await tester
            .tap(find.byKey(const ValueKey('select-message-reaction-❤️')));
        await tester.pumpAndSettle();
        expect(
            find.byKey(const ValueKey('message-options-menu')), findsNothing);
        expect(response.isCompleted, isFalse);
        expect(writes, ['❤️']);
        response.complete(http.Response(
            fail
                ? '{}'
                : jsonEncode([
                    {'emoji': '❤️', 'count': 1, 'mine': true}
                  ]),
            fail ? 500 : 200,
            headers: {'content-type': 'application/json; charset=utf-8'}));
        await tester.pumpAndSettle();
        if (fail) {
          expect(find.text('👍'), findsOneWidget);
          expect(find.text('לא ניתן לעדכן את התגובה כרגע'), findsOneWidget);
        } else {
          expect(find.text('❤️'), findsOneWidget);
          expect(find.text('👍'), findsNothing);
        }
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
          () => MockClient((request) async {
                if (request.method == 'PUT') {
                  writes.add(jsonDecode(request.body)['emoji']);
                  return response.future;
                }
                return http.Response(
                    jsonEncode([
                      {'emoji': '👍', 'count': 1, 'mine': true}
                    ]),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8'
                    });
              }));
    });
  }
  testWidgets('menu uses the object left edge without moving the object',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
      builder: (context) => Align(
        alignment: Alignment.centerRight,
        child: MessageHover(
          actions: MessageActionBar(
            api: 'https://test/api',
            token: 'token',
            message: const {'id': 'temp_1'},
            onOptions: (anchor) => showMessageOptionsMenu(
              context: context,
              anchorContext: anchor,
              api: 'https://test/api',
              token: 'token',
              message: const {'id': 'temp_1'},
              items: [
                CompactMessageMenuItem(
                    leading: const Icon(Icons.reply),
                    title: const Text('reply'),
                    onTap: () => Navigator.pop(context))
              ],
            ),
          ),
          child:
              const SizedBox(key: ValueKey('object'), width: 220, height: 150),
        ),
      ),
    ))));
    final object = tester.getRect(find.byKey(const ValueKey('object')));
    await tester.tap(find.byTooltip('אפשרויות הודעה'));
    await tester.pumpAndSettle();
    final menu =
        tester.getRect(find.byKey(const ValueKey('message-options-menu')));
    expect(menu.right, closeTo(object.left - 4, .1));
    expect(menu.top, object.top);
    expect(tester.getRect(find.byKey(const ValueKey('object'))), object);
    await tester.tap(find.text('reply'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('object'))), object);
  });
  for (final alignment in [Alignment.topRight, Alignment.bottomLeft]) {
    testWidgets('menu stays beside its button at $alignment', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var selected = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => SafeArea(
            child: Align(
          alignment: alignment,
          child: MessageActionBar(
            api: 'https://test/api',
            token: 'token',
            message: const {'id': 'temp_1'},
            onOptions: (anchor) => showMessageOptionsMenu(
              context: context,
              anchorContext: anchor,
              api: 'https://test/api',
              token: 'token',
              message: const {'id': 'temp_1'},
              items: [
                CompactMessageMenuItem(
                  leading: const Icon(Icons.reply),
                  title: const Text('ענה'),
                  onTap: () {
                    Navigator.pop(context);
                    selected++;
                  },
                )
              ],
            ),
          ),
        )),
      ))));
      final button = find.byTooltip('אפשרויות הודעה');
      final anchor = tester.getRect(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      final menu =
          tester.getRect(find.byKey(const ValueKey('message-options-menu')));
      expect(menu.width, lessThanOrEqualTo(208));
      expect(menu.left, greaterThanOrEqualTo(0));
      expect(menu.right, lessThanOrEqualTo(390));
      expect(menu.top, greaterThanOrEqualTo(0));
      expect(menu.bottom, lessThanOrEqualTo(844));
      if (alignment == Alignment.topRight) {
        expect(menu.right, closeTo(anchor.left - 4, .1));
        expect(menu.top, closeTo(6, .1));
      } else {
        expect(menu.left, closeTo(6, .1));
        expect(menu.bottom, lessThanOrEqualTo(838));
      }
      await tester.tap(find.text('ענה'));
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(button, findsOneWidget);
      expect(find.text('ענה'), findsNothing);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('ענה'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'menu exposes reactions only through plus and cancels without writes',
      (tester) async {
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => Center(
            child: TextButton(
                onPressed: () {
                  showMessageOptionsMenu(
                    context: context,
                    api: 'https://test/api',
                    token: 'token',
                    message: const {
                      'id': '00000000-0000-4000-8000-000000000123'
                    },
                    items: const [],
                  );
                },
                child: const Text('open'))),
      ))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('הוספת תגובה'), findsOneWidget);
      for (final emoji in messageReactionEmoji) {
        expect(find.byTooltip('תגובה $emoji'), findsNothing);
        expect(find.byKey(ValueKey('select-message-reaction-$emoji')),
            findsNothing);
      }
      expect(requests.where((request) => request.method == 'PUT'), isEmpty);
      await tester.tap(find.byTooltip('הוספת תגובה'));
      await tester.pumpAndSettle();
      for (final emoji in messageReactionEmoji) {
        expect(find.byKey(ValueKey('select-message-reaction-$emoji')),
            findsOneWidget);
      }
      expect(requests.where((request) => request.method == 'PUT'), isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('הוספת תגובה'), findsOneWidget);
      expect(find.byKey(const ValueKey('select-message-reaction-👍')),
          findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byTooltip('הוספת תגובה'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.url.path,
          '/api/messages/00000000-0000-4000-8000-000000000123/reactions');
    },
        () => MockClient((request) async {
              requests.add(request);
              return http.Response('[]', 200);
            }));
  });
}
