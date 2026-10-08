import 'dart:typed_data';

typedef MediaBytesReader = Future<Uint8List?> Function(String key);
typedef MediaBytesWriter = Future<void> Function(String key, Uint8List bytes);

/// Reuses encoded media bytes before consulting persistent storage or network.
/// Keeping the same byte object also lets MemoryImage reuse its decoded frame.
class PersistentMediaLoader {
  PersistentMediaLoader({
    required MediaBytesReader read,
    required MediaBytesWriter write,
    required MediaBytesReader download,
    this.maxBytes = 24 * 1024 * 1024,
    this.maxEntries = 80,
  })  : _read = read,
        _write = write,
        _download = download {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    if (maxEntries < 0) throw ArgumentError.value(maxEntries, 'maxEntries');
  }

  final MediaBytesReader _read, _download;
  final MediaBytesWriter _write;
  final int maxBytes, maxEntries;
  final _bytes = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List?>>{};
  final _writes = <Future<void>>{};
  int _byteCount = 0;
  int _generation = 0;

  /// Returns a warm entry synchronously and marks it recently used.
  Uint8List? peek(String key) {
    final bytes = _bytes.remove(key);
    if (bytes != null) _bytes[key] = bytes;
    return bytes;
  }

  Future<Uint8List?> load(String key) {
    final bytes = peek(key);
    if (bytes != null) return Future.value(bytes);
    final pending = _pending[key];
    if (pending != null) return pending;

    final future = _load(key, _generation);
    _pending[key] = future;
    future.then((_) {
      if (identical(_pending[key], future)) _pending.remove(key);
    });
    return future;
  }

  Future<Uint8List?> _load(String key, int generation) async {
    Uint8List? bytes;
    try {
      bytes = await _read(key);
    } catch (_) {
      // Storage is best-effort; a failed read can still use the network.
    }
    if (bytes != null && bytes.isNotEmpty) {
      if (generation == _generation) _remember(key, bytes);
      return bytes;
    }
    if (generation != _generation) return null;
    try {
      bytes = await _download(key);
    } catch (_) {
      return null;
    }
    if (bytes == null || bytes.isEmpty) return null;
    if (generation == _generation) {
      _remember(key, bytes);
      _persist(key, bytes);
    }
    return bytes;
  }

  void _remember(String key, Uint8List bytes) {
    if (maxEntries == 0 || bytes.lengthInBytes > maxBytes) return;
    final previous = _bytes.remove(key);
    if (previous != null) _byteCount -= previous.lengthInBytes;
    _bytes[key] = bytes;
    _byteCount += bytes.lengthInBytes;
    while (_bytes.length > maxEntries || _byteCount > maxBytes) {
      _byteCount -= _bytes.remove(_bytes.keys.first)!.lengthInBytes;
    }
  }

  void _persist(String key, Uint8List bytes) {
    final write = Future<void>.sync(() => _write(key, bytes)).then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _writes.add(write);
    write.then((_) => _writes.remove(write));
  }

  /// Invalidates memory and in-flight loads immediately. Downloads from an old
  /// generation may finish for their callers, but cannot refill either cache.
  /// Await this before clearing persistent storage so existing writes finish
  /// first. Persistent storage itself is owned by the caller.
  Future<void> clear() async {
    _generation++;
    _bytes.clear();
    _byteCount = 0;
    _pending.clear();
    await Future.wait(_writes.toList());
  }
}
