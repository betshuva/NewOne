import 'dart:convert';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      'desktop search opens the selected message through the conversation pane',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final selected = <String>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: ConversationsScreen(
        users: const [],
        token: 'token',
        me: const {'id': 'me', 'name': 'אני'},
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
        onFilterChanged: (_) {},
        onSearchMessageSelected: (item, group, message) {
          expect(item['id'], 'conversation-${message['kind']}');
          expect(group, message['kind'] == 'group');
          selected.add(message['id'].toString());
        },
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.search).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'result');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      for (final kind in ['personal', 'group']) {
        await tester.tap(find.text('result-$kind'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(ChatScreen), findsNothing);
        expect(find.byType(GroupChatScreen), findsNothing);
        expect(find.text('result-$kind'), findsOneWidget);
      }
      expect(selected, ['message-personal', 'message-group']);
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((request) async => http.Response(
            jsonEncode(request.url.path.endsWith('/conversations/search')
                ? {
                    'messages': [
                      for (final kind in ['personal', 'group'])
                        {
                          'id': 'message-$kind',
                          'kind': kind,
                          'conversation_id': 'conversation-$kind',
                          'conversation_name': 'result-$kind',
                          'body': 'result',
                          'created_at': '2026-09-30T10:00:00Z',
                        }
                    ],
                    'nextCursor': null
                  }
                : []),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
  });
}
