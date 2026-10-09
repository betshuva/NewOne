import 'dart:convert';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final editFilter in [false, true]) {
    testWidgets('friend approval preserves locked filters; editing=$editFilter', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var pending = true, unlocked = false;
      final events = <String>[];
      final accepts = <Map<String, dynamic>>[];
      final filter = {'text': true, 'nonHumanImages': true, 'men': false, 'women': false, 'children': true, 'video': true};
      http.Response json(Object value) => http.Response(jsonEncode(value), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      final client = MockClient((r) async {
        final path = r.url.path;
        if (path.endsWith('/filter-pin/unlock')) unlocked = true;
        if (path.endsWith('/filter-pin/leave')) {events.add('leave'); unlocked = false;}
        if (path.contains('/filter-pin')) return json({'configured': true, 'unlocked': unlocked});
        if (path.endsWith('/accept')) {
          events.add('accept'); accepts.add(Map<String,dynamic>.from(jsonDecode(r.body)));
          if (editFilter) expect(unlocked, true);
          pending = false;
          return json({'ok': true, 'messageIds': [], 'rejected': []});
        }
        if (path.endsWith('/registration-status')) return json({'birthDateMissing': false});
        if (path.endsWith('/profile')) return json({'id': 'me', 'name': 'אני'});
        if (path.endsWith('/message-requests')) return json(pending ? [{'id': 'request', 'sender_id': 'friend', 'sender_name': 'חבר בדיקה', 'my_filter': filter, 'expected_filter': filter}] : []);
        if (path.endsWith('/users')) return json([{'id': 'friend', 'name': 'חבר בדיקה'}]);
        if (path.endsWith('/groups') || path.contains('/messages')) return json([]);
        return json({});
      });
      await http.runWithClient(() async {
        try {
          await tester.pumpWidget(const MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: MainShell(token: 'test-token'))));
          await tester.pumpAndSettle();
          tester.widget<ConversationsScreen>(find.byType(ConversationsScreen)).socket?.disconnect();
          expect(find.text('בקשת חברות מאת חבר בדיקה'), findsOneWidget);
          expect(find.byIcon(Icons.lock_outline), findsOneWidget);
          final checkbox = find.widgetWithText(InkWell, 'חסום').first;
          final initialChecks = find.byIcon(Icons.check).evaluate().length;
          await tester.tap(checkbox, warnIfMissed: false);
          await tester.pump();
          expect(find.byIcon(Icons.check).evaluate().length, initialChecks);
          if (editFilter) {
            await tester.tap(find.byKey(const ValueKey('filter-pin-lock'))); await tester.pumpAndSettle();
            for (final digit in '1234'.split('')) {
              final key = find.byKey(ValueKey('filter-pin-key-$digit'));
              await tester.ensureVisible(key); await tester.tap(key); await tester.pump();
            }
            final ok = find.widgetWithText(FilledButton, 'אישור');
            await tester.ensureVisible(ok); await tester.tap(ok); await tester.pumpAndSettle();
            await tester.tap(checkbox); await tester.pumpAndSettle();
            expect(find.byIcon(Icons.check).evaluate().length, initialChecks + 1);
          }
          final approve = find.text('אשר והוסף כחבר');
          await tester.ensureVisible(approve); await tester.tap(approve); await tester.pumpAndSettle();
          expect(accepts.length, 1);
          expect(accepts.single.containsKey('filter'), editFilter);
          if (editFilter) expect((accepts.single['filter'] as Map)['men'], true);
          expect(events.take(2).toList(), ['accept', 'leave']);
          expect(find.text('בקשת חברות מאת חבר בדיקה'), findsNothing);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink()); await tester.pump(const Duration(seconds: 1));
        }
      }, () => client);
    });
  }
}
