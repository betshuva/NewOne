import 'dart:convert';
import 'package:betshuva/chat_design_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> doc(String revision, Map<String, dynamic> settings) =>
    {'schemaVersion': 1, 'revision': revision, 'settings': settings};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('bounded schema ignores future fields and rejects unsafe values', () {
    final parsed = ChatDesign.parse(doc('new', {
      'textScale': 1.1,
      'messageGap': 2,
      'showFileNames': false,
      'future': 42
    }))!;
    expect(parsed.number('messageGap', 4), 2);
    expect(parsed.flag('showFileNames'), false);
    expect(parsed.values.containsKey('future'), false);
    for (final bad in [
      {'textScale': 100},
      {'voicePlayerWidth': -1},
      {'showFileNames': 'false'},
      {'accentColor': '#FFFFFF'},
      {'chatBackground': '#000000'}
    ]) expect(ChatDesign.parse(doc('bad', bad)), isNull);
    expect(
        ChatDesign.parse(
            {'schemaVersion': 2, 'revision': 'future', 'settings': {}}),
        isNull);
  });
  test('remote updates persist and last valid design survives offline relaunch',
      () async {
    SharedPreferences.setMockInitialValues({});
    var online = true;
    var revision = 'one';
    final client = MockClient((r) async {
      expect(r.url.path, '/api/chat-design');
      return http.Response(
          online
              ? jsonEncode(
                  doc(revision, {'messageGap': 2, 'voicePlayerWidth': 240}))
              : '{}',
          online ? 200 : 503);
    });
    final store = ChatDesignStore(client: client);
    store.attach('https://example.test/api');
    await store.ready;
    expect(store.value.revision, 'one');
    revision = 'two';
    await store.refresh();
    expect(store.value.revision, 'two');
    store.detach();
    store.dispose();
    online = false;
    final offline = ChatDesignStore(client: client);
    offline.attach('https://example.test/api');
    await offline.ready;
    expect(offline.value.revision, 'two');
    expect(offline.value.number('voicePlayerWidth', 285), 240);
    offline.detach();
    offline.dispose();
  });
  test(
      'invalid responses retain valid settings and paused clients stop fetching',
      () async {
    SharedPreferences.setMockInitialValues({});
    var bad = false;
    var calls = 0;
    final store = ChatDesignStore(client: MockClient((r) async {
      calls++;
      return http.Response(
          jsonEncode(doc('server', {'messageGap': bad ? -99 : 3})), 200);
    }));
    store.attach('https://example.test/api');
    store.attach('https://example.test/api');
    await store.ready;
    expect(calls, 1);
    bad = true;
    await store.refresh();
    expect(store.value.number('messageGap', 4), 3);
    store.didChangeAppLifecycleState(AppLifecycleState.paused);
    final before = calls;
    await store.refresh();
    expect(calls, before);
    store.detach();
    store.detach();
    store.dispose();
  });
  test('scaling preserves system accessibility text sizes', () {
    const scale = ChatDesignTextScaler(TextScaler.linear(1.5), 1.1);
    expect(scale.scale(20), closeTo(33, .001));
  });
}
