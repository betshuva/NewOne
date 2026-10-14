import 'dart:async';
import 'package:betshuva/media_prefetch_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'two loads at a time; opening a chat promotes pending work and deduplicates',
      () async {
    final queue = MediaPrefetchQueue();
    final gates = <String, Completer<void>>{};
    final started = <String>[];
    Future<void> load(String key) {
      started.add(key);
      return (gates[key] = Completer<void>()).future;
    }

    final jobs = [
      for (final key in ['a', 'b', 'c', 'd'])
        queue.schedule(key, () => load(key))
    ];
    final duplicate =
        queue.schedule('d', () => fail('duplicate download'), priority: true);
    expect(started, ['a', 'b']);
    gates['a']!.complete();
    await jobs[0];
    expect(started, ['a', 'b', 'd']);
    gates['b']!.complete();
    await jobs[1];
    expect(started, ['a', 'b', 'd', 'c']);
    gates['c']!.complete();
    gates['d']!.complete();
    await Future.wait([...jobs, duplicate]);
    await queue.schedule('d', () => fail('already warmed'));
  });

  test(
      'failure can retry and logout discards queued work without filling new generation',
      () async {
    final queue = MediaPrefetchQueue(concurrency: 1);
    var attempts = 0;
    await queue.schedule('failed', () async {
      attempts++;
      throw StateError('offline');
    });
    await queue.schedule('failed', () async {
      attempts++;
    });
    expect(attempts, 2);
    final gate = Completer<void>();
    final active = queue.schedule('old', () => gate.future);
    final queued =
        queue.schedule('queued', () async => fail('old account queued work'));
    queue.clear();
    await queued;
    gate.complete();
    await active;
    var reloaded = false;
    await queue.schedule('old', () async {
      reloaded = true;
    });
    expect(reloaded, isTrue);
  });

  test('queue cap lets foreground work replace the last background item',
      () async {
    final queue = MediaPrefetchQueue(concurrency: 1, maxQueued: 1);
    final gate = Completer<void>();
    final active = queue.schedule('active', () => gate.future);
    final dropped = queue.schedule('background', () async => fail('discarded'));
    await queue.schedule('overflow', () async => fail('over capacity'));
    var foreground = false;
    final promoted = queue.schedule('foreground', () async {
      foreground = true;
    }, priority: true);
    await dropped;
    gate.complete();
    await active;
    await promoted;
    expect(foreground, isTrue);
  });
}
