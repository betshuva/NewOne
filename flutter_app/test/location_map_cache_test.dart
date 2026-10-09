@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:betshuva/location_map_cache.dart';
import 'package:betshuva/location_map_cache_io.dart'
    show NativeLocationMapTileCache;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'native map tiles identify the app and reuse the persistent HTTP cache',
      (tester) async {
    await tester.runAsync(() async {
      final directory =
          await Directory.systemTemp.createTemp('betshuva-map-cache-test-');
      addTearDown(() => directory.delete(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => directory.path);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(
            request.headers['User-Agent'], contains('BetshuvaLocationShare/'));
        return http.Response.bytes([1, 2, 3], 200,
            headers: {'cache-control': 'max-age=1209600'});
      });
      final uri = Uri.parse('https://tile.openstreetmap.org/7/76/52.png');
      await http.runWithClient(() async {
        expect(await loadLocationMapTile(uri), [1, 2, 3]);
        expect(await loadLocationMapTile(uri), [1, 2, 3]);
      }, () => client);
      expect(requests, 1);
      final files = await Directory('${directory.path}/shared-location-tiles')
          .list()
          .toList();
      expect(files.whereType<File>().length, 2);
      final expiry = files
          .whereType<File>()
          .firstWhere((file) => file.path.endsWith('.meta'));
      final metadata =
          jsonDecode(await expiry.readAsString()) as Map<String, dynamic>;
      final expiresAt = DateTime.parse(metadata['expiresAt'] as String);
      expect(expiresAt.difference(DateTime.now()).inDays, 13);
      metadata['expiresAt'] = DateTime(2020).toIso8601String();
      await expiry.writeAsString(jsonEncode(metadata));
      await http.runWithClient(() async {
        expect(await loadLocationMapTile(uri), [1, 2, 3]);
      }, () => client);
      expect(requests, 2);
    });
  });

  testWidgets(
      'expired validators use 304 bytes and renewed metadata survives restart',
      (tester) async {
    await tester.runAsync(() async {
      final directory = await _temporaryCache();
      var now = DateTime.utc(2026, 10, 9);
      var requests = 0;
      const lastModified = 'Thu, 08 Oct 2026 10:00:00 GMT';
      final client = MockClient((request) async {
        requests++;
        if (requests == 1) {
          expect(request.headers['If-None-Match'], isNull);
          return http.Response.bytes([4, 5, 6], 200,
              headers: {
                'cache-control': 'max-age=60',
                'etag': '"tile-v1"',
                'last-modified': lastModified,
              });
        }
        expect(request.headers['If-None-Match'], '"tile-v1"');
        expect(request.headers['If-Modified-Since'], lastModified);
        return http.Response('', 304,
            headers: {'cache-control': 'max-age=3600'});
      });
      final cache = NativeLocationMapTileCache(
          directory: directory, client: client, now: () => now);
      expect(await cache.load(_tile(1)), [4, 5, 6]);
      now = now.add(const Duration(seconds: 61));
      expect(await cache.load(_tile(1)), [4, 5, 6]);
      expect(requests, 2);
      final restarted = NativeLocationMapTileCache(
          directory: directory, client: client, now: () => now);
      now = now.add(const Duration(minutes: 20));
      expect(await restarted.load(_tile(1)), [4, 5, 6]);
      expect(requests, 2);
    });
  });

  testWidgets(
      'Last-Modified alone and the seven day fallback revalidate correctly',
      (tester) async {
    await tester.runAsync(() async {
      final directory = await _temporaryCache();
      var now = DateTime.utc(2026, 10, 9);
      var requests = 0;
      const lastModified = 'Thu, 08 Oct 2026 10:00:00 GMT';
      final client = MockClient((request) async {
        requests++;
        if (requests == 2) {
          expect(request.headers['If-None-Match'], isNull);
          expect(request.headers['If-Modified-Since'], lastModified);
          return http.Response('', 304);
        }
        return http.Response.bytes([7], 200,
            headers: {'last-modified': lastModified});
      });
      final cache = NativeLocationMapTileCache(
          directory: directory, client: client, now: () => now);
      await cache.load(_tile(1));
      now = now.add(const Duration(days: 6));
      await cache.load(_tile(1));
      expect(requests, 1);
      now = now.add(const Duration(days: 2));
      expect(await cache.load(_tile(1)), [7]);
      await cache.load(_tile(1));
      expect(requests, 2);
    });
  });

  testWidgets('Expires, no-cache and no-store follow the server cache policy',
      (tester) async {
    await tester.runAsync(() async {
      final directory = await _temporaryCache();
      var now = DateTime.utc(2026, 10, 9);
      final counts = <int, int>{};
      final client = MockClient((request) async {
        final index = int.parse(request.url.pathSegments[1]);
        counts[index] = (counts[index] ?? 0) + 1;
        if (index == 1) {
          return http.Response.bytes([1], 200,
              headers: {
                'expires': HttpDate.format(DateTime.utc(2026, 10, 9, 0, 1)),
              });
        }
        if (index == 2) {
          if (counts[index] == 2) {
            expect(request.headers['If-None-Match'], '"private"');
          }
          return http.Response.bytes([2], 200,
              headers: {'cache-control': 'no-cache', 'etag': '"private"'});
        }
        return http.Response.bytes([3], 200,
            headers: {'cache-control': 'no-store'});
      });
      final cache = NativeLocationMapTileCache(
          directory: directory, client: client, now: () => now);
      await cache.load(_tile(1));
      await cache.load(_tile(1));
      expect(counts[1], 1);
      now = now.add(const Duration(minutes: 2));
      await cache.load(_tile(1));
      expect(counts[1], 2);
      await cache.load(_tile(2));
      await cache.load(_tile(2));
      expect(counts[2], 2);
      await cache.load(_tile(3));
      await cache.load(_tile(3));
      expect(counts[3], 2);
      expect(await File('${directory.path}/7-3-52.png').exists(), isFalse);
    });
  });

  testWidgets(
      'tile count evicts the least recently viewed entry including its metadata',
      (tester) async {
    await tester.runAsync(() async {
      final directory = await _temporaryCache();
      var now = DateTime.utc(2026, 10, 9);
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response.bytes([1, 2, 3], 200);
      });
      final cache = NativeLocationMapTileCache(
          directory: directory, client: client, now: () => now, maxTiles: 2);
      await cache.load(_tile(1));
      now = now.add(const Duration(seconds: 1));
      await cache.load(_tile(2));
      now = now.add(const Duration(seconds: 1));
      await cache.load(_tile(1));
      now = now.add(const Duration(seconds: 1));
      await cache.load(_tile(3));
      expect(requests, 3);
      expect(await File('${directory.path}/7-2-52.png').exists(), isFalse);
      expect(await File('${directory.path}/7-2-52.png.meta').exists(), isFalse);
      expect(await File('${directory.path}/7-1-52.png').exists(), isTrue);
      expect(await File('${directory.path}/7-3-52.png').exists(), isTrue);
      // A smaller budget must also trim a cache populated by a prior process.
      final restarted = NativeLocationMapTileCache(
          directory: directory, client: client, now: () => now, maxTiles: 1);
      await restarted.load(_tile(3));
      expect(requests, 3);
      expect(
          (await _cacheFiles(directory))
              .where((file) => file.path.endsWith('.png')),
          hasLength(1));
    });
  });

  testWidgets(
      'concurrent writes remain within the byte budget including metadata',
      (tester) async {
    await tester.runAsync(() async {
      final directory = await _temporaryCache();
      final client = MockClient(
          (request) async => http.Response.bytes(List.filled(250, 1), 200));
      final cache = NativeLocationMapTileCache(
          directory: directory, client: client, maxBytes: 600);
      final results = await Future.wait(
          [cache.load(_tile(1)), cache.load(_tile(2)), cache.load(_tile(3))]);
      expect(results.every((bytes) => bytes?.length == 250), isTrue);
      final files = await _cacheFiles(directory);
      final lengths = await Future.wait(files.map((file) => file.length()));
      expect(lengths.fold<int>(0, (total, size) => total + size),
          lessThanOrEqualTo(600));
      expect(files.where((file) => file.path.endsWith('.png')), hasLength(1));
      expect(files.where((file) => file.path.endsWith('.meta')), hasLength(1));
    });
  });

  testWidgets(
      'orphan files and corrupt metadata are cleaned without forwarding unsafe headers',
      (tester) async {
    await tester.runAsync(() async {
      final directory = await _temporaryCache();
      await File('${directory.path}/old.part')
          .writeAsString('interrupted write');
      await File('${directory.path}/old.png.meta')
          .writeAsString('orphan metadata');
      await File('${directory.path}/7-1-52.png').writeAsBytes([9]);
      await File('${directory.path}/7-1-52.png.meta').writeAsString(jsonEncode({
        'expiresAt': DateTime.utc(2025).toIso8601String(),
        'headers': {'etag': 'bad\r\nInjected: header'},
      }));
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(request.headers['If-None-Match'], isNull);
        return http.Response.bytes([1, 2, 3], 200);
      });
      final cache =
          NativeLocationMapTileCache(directory: directory, client: client);
      expect(await cache.load(_tile(1)), [1, 2, 3]);
      expect(requests, 1);
      expect(await File('${directory.path}/old.part').exists(), isFalse);
      expect(await File('${directory.path}/old.png.meta').exists(), isFalse);
    });
  });

  testWidgets(
      'same tile requests share one transfer and invalid tile addresses never fetch',
      (tester) async {
    await tester.runAsync(() async {
      final directory = await _temporaryCache();
      final release = Completer<void>();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        await release.future;
        return http.Response.bytes([1], 200);
      });
      final cache =
          NativeLocationMapTileCache(directory: directory, client: client);
      final first = cache.load(_tile(1)), second = cache.load(_tile(1));
      release.complete();
      expect(await first, [1]);
      expect(await second, [1]);
      expect(requests, 1);
      expect(await cache.load(_tile(1)), [1]);
      for (final url in [
        'http://tile.openstreetmap.org/7/1/52.png',
        'https://evil.example/7/1/52.png',
        'https://tile.openstreetmap.org/7/128/52.png',
        'https://tile.openstreetmap.org/20/1/52.png',
        'https://tile.openstreetmap.org/7/1/52.png?token=secret'
      ]) {
        expect(await cache.load(Uri.parse(url)), isNull);
      }
      expect(requests, 1);
    });
  });
  testWidgets('errors and oversized responses cannot overwrite a cached tile',
      (tester) async {
    await tester.runAsync(() async {
      final directory = await _temporaryCache();
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        if (requests == 1) {
          return http.Response.bytes([8], 200,
              headers: {'cache-control': 'max-age=0', 'etag': '"saved"'});
        }
        if (requests == 2) {
          expect(request.headers['If-None-Match'], '"saved"');
          return http.Response('temporary failure', 503);
        }
        if (requests == 3) {
          expect(request.headers['If-None-Match'], '"saved"');
          return http.Response('', 304,
              headers: {'cache-control': 'max-age=3600'});
        }
        if (requests == 4) {
          return http.Response.bytes(List.filled(2 * 1024 * 1024 + 1, 9), 200);
        }
        return http.Response('', 304);
      });
      final cache =
          NativeLocationMapTileCache(directory: directory, client: client);
      expect(await cache.load(_tile(1)), [8]);
      expect(await cache.load(_tile(1)), isNull);
      expect(await File('${directory.path}/7-1-52.png').readAsBytes(), [8]);
      expect(await cache.load(_tile(1)), [8]);
      expect(await cache.load(_tile(2)), isNull);
      expect(await File('${directory.path}/7-2-52.png').exists(), isFalse);
      expect(await cache.load(_tile(3)), isNull);
      expect(await File('${directory.path}/7-3-52.png').exists(), isFalse);
    });
  });
}

Uri _tile(int x) => Uri.parse('https://tile.openstreetmap.org/7/$x/52.png');

Future<Directory> _temporaryCache() async {
  final directory =
      await Directory.systemTemp.createTemp('betshuva-map-cache-test-');
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}

Future<List<File>> _cacheFiles(Directory directory) async =>
    (await directory.list().toList()).whereType<File>().toList();
