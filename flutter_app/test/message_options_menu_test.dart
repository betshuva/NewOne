import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:betshuva/message_action_bar.dart';
import 'package:betshuva/message_options_menu.dart';
import 'package:betshuva/message_hover.dart';
import 'package:betshuva/message_reactions.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

late String _bundledCatalog;

class _LibraryBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == 'assets/stickers/user-catalog.json') {
      return ByteData.sublistView(
          Uint8List.fromList(utf8.encode(_bundledCatalog)));
    }
    return rootBundle.load(key);
  }
}

void main() {
  setUpAll(() async {
    _bundledCatalog =
        await rootBundle.loadString('assets/stickers/user-catalog.json');
  });
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
        expect(find.byTooltip('תגובה ❤️'), findsOneWidget);
        expect(find.byIcon(Icons.add), findsOneWidget);
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
      'six quick reactions and plus fit one row; library cancel does not write',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) =>
              DefaultAssetBundle(bundle: _LibraryBundle(), child: child!),
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
      expect(find.byTooltip('כל האימוג׳י'), findsOneWidget);
      final row = tester
          .getRect(find.byKey(const ValueKey('message-reaction-quick-row')));
      final plus =
          tester.getRect(find.byKey(const ValueKey('message-reaction-more')));
      expect(row.width, lessThanOrEqualTo(246));
      expect(plus.left, greaterThanOrEqualTo(0));
      for (final emoji in messageReactionEmoji) {
        expect(find.byTooltip('תגובה $emoji'), findsOneWidget);
        final choice = tester
            .getRect(find.byKey(ValueKey('select-message-reaction-$emoji')));
        expect(choice.center.dy, closeTo(plus.center.dy, .1));
        expect(choice.left, greaterThan(plus.right));
        expect(choice.right, lessThanOrEqualTo(390));
      }
      final rowKeys = [
        'message-reaction-more',
        ...['🙏', '😢', '😮', '😂', '❤️', '👍']
            .map((emoji) => 'select-message-reaction-$emoji'),
      ];
      for (var index = 0; index < rowKeys.length - 1; index++) {
        final first = tester.getRect(find.byKey(ValueKey(rowKeys[index])));
        final next = tester.getRect(find.byKey(ValueKey(rowKeys[index + 1])));
        expect(first.right, lessThan(next.left));
      }
      final thumb = find.byKey(const ValueKey('select-message-reaction-👍'));
      final glyph = tester.widget<SvgPicture>(
          find.descendant(of: thumb, matching: find.byType(SvgPicture)));
      expect(glyph.width, 24);
      expect(glyph.height, 24);
      expect(requests.where((request) => request.method == 'PUT'), isEmpty);
      await tester.tap(find.byTooltip('כל האימוג׳י'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-reaction-library')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('reaction-library-emoji-001')),
          findsOneWidget);
      expect(requests.where((request) => request.method == 'PUT'), isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('כל האימוג׳י'), findsOneWidget);
      expect(
          find.byKey(const ValueKey('message-reaction-library')), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byTooltip('כל האימוג׳י'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(requests, isEmpty);
    },
        () => MockClient((request) async {
              requests.add(request);
              return http.Response('[]', 200);
            }));
  });

  testWidgets('library selection closes both routes before caller-owned write',
      (tester) async {
    final response = Completer<http.Response>();
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) =>
              DefaultAssetBundle(bundle: _LibraryBundle(), child: child!),
          home: Scaffold(
              body: Builder(
            builder: (context) => TextButton(
                onPressed: () => showMessageOptionsMenu(
                        context: context,
                        api: 'https://test/api',
                        token: 'library-reaction-menu',
                        message: const {
                          'id': '00000000-0000-4000-8000-000000000151'
                        },
                        items: const []),
                child: const Text('open')),
          ))));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('כל האימוג׳י'));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester
          .tap(find.byKey(const ValueKey('reaction-library-emoji-001')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('message-reaction-library')), findsNothing);
      expect(find.byKey(const ValueKey('message-options-menu')), findsNothing);
      expect(response.isCompleted, isFalse);
      final writes =
          requests.where((request) => request.method == 'PUT').toList();
      expect(writes, hasLength(1));
      expect(jsonDecode(writes.single.body), {'emoji': '[[bt-emoji:001]]'});
      response.complete(http.Response(
          '[{"emoji":"[[bt-emoji:001]]","count":1,"mine":true}]', 200));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.method == 'PUT') return response.future;
              return http.Response('[]', 200);
            }));
  });
}
