import 'dart:async';
import 'dart:typed_data';

import 'package:betshuva/persistent_media_loader.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int size) => Uint8List(size)..fillRange(0, size, 1);

void main() {
  test('warm loads and peek retain byte identity and skip storage', () async {
    final bytes = _bytes(4);
    var reads = 0, downloads = 0, writes = 0;
    final loader = PersistentMediaLoader(
      read: (_) async {
        reads++;
        return null;
      },
      download: (_) async {
        downloads++;
        return bytes;
      },
      write: (_, __) async {
        writes++;
      },
    );
    expect(await loader.load('photo'), same(bytes));
    expect(loader.peek('photo'), same(bytes));
    expect(await loader.load('photo'), same(bytes));
    await loader.clear();
    expect(reads, 1);
    expect(downloads, 1);
    expect(writes, 1);
    expect(loader.peek('photo'), isNull);
  });

  test('storage hits are warm without downloading or rewriting', () async {
    final bytes = _bytes(4);
    var reads = 0;
    final loader = PersistentMediaLoader(
      read: (_) async {
        reads++;
        return bytes;
      },
      download: (_) async => fail('unexpected download'),
      write: (_, __) async => fail('unexpected write'),
    );
    expect(await loader.load('photo'), same(bytes));
    expect(await loader.load('photo'), same(bytes));
    expect(reads, 1);
  });

  test('identical in-flight requests share a future and one download',
      () async {
    final download = Completer<Uint8List?>();
    final started = Completer<void>();
    var reads = 0, downloads = 0;
    final loader = PersistentMediaLoader(
      read: (_) async {
        reads++;
        return null;
      },
      download: (_) {
        downloads++;
        started.complete();
        return download.future;
      },
      write: (_, __) async {},
    );
    final first = loader.load('photo');
    final second = loader.load('photo');
    expect(second, same(first));
    await started.future;
    final bytes = _bytes(4);
    download.complete(bytes);
    expect(await first, same(bytes));
    expect(await second, same(bytes));
    expect(reads, 1);
    expect(downloads, 1);
  });

  test('entry limit evicts the least recently used entry', () async {
    final loader = PersistentMediaLoader(
      read: (_) async => null,
      download: (_) async => _bytes(4),
      write: (_, __) async {},
      maxEntries: 2,
    );
    final first = await loader.load('first');
    await loader.load('second');
    expect(loader.peek('first'), same(first));
    await loader.load('third');
    expect(loader.peek('second'), isNull);
    expect(loader.peek('first'), same(first));
    expect(loader.peek('third'), isNotNull);
  });

  test('byte limit evicts old entries and oversized downloads remain usable',
      () async {
    var largeDownloads = 0;
    final loader = PersistentMediaLoader(
      read: (_) async => null,
      download: (key) async {
        if (key == 'large') largeDownloads++;
        return _bytes(key == 'large' ? 9 : 4);
      },
      write: (_, __) async {},
      maxBytes: 8,
    );
    await loader.load('first');
    await loader.load('second');
    await loader.load('third');
    expect(loader.peek('first'), isNull);
    final second = loader.peek('second');
    final third = loader.peek('third');
    expect(second, isNotNull);
    expect(third, isNotNull);
    expect((await loader.load('large'))!.length, 9);
    expect(loader.peek('large'), isNull);
    expect(loader.peek('second'), same(second));
    expect(loader.peek('third'), same(third));
    await loader.load('large');
    expect(largeDownloads, 2);
  });

  test('download is ready while persistence is pending; clear drains writes',
      () async {
    final write = Completer<void>();
    final bytes = _bytes(4);
    final loader = PersistentMediaLoader(
      read: (_) async => null,
      download: (_) async => bytes,
      write: (_, __) => write.future,
    );
    expect(await loader.load('photo'), same(bytes));
    expect(write.isCompleted, isFalse);
    var cleared = false;
    final clearing = loader.clear().then((_) => cleared = true);
    expect(loader.peek('photo'), isNull);
    await Future<void>.value();
    expect(cleared, isFalse);
    write.complete();
    await clearing;
    expect(cleared, isTrue);
  });

  for (final synchronous in [false, true]) {
    test(
        'persistence ${synchronous ? 'synchronous' : 'asynchronous'} errors '
        'do not prevent display or warm reuse', () async {
      final bytes = _bytes(4);
      final loader = PersistentMediaLoader(
        read: (_) async => null,
        download: (_) async => bytes,
        write: (_, __) {
          if (synchronous) throw StateError('storage failed');
          return Future<void>.error(StateError('storage failed'));
        },
      );
      expect(await loader.load('photo'), same(bytes));
      expect(await loader.load('photo'), same(bytes));
      await loader.clear();
    });
  }

  test('clear prevents old downloads from repopulating memory or disk',
      () async {
    final oldDownload = Completer<Uint8List?>();
    final started = Completer<void>();
    final oldBytes = _bytes(3);
    final newBytes = _bytes(4);
    var downloads = 0;
    final writes = <Uint8List>[];
    final loader = PersistentMediaLoader(
      read: (_) async => null,
      download: (_) {
        downloads++;
        if (downloads == 1) {
          started.complete();
          return oldDownload.future;
        }
        return Future.value(newBytes);
      },
      write: (_, bytes) async => writes.add(bytes),
    );
    final oldLoad = loader.load('photo');
    await started.future;
    await loader.clear();
    final newLoad = loader.load('photo');
    expect(newLoad, isNot(same(oldLoad)));
    expect(await newLoad, same(newBytes));
    oldDownload.complete(oldBytes);
    expect(await oldLoad, same(oldBytes));
    expect(loader.peek('photo'), same(newBytes));
    expect(writes, [same(newBytes)]);
    expect(downloads, 2);
    await loader.clear();
  });

  test('clear also prevents a pending disk hit from warming memory', () async {
    final disk = Completer<Uint8List?>();
    final loader = PersistentMediaLoader(
      read: (_) => disk.future,
      download: (_) async => fail('unexpected download'),
      write: (_, __) async => fail('unexpected write'),
    );
    final pending = loader.load('photo');
    await loader.clear();
    final bytes = _bytes(4);
    disk.complete(bytes);
    expect(await pending, same(bytes));
    expect(loader.peek('photo'), isNull);
  });

  test('old completion cannot remove a new in-flight request after clear',
      () async {
    final oldDownload = Completer<Uint8List?>();
    final newDownload = Completer<Uint8List?>();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    var downloads = 0;
    final loader = PersistentMediaLoader(
      read: (_) async => null,
      download: (_) {
        downloads++;
        if (downloads == 1) {
          firstStarted.complete();
          return oldDownload.future;
        }
        secondStarted.complete();
        return newDownload.future;
      },
      write: (_, __) async {},
    );
    final oldLoad = loader.load('photo');
    await firstStarted.future;
    await loader.clear();
    final newLoad = loader.load('photo');
    await secondStarted.future;
    oldDownload.complete(null);
    expect(await oldLoad, isNull);
    expect(loader.load('photo'), same(newLoad));
    final bytes = _bytes(4);
    newDownload.complete(bytes);
    expect(await newLoad, same(bytes));
    expect(downloads, 2);
  });

  test('clear prevents an old disk miss from starting a download', () async {
    final disk = Completer<Uint8List?>();
    final loader = PersistentMediaLoader(
      read: (_) => disk.future,
      download: (_) async => fail('unexpected download after clear'),
      write: (_, __) async => fail('unexpected write'),
    );
    final pending = loader.load('photo');
    await loader.clear();
    disk.complete(null);
    expect(await pending, isNull);
    expect(loader.peek('photo'), isNull);
  });

  for (final failure in ['null', 'empty', 'error']) {
    test('failed $failure downloads are not cached and can retry', () async {
      var downloads = 0;
      final bytes = _bytes(4);
      final loader = PersistentMediaLoader(
        read: (_) async => Uint8List(0),
        download: (_) async {
          downloads++;
          if (downloads > 1) return bytes;
          if (failure == 'error') throw StateError('offline');
          return failure == 'empty' ? Uint8List(0) : null;
        },
        write: (_, __) async {},
      );
      expect(await loader.load('photo'), isNull);
      expect(loader.peek('photo'), isNull);
      expect(await loader.load('photo'), same(bytes));
      expect(downloads, 2);
    });
  }

  test('disk read failures still download and cache valid bytes', () async {
    final bytes = _bytes(4);
    final loader = PersistentMediaLoader(
      read: (_) async => throw StateError('storage failed'),
      download: (_) async => bytes,
      write: (_, __) async {},
    );
    expect(await loader.load('photo'), same(bytes));
    expect(loader.peek('photo'), same(bytes));
  });
}
