@TestOn('browser')
library;

// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:betshuva/media_cache_web.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'old open tab cannot indefinitely block media loading; cache recovers after closing it',
      () async {
    final legacy = await html.window.indexedDB!
        .open('betshuva_media_cache', version: 1, onUpgradeNeeded: (event) {
      final dynamic request = event.target;
      request.result.createObjectStore('media');
    });
    await writeMediaCache('blocked', Uint8List.fromList([1]));
    expect(await readMediaCache('blocked'), isNull);
    legacy.close();
    Uint8List? recovered;
    for (var attempt = 0; attempt < 10 && recovered == null; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await writeMediaCache('recovered', Uint8List.fromList([2]));
      recovered = await readMediaCache('recovered');
    }
    expect(recovered, [2]);
  });

  test('IndexedDB keeps two hundred entries and refreshes LRU access',
      () async {
    await clearMediaCache();
    for (var i = 0; i < 200; i++) {
      await writeMediaCache('prefetch-test-$i', Uint8List.fromList([i % 255]));
    }
    expect(await readMediaCache('prefetch-test-0'), isNotNull);
    await writeMediaCache('prefetch-test-200', Uint8List.fromList([1]));
    expect(await readMediaCache('prefetch-test-0'), isNotNull);
    expect(await readMediaCache('prefetch-test-1'), isNull);
    expect(await readMediaCache('prefetch-test-200'), isNotNull);
    await clearMediaCache();
    expect(await readMediaCache('prefetch-test-0'), isNull);
  });
}
