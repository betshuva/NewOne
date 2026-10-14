import 'dart:convert';
import 'package:betshuva/chat_design_settings.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'own_media_filter_test.dart' as fixtures;

void main() {
  for (final group in [false, true]) {
    testWidgets('server design refresh preserves open chat draft group=$group',
        (tester) async {
      fixtures.size(tester);
      SharedPreferences.setMockInitialValues({});
      ChatDesignStore.shared.value = const ChatDesign();
      var changed = false;
      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(group));
        await tester.pumpAndSettle();
        await tester.runAsync(() => ChatDesignStore.shared.ready);
        await tester.pumpAndSettle();
        final field = find.byType(TextField).last;
        await tester.enterText(field, 'טיוטה שנשמרת');
        await tester.pump();
        changed = true;
        await tester.runAsync(() => ChatDesignStore.shared.refresh());
        await tester.pump();
        expect(tester.widget<AppBar>(find.byType(AppBar).first).backgroundColor,
            const Color(0xFF164A73));
        expect(
            tester.widget<TextField>(field).controller!.text, 'טיוטה שנשמרת');
        expect(MediaQuery.textScalerOf(tester.element(field)).scale(20),
            closeTo(22, .001));
        final action = find.byKey(const ValueKey('chat-composer-action'));
        expect((tester.widget<IconButton>(action).icon as Icon).size, 24);
        expect(tester.widget<TextField>(field).style!.fontSize, 15);
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
                        'revision': changed ? 'changed' : 'initial',
                        'settings': changed
                            ? {
                                'accentColor': '#164A73',
                                'messageGap': 2,
                                'textScale': 1.1,
                                'composerIconSize': 24,
                                'composerFontSize': 15,
                                'composerBackground': '#FFFFFF'
                              }
                            : <String, dynamic>{}
                      }),
                      200);
                return fixtures.defaultResponse(r);
              }));
    });
  }
  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets('largest composer settings fit a phone keyboard at $size',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets =
          FakeViewPadding(bottom: size.height > 400 ? 300 : 180);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final settings = {
        'composerMinHeight': 60,
        'composerIconSize': 28,
        'composerActionSize': 56,
        'composerShortcutHeight': 48,
        'composerVerticalPadding': 12,
        'composerFontSize': 18,
        'textScale': 1.25
      };
      ChatDesignStore.shared.value = ChatDesign.parse(
          {'schemaVersion': 1, 'revision': 'large', 'settings': settings})!;
      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(true));
        await tester.pumpAndSettle();
        await tester.runAsync(() => ChatDesignStore.shared.ready);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final action = find.byKey(const ValueKey('chat-composer-action'));
        expect(tester.getRect(action).bottom,
            lessThanOrEqualTo(size.height - tester.view.viewInsets.bottom));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        ChatDesignStore.shared.value = const ChatDesign();
      },
          () => MockClient((r) async {
                if (r.url.path.endsWith('/chat-design'))
                  return http.Response(
                      jsonEncode({
                        'schemaVersion': 1,
                        'revision': 'large',
                        'settings': settings
                      }),
                      200);
                return fixtures.defaultResponse(r);
              }));
    });
  }
}
