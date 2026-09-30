import 'dart:convert';
import 'package:betshuva/chat_upload_notices.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('queue notices survive reopening offline and sync to another device', () async {
    SharedPreferences.setMockInitialValues({});
    const store = ChatUploadNotices(api: 'https://test/api', token: 'token', account: 'owner', kind: 'group', target: 'group');
    var online = false;
    final remote = <String, Map<String, dynamic>>{};
    await http.runWithClient(() async {
      for (final phase in ['start', 'end']) {
        await store.save({'id': phase, 'isUploadBatchNotice': true,
          'text': phase == 'start' ? 'מעלה 3 קבצים' : 'סוף העלאת 3 קבצים',
          'createdAt': '2026-09-30T12:00:00Z'});
      }
      expect((await store.load()).length, 2);
      expect(remote, isEmpty);
      online = true;
      expect((await store.load()).length, 2);
      expect(remote.length, 2);
      SharedPreferences.setMockInitialValues({});
      expect((await store.load()).map((m) => m['id']), ['start', 'end']);
    }, () => MockClient((request) async {
      if (!online) return http.Response('{}', 503);
      if (request.method == 'POST') {
        final data = jsonDecode(request.body) as Map<String, dynamic>;
        remote[data['id']] = data;
        return http.Response('{"saved":true}', 201);
      }
      return http.Response(jsonEncode(remote.values.toList()), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    }));
  });
}
