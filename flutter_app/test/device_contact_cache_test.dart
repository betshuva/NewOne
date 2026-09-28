import 'dart:async';
import 'dart:convert';
import 'package:betshuva/device_contact_cache.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const contactChannel = MethodChannel('github.com/QuisApp/flutter_contacts');
  const permissionChannel = MethodChannel('flutter.baseflow.com/permissions/methods');
  var granted = true;
  var reads = 0;
  var permissionRequests = 0;
  Completer<List<dynamic>>? blockedRead;
  final rows = [Contact(id: 'one', displayName: 'שלום', phones: [Phone('+972501234567'), Phone('0527654321')]).toJson()];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    granted = true; reads = 0; permissionRequests = 0; blockedRead = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      permissionChannel, (call) async => granted ? 1 : 0);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      contactChannel, (call) async {
        if (call.method == 'requestPermission') { permissionRequests++; return granted; }
        if (call.method == 'select') { reads++; return blockedRead?.future ?? rows; }
        return null;
      });
  });

  test('memory cache avoids repeated native reads and keeps secondary phone numbers', () async {
    final cache = DeviceContactCache('a');
    final first = await cache.load();
    final second = await cache.load();
    expect(first.map((r) => r['phone']), ['0501234567', '0527654321']);
    expect(second, first);
    expect(reads, 1);
    expect(permissionRequests, 0);
  });

  test('account-scoped disk cache returns before native refresh completes', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('device_contact_names_v1_a', jsonEncode([{'name': 'cached', 'phone': '0501111111'}]));
    blockedRead = Completer<List<dynamic>>();
    final cache = DeviceContactCache('a');
    expect((await cache.load()).single['name'], 'cached');
    blockedRead!.complete(rows);
    await cache.refresh();
    expect((await cache.load()).first['name'], 'שלום');
    await DeviceContactCache('b').load();
    expect(prefs.containsKey('device_contact_names_v1_b'), isTrue);
    await DeviceContactCache.clear('a');
    expect(prefs.containsKey('device_contact_names_v1_a'), isFalse);
    expect(prefs.containsKey('device_contact_names_v1_b'), isTrue);
  });

  test('revoking permission clears cached contact names without prompting', () async {
    final cache = DeviceContactCache('a');
    await cache.load();
    granted = false;
    expect(await cache.load(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('device_contact_names_v1_a'), isFalse);
    expect(permissionRequests, 0);
  });

  test('logout during a native read cannot recreate the persisted cache', () async {
    blockedRead = Completer<List<dynamic>>();
    final cache = DeviceContactCache('a');
    final pending = cache.refresh();
    await Future<void>.delayed(Duration.zero);
    await DeviceContactCache.clear('a');
    blockedRead!.complete(rows);
    expect(await pending, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('device_contact_names_v1_a'), isFalse);
  });
}
