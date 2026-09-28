import 'dart:async';
import 'dart:convert';
import 'package:betshuva/media_playback_progress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('saves are serialized with the authenticated account and latest version', () async {
    final firstSave = Completer<http.Response>();
    final writes = <Map<String, dynamic>>[];
    await http.runWithClient(() async {
      final progress = MediaPlaybackProgress(api: 'https://example.test/api',
        token: 'alice', url: '/betshuva-app/uploads/lesson.mp3');
      expect(await progress.load(), 123000);
      final first = progress.save(125000);
      final second = progress.save(90000);
      await Future<void>.delayed(Duration.zero);
      expect(writes.length, 1);
      firstSave.complete(http.Response('{"positionMs":125000,"version":5}', 200));
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(writes, [
        {'positionMs': 125000, 'version': 4},
        {'positionMs': 90000, 'version': 5},
      ]);
    }, () => MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer alice');
      expect(request.url.queryParameters['fileUrl'], '/betshuva-app/uploads/lesson.mp3');
      if (request.method == 'GET') return http.Response('{"positionMs":123000,"version":4}', 200);
      writes.add(jsonDecode(request.body));
      return writes.length == 1 ? await firstSave.future
          : http.Response('{"positionMs":90000,"version":6}', 200);
    }));
  });

  test('unavailable progress and stale-device writes never claim to be saved', () async {
    var status = 503;
    var writes = 0;
    await http.runWithClient(() async {
      final progress = MediaPlaybackProgress(api: 'https://example.test/api',
        token: 'alice', url: '/betshuva-app/uploads/lesson.mp3');
      expect(await progress.load(), isNull);
      expect(await progress.save(1000), isFalse);
      expect(writes, 0);
      status = 200;
      expect(await progress.load(), 2000);
      status = 409;
      expect(await progress.save(1000), isFalse);
      expect(await progress.save(1200), isFalse);
      expect(writes, 1);
      status = 200;
      expect(await progress.load(), 2000);
      expect(await progress.save(0), isTrue);
    }, () => MockClient((request) async {
      if (request.method == 'PUT') writes++;
      return http.Response('{"positionMs":2000,"version":7}', status);
    }));
  });
}
