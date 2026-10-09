import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

const _cacheLifetime = Duration(days: 7);
const _maxTileBytes = 2 * 1024 * 1024;
const _maxMetadataBytes = 16 * 1024;
Future<NativeLocationMapTileCache>? _nativeCache;

/// Browser tiles use the browser HTTP cache. Native tiles identify this app and
/// use a dedicated, bounded cache with HTTP validators after expiry.
Future<Uint8List?> loadLocationMapTile(Uri uri) async {
  try {
    final cache = await (_nativeCache ??= () async {
      final root = await getApplicationCacheDirectory();
      return NativeLocationMapTileCache(
          directory: Directory('${root.path}/shared-location-tiles'));
    }());
    return await cache.load(uri);
  } catch (_) {
    // Manual coordinates remain available if persistent caching is unavailable.
    return null;
  }
}

/// [directory] belongs exclusively to the tile cache; stale/orphan cache files
/// can be removed here. Clock/client and smaller budgets allow isolated tests.
class NativeLocationMapTileCache {
  final Directory directory;
  final http.Client? client;
  final int maxBytes;
  final int maxTiles;
  final DateTime Function() _now;
  final _pending = <String, Future<Uint8List?>>{};
  final _entries = <String, _DiskEntry>{};
  Future<void> _diskTail = Future.value();
  bool _initialized = false;
  int _diskBytes = 0;

  NativeLocationMapTileCache({
    required this.directory,
    this.client,
    this.maxBytes = 64 * 1024 * 1024,
    this.maxTiles = 2048,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (maxBytes <= 0 || maxTiles <= 0) {
      throw ArgumentError('Tile cache budgets must be positive');
    }
  }

  Future<Uint8List?> load(Uri uri) {
    if (!_validTileUri(uri)) return Future.value(null);
    return _pending.putIfAbsent(
        uri.toString(),
        () => _load(uri).whenComplete(() {
              _pending.remove(uri.toString());
            }));
  }

  Future<T> _disk<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _diskTail = _diskTail.then((_) async {
      try {
        await _initialize();
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    await directory.create(recursive: true);
    _entries.clear();
    _diskBytes = 0;
    final files = <String, File>{};
    await for (final file in directory.list(followLinks: false)) {
      if (file is File) files[file.uri.pathSegments.last] = file;
    }
    for (final entry in files.entries) {
      final name = entry.key;
      if (RegExp(r'^\d+-\d+-\d+\.png$').hasMatch(name)) {
        final stat = await entry.value.stat();
        var size = stat.size;
        for (final extension in ['.meta', '.expiry']) {
          final extra = files['$name$extension'];
          if (extra != null) size += (await extra.stat()).size;
        }
        _entries[name] = _DiskEntry(size, stat.modified);
        _diskBytes += size;
      } else if (!(name.endsWith('.meta') &&
              files.containsKey(name.substring(0, name.length - 5))) &&
          !(name.endsWith('.expiry') &&
              files.containsKey(name.substring(0, name.length - 7)))) {
        await entry.value.delete();
      }
    }
    _initialized = true;
    await _makeRoom(0, 0);
  }

  File _file(String name) => File('${directory.path}/$name');

  Future<void> _remove(String name) async {
    for (final extension in ['', '.meta', '.expiry', '.part', '.meta.part']) {
      final file = _file('$name$extension');
      if (await file.exists()) await file.delete();
    }
    final removed = _entries.remove(name);
    if (removed != null) _diskBytes -= removed.bytes;
  }

  Future<void> _makeRoom(int bytes, int tiles) async {
    while (_entries.isNotEmpty &&
        (_diskBytes + bytes > maxBytes || _entries.length + tiles > maxTiles)) {
      final oldest = _entries.entries
          .reduce((a, b) => a.value.lastUsed.isAfter(b.value.lastUsed) ? b : a);
      await _remove(oldest.key);
    }
  }

  Future<_CachedTile?> _read(String name) async {
    if (!_entries.containsKey(name)) return null;
    try {
      final file = _file(name);
      final stat = await file.stat();
      if (stat.size <= 0 || stat.size > _maxTileBytes) {
        await _remove(name);
        return null;
      }
      final meta = _file('$name.meta');
      final expiry = _file('$name.expiry');
      final headers = <String, String>{};
      var expires = stat.modified.add(_cacheLifetime);
      final hasMeta = await meta.exists();
      final hasExpiry = await expiry.exists();
      if (hasMeta) {
        if ((await meta.stat()).size > _maxMetadataBytes) {
          throw const FormatException();
        }
        final data = jsonDecode(await meta.readAsString()) as Map;
        expires = DateTime.parse(data['expiresAt'] as String);
        for (final entry in (data['headers'] as Map).entries) {
          if (entry.key is! String ||
              entry.value is! String ||
              (entry.value as String).length > 1024 ||
              (entry.value as String).contains(RegExp(r'[\r\n]'))) {
            throw const FormatException();
          }
          headers[entry.key as String] = entry.value as String;
        }
      } else if (hasExpiry) {
        if ((await expiry.stat()).size > 100) throw const FormatException();
        expires = DateTime.parse(await expiry.readAsString());
      }
      final bytes = await file.readAsBytes();
      // Old files lacking expiry metadata use their original mtime as TTL.
      // Never extend that fallback lifetime just by viewing the tile again.
      if (hasMeta || hasExpiry) await file.setLastModified(_now());
      final entry = _entries.remove(name)!;
      _entries[name] = _DiskEntry(entry.bytes, _now());
      return _CachedTile(bytes, expires, headers);
    } catch (_) {
      await _remove(name);
      return null;
    }
  }

  Future<void> _store(
      String name, Uint8List bytes, Map<String, String> headers) async {
    if (_hasDirective(headers, 'no-store')) {
      await _remove(name);
      return;
    }
    final metadata = utf8.encode(jsonEncode({
      'expiresAt': _expiresAt(headers, _now()).toIso8601String(),
      'headers': headers,
    }));
    await _remove(name);
    final size = bytes.length + metadata.length;
    if (size > maxBytes) return;
    await _makeRoom(size, 1);
    try {
      await _file('$name.part').writeAsBytes(bytes, flush: true);
      await _file('$name.meta.part').writeAsBytes(metadata, flush: true);
      await _file('$name.part').rename(_file(name).path);
      await _file('$name.meta.part').rename(_file('$name.meta').path);
      await _file(name).setLastModified(_now());
      _entries[name] = _DiskEntry(size, _now());
      _diskBytes += size;
    } catch (_) {
      await _remove(name);
      rethrow;
    }
  }

  Future<Uint8List?> _load(Uri uri) async {
    final name = uri.pathSegments.join('-');
    try {
      final cached = await _disk(() => _read(name));
      if (cached != null && _now().isBefore(cached.expires)) {
        return cached.bytes;
      }
      final headers = <String, String>{
        'User-Agent': 'BetshuvaLocationShare/1.0 (+https://betshuva.com)',
        if (cached?.headers['etag'] != null)
          'If-None-Match': cached!.headers['etag']!,
        if (cached?.headers['last-modified'] != null)
          'If-Modified-Since': cached!.headers['last-modified']!,
      };
      final response = await (client?.get ?? http.get)(uri, headers: headers)
          .timeout(const Duration(seconds: 12));
      final selected = <String, String>{
        for (final key in [
          'cache-control',
          'expires',
          'etag',
          'last-modified',
          'age'
        ])
          if (response.headers[key] != null &&
              response.headers[key]!.length <= 1024 &&
              !response.headers[key]!.contains(RegExp(r'[\r\n]')))
            key: response.headers[key]!,
      };
      if (response.statusCode == 304 && cached != null) {
        final updated = {...cached.headers, ...selected};
        await _disk(() => _store(name, cached.bytes, updated));
        return cached.bytes;
      }
      if (response.statusCode != 200 ||
          response.bodyBytes.isEmpty ||
          response.bodyBytes.length > _maxTileBytes) {
        return null;
      }
      await _disk(() => _store(name, response.bodyBytes, selected));
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }
}

class _CachedTile {
  final Uint8List bytes;
  final DateTime expires;
  final Map<String, String> headers;
  const _CachedTile(this.bytes, this.expires, this.headers);
}

class _DiskEntry {
  final int bytes;
  final DateTime lastUsed;
  const _DiskEntry(this.bytes, this.lastUsed);
}

bool _validTileUri(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host != 'tile.openstreetmap.org' ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }
  final match = RegExp(r'^/(\d{1,2})/(\d+)/(\d+)\.png$').firstMatch(uri.path);
  if (match == null) return false;
  final zoom = int.tryParse(match.group(1)!);
  final x = int.tryParse(match.group(2)!);
  final y = int.tryParse(match.group(3)!);
  return zoom != null &&
      zoom >= 0 &&
      zoom <= 19 &&
      x != null &&
      y != null &&
      x < (1 << zoom) &&
      y < (1 << zoom);
}

bool _hasDirective(Map<String, String> headers, String name) =>
    (headers['cache-control'] ?? '')
        .toLowerCase()
        .split(',')
        .any((value) => value.trim().split('=').first == name);

DateTime _expiresAt(Map<String, String> headers, DateTime now) {
  if (_hasDirective(headers, 'no-cache') ||
      _hasDirective(headers, 'no-store')) {
    return now;
  }
  final match = RegExp(r'(?:^|,)\s*max-age\s*=\s*"?(\d+)', caseSensitive: false)
      .firstMatch(headers['cache-control'] ?? '');
  final maxAge = match == null ? null : int.tryParse(match.group(1)!);
  if (maxAge != null && maxAge <= 365 * 24 * 60 * 60) {
    final age = int.tryParse(headers['age'] ?? '') ?? 0;
    return now.add(Duration(seconds: (maxAge - age).clamp(0, maxAge)));
  }
  try {
    final expires = headers['expires'];
    if (expires != null) return HttpDate.parse(expires);
  } catch (_) {}
  return now.add(_cacheLifetime);
}
