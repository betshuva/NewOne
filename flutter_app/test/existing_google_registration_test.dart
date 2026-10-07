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
  testWidgets('existing Google signup enters the existing account without forms',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('plugins.flutter.io/google_sign_in');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'signIn') {
        return {'id': 'google-existing', 'email': 'existing@example.invalid',
          'displayName': 'Existing User', 'idToken': 'google-credential'};
      }
      if (call.method == 'getTokens') {
        return {'idToken': 'google-credential', 'accessToken': 'test-access'};
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final calls = <String>[];
    http.Response json(Object value) => http.Response(jsonEncode(value), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    const user = {'id': 'existing-id', 'name': 'Existing User',
      'phone': '0501234567', 'email': 'existing@example.invalid'};
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: Directionality(
          textDirection: TextDirection.rtl,
          child: AuthScreen(initialRegistration: true))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('הרשמה באמצעות Google').last);
      await tester.pumpAndSettle();
      expect(calls.where((path) => path.endsWith('/auth/google')).length, 1);
      expect(find.byType(MainShell), findsOneWidget);
      expect(find.text('השלמת פרטים'), findsNothing);
      expect(find.byType(GoogleDriveBackupOfferScreen), findsNothing);
      expect((await SharedPreferences.getInstance()).getString('token'),
          'existing-session');
      tester.widget<ConversationsScreen>(find.byType(ConversationsScreen))
          .socket?.disconnect();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    }, () => MockClient((request) async {
      final path = request.url.path;
      calls.add(path);
      if (path.endsWith('/registration/verify-google')) {
        expect(jsonDecode(request.body)['idToken'], 'google-credential');
        return json({'ok': true, 'existingAccount': true});
      }
      if (path.endsWith('/auth/google')) {
        expect(jsonDecode(request.body)['idToken'], 'google-credential');
        return json({'token': 'existing-session', 'user': user});
      }
      if (path.endsWith('/profile')) return json(user);
      if (path.endsWith('/registration-status')) {
        return json({'birthDateMissing': false});
      }
      if (path.endsWith('/users') || path.endsWith('/groups') ||
          path.endsWith('/message-requests')) {
        return json([]);
      }
      return json({});
    }));
    debugDefaultTargetPlatformOverride = null;
  });
}
