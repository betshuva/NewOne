import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Never clear a badge on a failed/partial unread-count request.
Future<void> reconcileReadNotifications(String api, String token,
    {http.Client? client, MethodChannel? channel}) async {
  if (channel == null &&
      (kIsWeb || defaultTargetPlatform != TargetPlatform.android)) {
    return;
  }
  final transport = client ?? http.Client();
  final before = DateTime.now().millisecondsSinceEpoch;
  try {
    final results = await Future.wait([
      for (final route in [
        'messages/unread',
        'groups/unread',
        'message-requests'
      ])
        transport.get(Uri.parse('$api/$route'), headers: {
          'Authorization': 'Bearer $token'
        }).timeout(const Duration(seconds: 10)),
    ]);
    if (results.any((r) => r.statusCode != 200)) return;
    final direct = jsonDecode(results[0].body) as Map;
    final groups = jsonDecode(results[1].body) as Map;
    final requests = jsonDecode(results[2].body) as List;
    final counts = <String, int>{
      for (final e in direct.entries) 'chat:${e.key}': (e.value as num).toInt(),
      for (final e in groups.entries)
        'group:${e.key}': (e.value as num).toInt(),
    };
    await (channel ?? const MethodChannel('com.betshuva.app/share'))
        .invokeMethod('reconcileNotifications', {
      'counts': counts,
      'before': before,
      'clearLegacy': requests.isEmpty && counts.values.every((n) => n == 0)
    });
  } catch (_) {
    // Retain notifications when the server/platform cannot confirm read state.
  } finally {
    if (client == null) transport.close();
  }
}
