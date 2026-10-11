import 'dart:convert';
import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });
  testWidgets(
      'pending invitation hides queued forms and group messages before acceptance',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <http.Request>[];
    final group = <String, dynamic>{
      'id': 'group-one',
      'name': 'קבוצת בדיקה',
      'status': 'pending',
      'role': 'admin',
      'send_permission': 'all'
    };
    final form = <String, dynamic>{
      'id': 'form-one',
      'group_id': 'group-one',
      'group_name': 'קבוצת בדיקה',
      'form_type': 'survey',
      'title': 'סקר למוזמנים',
      'status': 'open',
      'my_role': 'member',
      'membership_status': 'pending',
      'anonymous': false,
      'expected_count': 1,
      'response_count': 0,
      'questions': [
        {
          'text': 'מתי מגיעים?',
          'options': ['בוקר', 'ערב']
        }
      ],
      'updated_at': '2026-10-11T10:00:00Z'
    };
    final client = MockClient((req) async {
      requests.add(req);
      Object body = <String, dynamic>{};
      if (req.url.path.endsWith('/groups'))
        body = [group];
      else if (req.url.path.endsWith('/education-forms'))
        body = {
          'forms': [form],
          'isAdmin': false
        };
      else if (req.url.path.endsWith('/education-forms/form-one'))
        body = {'form': form, 'participants': null, 'results': null};
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSansHebrew'),
          home: GroupChatScreen(
              token: 'test-token',
              me: const {'id': 'pending-user'},
              group: group,
              socket: null)));
      await tester.pumpAndSettle();
      expect(find.text('טפסים וסקרים שנשלחו אליי'), findsNothing);
      expect(find.text('סקר למוזמנים'), findsNothing);
      expect(find.textContaining('מתי מגיעים?'), findsNothing);
      expect(requests.where((r) => r.url.path.endsWith('/group-one/messages')),
          isEmpty);
      expect(requests.where((r) => r.url.path.endsWith('/group-one/join')),
          isEmpty);
      expect(group['status'], 'pending');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => client);
  });
}
