import 'dart:async';

/// A small background queue shared by images and video stills. A chat opening
/// can promote queued work without starting another download of the same URL.
class MediaPrefetchQueue {
  MediaPrefetchQueue({this.concurrency = 2, this.maxQueued = 20});

  final int concurrency, maxQueued;
  final _queued = <_PrefetchJob>[];
  final _pending = <String, _PrefetchJob>{};
  final _completed = <String>{};
  int _active = 0, _generation = 0;

  Future<void> schedule(String key, Future<void> Function() load,
      {bool priority = false}) {
    if (_completed.contains(key)) return Future.value();
    final existing = _pending[key];
    if (existing != null) {
      if (priority && _queued.remove(existing)) _queued.insert(0, existing);
      return existing.done.future;
    }
    if (_queued.length >= maxQueued) {
      if (!priority) return Future.value();
      final discarded = _queued.removeLast();
      _pending.remove(discarded.key);
      discarded.done.complete();
    }
    final job = _PrefetchJob(key, load, _generation);
    _pending[key] = job;
    priority ? _queued.insert(0, job) : _queued.add(job);
    _drain();
    return job.done.future;
  }

  void _drain() {
    while (_active < concurrency && _queued.isNotEmpty) {
      final job = _queued.removeAt(0);
      _active++;
      _run(job);
    }
  }

  Future<void> _run(_PrefetchJob job) async {
    try {
      await job.load();
      if (job.generation == _generation) {
        _completed.add(job.key);
        if (_completed.length > 80) _completed.remove(_completed.first);
      }
    } catch (_) {
      // A failed warmup is retried by the visible media widget normally.
    } finally {
      if (identical(_pending[job.key], job)) _pending.remove(job.key);
      job.done.complete();
      _active--;
      _drain();
    }
  }

  void clear() {
    _generation++;
    for (final job in _queued) {
      job.done.complete();
    }
    _queued.clear();
    _pending.clear();
    _completed.clear();
  }
}

class _PrefetchJob {
  _PrefetchJob(this.key, this.load, this.generation);
  final String key;
  final Future<void> Function() load;
  final int generation;
  final done = Completer<void>();
}
