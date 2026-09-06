import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:betshuva/read_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/read-notifications');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  Future<void> reconcile(
      {bool fail = false, bool unread = false, bool request = false}) async {
    final client = MockClient((r) async {
      expect(r.headers['Authorization'], 'Bearer token');
      if (r.url.path.endsWith('message-requests')) {
        return http.Response(
            jsonEncode(request
                ? [
                    {'id': 'request'}
                  ]
                : []),
            fail ? 503 : 200);
      }
      return http.Response(jsonEncode(unread ? {'peer': 2} : {}), 200);
    });
    await reconcileReadNotifications('https://example.test/api', 'token',
        client: client, channel: channel);
    client.close();
  }

  test('fully read snapshot clears legacy notifications with cutoff timestamp',
      () async {
    final before = DateTime.now().millisecondsSinceEpoch;
    await reconcile();
    expect(calls.single.method, 'reconcileNotifications');
    expect(calls.single.arguments['clearLegacy'], true);
    expect(calls.single.arguments['counts'], isEmpty);
    expect(calls.single.arguments['before'], greaterThanOrEqualTo(before));
  });
  test('unread conversations are retained by their tags', () async {
    await reconcile(unread: true);
    expect(calls.single.arguments['counts'], {'chat:peer': 2, 'group:peer': 2});
    expect(calls.single.arguments['clearLegacy'], false);
  });
  test('pending contact request retains legacy notification', () async {
    await reconcile(request: true);
    expect(calls.single.arguments['clearLegacy'], false);
  });
  test('partial server failure never clears notifications', () async {
    await reconcile(fail: true);
    expect(calls, isEmpty);
  });
}
