import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../lib/storage_quota.dart';

void main() {
  final token = 'x.${base64Url.encode(utf8.encode('{"id":"quota-user"}'))}.x';
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('quota panel offers cleanup without deleting or connecting automatically', (tester) async {
    var cleanup = 0, connect = 0;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StorageQuotaView(
      api: '/api', token: token, onCleanup: () => cleanup++, onDrive: () => connect++,
      loadQuota: () async => {'usedBytes': 1800000000, 'warningLevel': 90, 'limitBytes': 2000000000},
    ))));
    await tester.pumpAndSettle();
    expect(find.text('מתקרבים למכסת האחסון — 90%'), findsOneWidget);
    expect(cleanup, 0); expect(connect, 0);
    await tester.tap(find.byKey(const ValueKey('storage-cleanup')));
    expect(cleanup, 1); expect(connect, 0);
    await tester.tap(find.text('חיבור Drive אישי'));
    expect(connect, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('dismissed warnings stay quiet until the next threshold and rearm after freeing space', (tester) async {
    var level = 80, revision = 0;
    Future<void> show() async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: StorageQuotaView(
        api: '/api', token: token, revision: revision++, alertsOnly: true,
        onCleanup: () {}, onDrive: () {},
        loadQuota: () async => {'usedBytes': level * 20000000, 'warningLevel': level},
      ))));
      await tester.pumpAndSettle();
    }
    await show(); expect(find.byKey(const ValueKey('storage-quota-panel')), findsOneWidget);
    await tester.tap(find.byTooltip('הבנתי')); await tester.pumpAndSettle();
    await show(); expect(find.byKey(const ValueKey('storage-quota-panel')), findsNothing);
    level = 90; await show(); expect(find.text('מתקרבים למכסת האחסון — 90%'), findsOneWidget);
    await tester.tap(find.byTooltip('הבנתי')); await tester.pumpAndSettle();
    level = 95; await show(); expect(find.text('מתקרבים למכסת האחסון — 95%'), findsOneWidget);
    level = 0; await show(); expect(find.byKey(const ValueKey('storage-quota-panel')), findsNothing);
    level = 80; await show(); expect(find.byKey(const ValueKey('storage-quota-panel')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
