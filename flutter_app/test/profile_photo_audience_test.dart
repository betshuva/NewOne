import 'dart:convert';

import 'package:betshuva/profile_photo_audience.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _options = {
  'privacy_pic': 'all',
  'profile_photo_user_ids': <String>[],
  'profile_photo_group_ids': <String>[],
  'is_teen': false,
  'users': [
    {'id': 'person-1', 'name': 'משתמש לבדיקה'}
  ],
  'groups': [
    {'id': 'group-1', 'name': 'קבוצה לבדיקה'}
  ],
};

void main() {
  testWidgets('select users and groups together and return the audience draft',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    ProfilePhotoAudience? chosen;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => TextButton(
          onPressed: () async => chosen = await chooseProfilePhotoAudience(
              context,
              api: 'https://example.test/api',
              token: 'test'),
          child: const Text('פתח'),
        ),
      ))));
      await tester.tap(find.text('פתח'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('משתמשים וקבוצות שאבחר'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('משתמש לבדיקה'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('קבוצה לבדיקה'), 180,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('קבוצה לבדיקה'));
      await tester.tap(find.text('אישור הבחירה'));
      await tester.pumpAndSettle();
    },
        () => MockClient((request) async {
              expect(request.method, 'GET',
                  reason: 'choosing alone must not save');
              expect(request.headers['Authorization'], 'Bearer test');
              return http.Response(jsonEncode(_options), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
    expect(chosen!.mode, 'selected');
    expect(chosen!.userIds, {'person-1'});
    expect(chosen!.groupIds, {'group-1'});
    expect(chosen!.toJson()['privacy_pic'], 'selected');
  });

  testWidgets('cancel preserves the previous selection and submits nothing',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const initial =
        ProfilePhotoAudience(mode: 'selected', userIds: {'person-1'});
    ProfilePhotoAudience? chosen = initial;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => TextButton(
          onPressed: () async => chosen = await chooseProfilePhotoAudience(
              context,
              api: 'https://example.test/api',
              token: 'test',
              initial: initial),
          child: const Text('פתח'),
        ),
      ))));
      await tester.tap(find.text('פתח'));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
              .value,
          true);
      await tester.tap(find.text('רק אני'));
      await tester.tap(find.byTooltip('סגור'));
      await tester.pumpAndSettle();
    },
        () => MockClient((request) async {
              expect(request.method, 'GET');
              return http.Response(jsonEncode(_options), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
    expect(chosen, isNull);
    expect(initial.userIds, {'person-1'});
    expect(initial.mode, 'selected');
  });

  testWidgets('load failure disables confirmation and retry restores choices',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loads = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => TextButton(
          onPressed: () => chooseProfilePhotoAudience(context,
              api: 'https://example.test/api', token: 'test'),
          child: const Text('פתח'),
        ),
      ))));
      await tester.tap(find.text('פתח'));
      await tester.pumpAndSettle();
      expect(find.text('לא ניתן לטעון את בחירת הצופים'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      await tester.tap(find.text('נסה שוב'));
      await tester.pumpAndSettle();
      expect(find.text('כל המשתמשים'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull);
    },
        () => MockClient((_) async => ++loads == 1
            ? http.Response('{}', 500)
            : http.Response(jsonEncode(_options), 200,
                headers: {'content-type': 'application/json; charset=utf-8'})));
  });
}
