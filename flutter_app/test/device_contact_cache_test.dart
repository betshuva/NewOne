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
  const permissionChannel =
      MethodChannel('flutter.baseflow.com/permissions/methods');
  const readPermissionChannel = MethodChannel('com.betshuva.app/contacts');
  var granted = true;
  var groupedGranted = true;
  bool? requestedGrant;
  var reads = 0;
  var permissionRequests = 0;
  var requestedReadonly = <Object?>[];
  Completer<List<dynamic>>? blockedRead;
  final rows = [
    Contact(
        id: 'one',
        displayName: 'שלום',
        phones: [Phone('+972501234567'), Phone('0527654321')]).toJson()
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    granted = true;
    groupedGranted = true;
    requestedGrant = null;
    reads = 0;
    permissionRequests = 0;
    requestedReadonly = [];
    blockedRead = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(permissionChannel,
            (call) async => granted && groupedGranted ? 1 : 0);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(readPermissionChannel, (call) async {
      if (call.method == 'readPermissionStatus') return granted ? 1 : 0;
      if (call.method == 'markReadPermissionRequested') return null;
      throw MissingPluginException('Unexpected contacts method ${call.method}');
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(contactChannel, (call) async {
      if (call.method == 'requestPermission') {
        permissionRequests++;
        requestedReadonly.add(call.arguments);
        if (requestedGrant != null) granted = requestedGrant!;
        return granted;
      }
      if (call.method == 'select') {
        reads++;
        return blockedRead?.future ?? rows;
      }
      return null;
    });
  });

  test(
      'memory cache avoids repeated native reads and keeps secondary phone numbers',
      () async {
    final cache = DeviceContactCache('a');
    final first = await cache.load();
    final second = await cache.load();
    expect(first.map((r) => r['phone']), ['0501234567', '0527654321']);
    expect(second, first);
    expect(reads, 1);
    expect(permissionRequests, 0);
  });

  test('READ-only grant loads and retains memory cache without prompting',
      () async {
    groupedGranted = false;
    final cache = DeviceContactCache('read-only');
    final first = await cache.load(requestPermission: true);
    expect(first.map((row) => row['phone']), ['0501234567', '0527654321']);
    expect(await cache.load(), first);
    expect(await cache.load(requestPermission: true), first);
    expect(reads, 1);
    expect(permissionRequests, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('device_contact_names_v1_read-only'), isTrue);
  });

  test('READ-only grant keeps persisted names available during refresh',
      () async {
    groupedGranted = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'device_contact_names_v1_read-disk',
        jsonEncode([
          {'name': 'cached read-only', 'phone': '0501111111'}
        ]));
    blockedRead = Completer<List<dynamic>>();
    final cache = DeviceContactCache('read-disk');
    expect((await cache.load()).single['name'], 'cached read-only');
    expect(prefs.containsKey('device_contact_names_v1_read-disk'), isTrue);
    expect(permissionRequests, 0);
    blockedRead!.complete(rows);
    await cache.refresh();
    expect((await cache.load()).first['name'], 'שלום');
    expect(reads, 1);
  });

  test(
      'explicit request grants READ and loads cache while WRITE remains denied',
      () async {
    granted = false;
    groupedGranted = false;
    requestedGrant = true;
    final cache = DeviceContactCache('new-read-grant');
    final result = await cache.load(requestPermission: true);
    expect(result.map((row) => row['phone']), ['0501234567', '0527654321']);
    expect(permissionRequests, 1);
    expect(requestedReadonly, [true]);
    expect(await cache.load(), result);
    expect(reads, 1);
    expect(permissionRequests, 1);
  });

  test('account-scoped disk cache returns before native refresh completes',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'device_contact_names_v1_a',
        jsonEncode([
          {'name': 'cached', 'phone': '0501111111'}
        ]));
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

  test('revoking permission clears cached contact names without prompting',
      () async {
    final cache = DeviceContactCache('a');
    await cache.load();
    granted = false;
    expect(await cache.load(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('device_contact_names_v1_a'), isFalse);
    expect(permissionRequests, 0);
  });

  test('logout during a native read cannot recreate the persisted cache',
      () async {
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

  test('revoking permission during native read does not persist contact names',
      () async {
    blockedRead = Completer<List<dynamic>>();
    final cache = DeviceContactCache('revoked-pending');
    final pending = cache.load();
    for (var i = 0; i < 50 && reads == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(reads, 1);
    granted = false;
    blockedRead!.complete(rows);
    expect(await pending, isEmpty);
    expect(await cache.load(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs.containsKey('device_contact_names_v1_revoked-pending'), isFalse);
    expect(reads, 1);
    expect(permissionRequests, 0);
  });
}
