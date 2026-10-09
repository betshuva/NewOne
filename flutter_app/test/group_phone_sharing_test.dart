import 'dart:convert';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final share in [true, false]) {
    testWidgets('new group defaults to sharing and persists explicit $share choice', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200,2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final created = <Map<String,dynamic>>[];
      final filter = {'text':true,'video':false,'nonHumanImages':true,'men':false,'women':false,'children':false};
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: Directionality(
          textDirection: TextDirection.rtl, child: CreateGroupScreen(token:'test-token'))));
        await tester.pumpAndSettle();
        final choice=find.widgetWithText(CheckboxListTile,'הצג את מספר הטלפון שלי למשתתפי הקבוצה');
        await tester.ensureVisible(choice);
        expect(tester.widget<CheckboxListTile>(choice).value,true);
        if (!share) { await tester.tap(choice); await tester.pump(); }
        expect(tester.widget<CheckboxListTile>(choice).value,share);
        final name=find.byWidgetPredicate((widget)=>widget is TextField && widget.decoration?.labelText=='שם הקבוצה *');
        await tester.ensureVisible(name);
        await tester.enterText(name,'קבוצת בדיקה');
        final approval=find.text('בדקתי ואני מאשר את סינון הקבוצה');
        await tester.ensureVisible(approval);
        await tester.tap(approval); await tester.pump();
        final create=find.text('צור קבוצה לעצמי');
        await tester.ensureVisible(create);
        await tester.tap(create); await tester.pumpAndSettle();
        expect(created.single['share_phone'],share);
        expect(tester.takeException(),isNull);
        await tester.pumpWidget(const SizedBox());
      },()=>MockClient((request) async {
            if (request.url.path.endsWith('/filter-pin')) return http.Response(jsonEncode({'configured': false, 'unlocked': true}), 200, headers: {'content-type': 'application/json'});
        Object body=[];
        if(request.url.path.endsWith('/filter-settings')) body=filter;
        if(request.method=='POST' && request.url.path.endsWith('/groups')) {
          created.add(jsonDecode(request.body) as Map<String,dynamic>);
          body={'id':'test-group','member_count':1,'role':'admin'};
        }
        return http.Response(jsonEncode(body),200,headers:{'content-type':'application/json; charset=utf-8'});
      }));
    });
  }
}
