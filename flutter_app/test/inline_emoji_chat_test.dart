import 'dart:convert';

import 'package:betshuva/app_screenshot.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _smile = '😀';
const _group = {
  'id': 'emoji-test-group',
  'name': 'קבוצת בדיקה',
  'status': 'member',
  'role': 'member',
  'send_permission': 'all',
};

class _ChatHarness {
  final bool isGroup;
  final requests = <http.Request>[];
  final socket = io.io(
    'http://localhost:1',
    io.OptionBuilder().disableAutoConnect().enableForceNew().build(),
  );

  _ChatHarness({required this.isGroup});

  late final client = MockClient((request) async {
    requests.add(request);
    dynamic body = <String, dynamic>{};
    final path = request.url.path;
    if (request.method == 'POST' && path.endsWith('/messages')) {
      body = {'id': 'emoji-sent-message', 'status': 'sent'};
    } else if (path.endsWith('/expressions/catalog')) {
      body = {'version': 3, 'categories': []};
    } else if (path.endsWith('/groups')) {
      body = [_group];
    } else if (path.endsWith('/groups/emoji-test-group')) {
      body = {
        'members': [
          {'id': 'emoji-test-user', 'name': 'משתמש לבדיקה', 'role': 'member'},
        ],
      };
    } else if (path.contains('/messages/')) {
      body = [];
    } else if (path.endsWith('/messages')) {
      body = [];
    } else if (path.endsWith('/filter-settings')) {
      body = {
        'filter': {'text': true},
        'personalFilter': {'text': true},
        'requiresChoice': false,
      };
    } else if (path.endsWith('/receiving-filter')) {
      body = {
        'filter': {'text': true},
      };
    }
    return http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });

  Finder get composer => find.byWidgetPredicate((widget) =>
      widget is TextField &&
      widget.decoration?.hintText ==
          (isGroup ? 'הודעה לקבוצה...' : 'כתוב הודעה...'));

  TextEditingController controller(WidgetTester tester) =>
      tester.widget<TextField>(composer).controller!;

  List<http.Request> get sentHttpMessages => requests
      .where((request) =>
          request.method == 'POST' && request.url.path.endsWith('/messages'))
      .toList();

  List<Map<String, dynamic>> get sentSocketMessages => socket.sendBuffer
      .whereType<Map>()
      .map((packet) => packet['data'])
      .whereType<List>()
      .where((data) =>
          data.isNotEmpty &&
          const ['chat:message', 'group:message'].contains(data.first))
      .map((data) => Map<String, dynamic>.from(data[1] as Map))
      .toList();

  void expectNoMediaUpload() {
    expect(requests.where((request) => request.url.path.contains('upload')),
        isEmpty);
  }

  void expectNothingSent() {
    expect(sentHttpMessages, isEmpty);
    expect(sentSocketMessages, isEmpty);
    expectNoMediaUpload();
  }

  void expectOneTextMessage(String text) {
    final Map<String, dynamic> message;
    if (isGroup) {
      expect(sentHttpMessages, isEmpty);
      expect(sentSocketMessages, hasLength(1));
      message = sentSocketMessages.single;
      expect(message['groupId'], _group['id']);
    } else {
      expect(sentSocketMessages, isEmpty);
      expect(sentHttpMessages, hasLength(1));
      message =
          jsonDecode(sentHttpMessages.single.body) as Map<String, dynamic>;
      expect(message['toUserId'], 'emoji-test-recipient');
    }
    expect(message['text'], text);
    expect(message.containsKey('stickerId'), isFalse);
    expect(message.containsKey('fileUrl'), isFalse);
    expectNoMediaUpload();
  }

  Future<void> mount(WidgetTester tester) async {
    final previousDestination = appScreenshotDestination.value;
    addTearDown(() {
      socket.dispose();
      client.close();
      appScreenshotDestination.value = previousDestination;
    });
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: isGroup
            ? GroupChatScreen(
                token: 'emoji-test-token',
                me: const {'id': 'emoji-test-user', 'name': 'משתמש לבדיקה'},
                group: Map<String, dynamic>.from(_group),
                socket: socket,
                embedded: true,
              )
            : ChatScreen(
                token: 'emoji-test-token',
                me: const {'id': 'emoji-test-user', 'name': 'משתמש לבדיקה'},
                recipient: const {
                  'id': 'emoji-test-recipient',
                  'name': 'חבר לבדיקה',
                },
                socket: socket,
                embedded: true,
              ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(composer, findsOneWidget);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }
}

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byTooltip('אימוג׳י ומדבקות'));
  await tester.pumpAndSettle();
  expect(find.text('אימוג׳י'), findsOneWidget);
  expect(find.text('מדבקות'), findsOneWidget);
}

Future<void> _chooseSmile(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('inline-emoji-1f600')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final isGroup in [false, true]) {
    final chatKind = isGroup ? 'group' : 'private';

    testWidgets('$chatKind emoji joins the draft and waits for explicit send',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, 'שלום חבר');
        await _openPicker(tester);
        app.expectNothingSent();
        expect(
            app.requests.where(
                (request) => request.url.path.endsWith('/expressions/catalog')),
            isEmpty,
            reason:
                'Unicode emoji must work without a sticker catalog request');
        await _chooseSmile(tester);

        expect(app.controller(tester).text, 'שלום חבר$_smile');
        app.expectNothingSent();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();

        app.expectOneTextMessage('שלום חבר$_smile');
        expect(app.controller(tester).text, isEmpty);
        expect(find.text('שלום חבר$_smile'), findsOneWidget);
        await app.dispose(tester);
      }, () => app.client);
    });

    for (final replaceSelection in [false, true]) {
      testWidgets(
          '$chatKind emoji ${replaceSelection ? 'replaces selected text' : 'inserts at the saved cursor'} after picker focus',
          (tester) async {
        final app = _ChatHarness(isGroup: isGroup);
        await http.runWithClient(() async {
          await app.mount(tester);
          const draft = 'שלום חבר יקר';
          await tester.enterText(app.composer, draft);
          final controller = app.controller(tester);
          controller.selection = TextSelection(
              baseOffset: 5, extentOffset: replaceSelection ? 8 : 5);
          await tester.pump();
          await _openPicker(tester);

          // The picker takes focus away from the composer. The replacement
          // must still use the user's selection from before it was opened.
          final search = find.descendant(
              of: find.byType(BottomSheet), matching: find.byType(TextField));
          expect(search, findsOneWidget);
          await tester.enterText(search, 'חיוך');
          await tester.pumpAndSettle();
          await _chooseSmile(tester);

          final expected =
              replaceSelection ? 'שלום $_smile יקר' : 'שלום $_smileחבר יקר';
          expect(controller.text, expected);
          expect(controller.selection,
              TextSelection.collapsed(offset: 5 + _smile.length));
          expect(tester.widget<TextField>(app.composer).focusNode!.hasFocus,
              isTrue);
          app.expectNothingSent();

          await tester.tap(find.byIcon(Icons.send));
          await tester.pumpAndSettle();
          app.expectOneTextMessage(expected);
          await app.dispose(tester);
        }, () => app.client);
      });
    }

    testWidgets('$chatKind emoji-only message retains normal text size',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _openPicker(tester);
        await _chooseSmile(tester);
        expect(app.controller(tester).text, _smile);
        app.expectNothingSent();

        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();

        app.expectOneTextMessage(_smile);
        final message = tester.widget<Text>(find.text(_smile));
        expect(message.style?.fontSize, isGroup ? 15 : 14);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$chatKind keeps stickers available in a separate tab',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, 'טיוטה שנשמרת');
        await _openPicker(tester);
        await tester.tap(find.text('מדבקות'));
        await tester.pumpAndSettle();

        expect(
            app.requests.where(
                (request) => request.url.path.endsWith('/expressions/catalog')),
            hasLength(1));
        expect(find.text('לא נמצאו מדבקות'), findsOneWidget);
        app.expectNothingSent();

        await tester.tap(find.text('אימוג׳י'));
        await tester.pumpAndSettle();
        await _chooseSmile(tester);
        expect(app.controller(tester).text, 'טיוטה שנשמרת$_smile');
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });
  }
}
