import 'dart:convert';
import 'package:betshuva/foreground_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'foreground notification uses default sound and preserves tap destination',
      () async {
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await showForegroundMessageNotification(
        FlutterLocalNotificationsPlugin(),
        const RemoteMessage(
            messageId: 'test',
            data: {'type': 'chat', 'fromUserId': 'peer'},
            notification: RemoteNotification(title: 'title', body: 'body')));
    final call = calls.singleWhere((c) => c.method == 'show');
    final android = call.arguments['platformSpecifics'] as Map;
    expect(android['sound'], isNull);
    expect(android['playSound'], true);
    expect(android['tag'], 'chat:peer');
    final payload = call.arguments['payload'] as String;
    expect(jsonDecode(payload)['data']['fromUserId'], 'peer');
    expect(notificationMessageFromPayload(payload)?.data['fromUserId'], 'peer');
    expect(notificationMessageFromPayload('invalid'), isNull);
  });
}
