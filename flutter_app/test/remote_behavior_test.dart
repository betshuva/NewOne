import 'dart:convert';
import 'package:betshuva/chat_design_settings.dart';
import 'package:betshuva/main.dart';
import 'package:betshuva/remote_card_notice.dart';
import 'package:betshuva/message_options_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'own_media_filter_test.dart' as fixtures;

void main() {
  for (final group in [false, true]) {
    testWidgets(
        'focused tools collapse outside and can be switched remotely group=$group',
        (tester) async {
      fixtures.size(tester);
      SharedPreferences.setMockInitialValues({});
      ChatDesignStore.shared.value = const ChatDesign();
      var settings = <String, dynamic>{};
      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(group));
        await tester.pumpAndSettle();
        await tester.runAsync(() => ChatDesignStore.shared.ready);
        await tester.pumpAndSettle();
        final field = find.byType(TextField).last;
        final emoji = find.byKey(const ValueKey('chat-inline-emoji-shortcut'));
        final tools = find.byKey(const ValueKey('chat-composer-shortcuts'));
        expect(emoji, findsNothing);
        expect(tester.getSize(tools).height, 0);
        await tester.tap(field);
        await tester.pump();
        expect(emoji, findsOneWidget);
        await tester.enterText(field, 'טיוטה');
        await tester.pump();
        await tester.tapAt(const Offset(500, 180));
        await tester.pump();
        expect(emoji, findsNothing);
        expect(tester.getSize(tools).height, 0);
        settings = {'composerToolsVisibility': 'always'};
        await tester.runAsync(() => ChatDesignStore.shared.refresh());
        await tester.pump();
        expect(emoji, findsOneWidget);
        expect(tester.widget<TextField>(field).controller!.text, 'טיוטה');
        settings = {'composerToolsVisibility': 'withText'};
        await tester.runAsync(() => ChatDesignStore.shared.refresh());
        await tester.pump();
        tester.widget<TextField>(field).controller!.clear();
        await tester.pump();
        expect(emoji, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        ChatDesignStore.shared.value = const ChatDesign();
      },
          () => MockClient((r) async {
                if (r.url.path.endsWith('/chat-design'))
                  return http.Response(
                      jsonEncode({
                        'schemaVersion': 1,
                        'revision': settings.toString(),
                        'settings': settings
                      }),
                      200);
                return fixtures.defaultResponse(r);
              }));
    });
  }
  for (final presentation in ['dialog', 'sheet']) {
    testWidgets('compact document keeps metadata in $presentation',
        (tester) async {
      ChatDesignStore.shared.value =
          ChatDesign(values: {'cardDetailsPresentation': presentation});
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: RemoteCardNotice(
                  title: 'המסמך נחסם',
                  details: 'סיבת החסימה',
                  fileName: 'file.pdf',
                  icon: Icons.block,
                  compactSetting: 'compactBlockedMedia'))));
      expect(find.text('file.pdf'), findsNothing);
      await tester.tap(find.text('המסמך נחסם'));
      await tester.pumpAndSettle();
      expect(find.textContaining('file.pdf'), findsOneWidget);
      expect(find.textContaining('סיבת החסימה'), findsOneWidget);
      await tester.tap(find.text('סגור'));
      await tester.pumpAndSettle();
      expect(find.textContaining('סיבת החסימה'), findsNothing);
      expect(tester.takeException(), isNull);
      ChatDesignStore.shared.value = const ChatDesign();
    });
  }
  testWidgets('menu order and presentation remain inside phone viewport',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final mode in ['auto', 'dialog', 'sheet']) {
      ChatDesignStore.shared.value = ChatDesign(values: {
        'messageMenuPresentation': mode,
        'messageMenuOrder': ['העתק', 'ענה']
      });
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (context) => TextButton(
                      onPressed: () => showMessageOptionsMenu(
                              context: context,
                              api: 'https://example.test',
                              token: 'token',
                              message: const {
                                'id': 'message',
                                'status': 'rejected_scan'
                              },
                              items: [
                                for (final label in ['ענה', 'העתק'])
                                  CompactMessageMenuItem(
                                      leading: const Icon(Icons.copy),
                                      title: Text(label),
                                      onTap: () => Navigator.pop(context))
                              ]),
                      child: const Text('פתח'))))));
      await tester.tap(find.text('פתח'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('העתק')).top,
          lessThan(tester.getRect(find.text('ענה')).top));
      final box =
          tester.getRect(find.byKey(const ValueKey('message-options-menu')));
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.bottom, lessThanOrEqualTo(640));
      await tester.tap(find.text('העתק'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    ChatDesignStore.shared.value = const ChatDesign();
  });
}
