import 'dart:convert';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  testWidgets(
      'profile editor saves photo audience with the profile in one request',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? saved;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                        onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                                builder: (_) => const ProfileScreen(
                                    me: {'id': 'me'}, token: 'test'))),
                        child: const Text('פרופיל')),
                  ))));
      await tester.tap(find.text('פרופיל'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('מי יכול לראות את התמונה?'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('משתמשים וקבוצות שאבחר'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('אדם לבדיקה'));
      await tester.scrollUntilVisible(find.text('קבוצה לבדיקה'), 180,
          scrollable: find
              .descendant(
                  of: find.byType(ListView).last,
                  matching: find.byType(Scrollable))
              .first);
      await tester.tap(find.text('קבוצה לבדיקה'));
      await tester.tap(find.text('אישור הבחירה'));
      await tester.pumpAndSettle();
      expect(find.text('1 משתמשים ו־1 קבוצות'), findsOneWidget);
      await tester.tap(find.text('שמור'));
      await tester.pumpAndSettle();
    },
        () => MockClient((request) async {
              if (request.method == 'PUT') {
                saved = jsonDecode(request.body) as Map<String, dynamic>;
                return _json({'ok': true});
              }
              if (request.url.path.endsWith('/photo-audience'))
                return _json({
                  'privacy_pic': 'all',
                  'users': [
                    {'id': 'person', 'name': 'אדם לבדיקה'}
                  ],
                  'groups': [
                    {'id': 'group', 'name': 'קבוצה לבדיקה'}
                  ],
                });
              return _json({
                'name': 'משתמש לבדיקה',
                'privacy_pic': 'all',
                'profile_pic_url': 'emoji:🌻'
              });
            }));
    expect(saved!['name'], 'משתמש לבדיקה');
    expect(saved!['privacy_pic'], 'selected');
    expect(saved!['profile_photo_user_ids'], ['person']);
    expect(saved!['profile_photo_group_ids'], ['group']);
    expect(saved!['profile_pic_url'], 'emoji:🌻');
  });

  testWidgets('failed profile load cannot save default public privacy',
      (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
          home: ProfileScreen(me: {'id': 'me'}, token: 'test')));
      await tester.pumpAndSettle();
      final save =
          tester.widget<TextButton>(find.widgetWithText(TextButton, 'שמור'));
      expect(save.onPressed, isNull);
      expect(find.text('לא ניתן לטעון את הפרופיל. נסה לפתוח אותו מחדש'),
          findsOneWidget);
    }, () => MockClient((request) async => http.Response('{}', 500)));
  });
}
