import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

RemoteMessage? notificationMessageFromPayload(String? payload) {
  if (payload == null) return null;
  try {
    return RemoteMessage.fromMap(
        Map<String, dynamic>.from(jsonDecode(payload)));
  } catch (_) {
    return null;
  }
}

Future<void> showForegroundMessageNotification(
    FlutterLocalNotificationsPlugin plugin, RemoteMessage message) async {
  final notification = message.notification;
  if (notification == null) return;
  await plugin.show(
    (message.messageId ?? message.hashCode.toString()).hashCode,
    notification.title,
    notification.body,
    NotificationDetails(
      android: AndroidNotificationDetails('betshuva_messages', 'הודעות',
          importance: Importance.high,
          priority: Priority.high,
          // Omit a raw sound resource: Android uses the channel/default sound.
          tag: message.data['type'] == 'chat' &&
                  message.data['fromUserId'] != null
              ? 'chat:${message.data['fromUserId']}'
              : null),
      iOS: const DarwinNotificationDetails(sound: 'default'),
    ),
    payload: jsonEncode({
      'data': message.data,
      'notification': {
        'title': notification.title,
        'body': notification.body,
      }
    }),
  );
}
