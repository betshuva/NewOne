import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('NotoSansHebrew')
          ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf')))
        .load();
  });
  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets('conversation header fits a phone at text scale $scale',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSansHebrew'),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: ConversationsScreen(
              users: const [],
              token: 'token',
              me: const {'id': 'me', 'name': 'שם משתמש ארוך לבדיקת כותרת'},
              socket: null,
              unreadCounts: const {},
              groupUnreadCounts: const {},
              groupTypingNames: const {},
              typingUserIds: const {},
              onChatOpened: (_) {},
              onLogout: () async {},
              onSettings: () {},
              onContactsChanged: () async {},
              onVoiceCall: (_) {},
              currentMainNavigationIndex: 0,
              onMainNavigationSelected: (_) {},
              onFilterChanged: (_) {}),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('בתשובה'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }, () => MockClient((_) async => http.Response('[]', 200)));
    });
  }
}
