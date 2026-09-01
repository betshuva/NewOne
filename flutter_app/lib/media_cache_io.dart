import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

const _maxCacheBytes = 512 * 1024 * 1024;
const _targetCacheBytes = 460 * 1024 * 1024;

Future<Directory> _mediaDirectory() async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory(
    '${support.path}${Platform.pathSeparator}media_cache',
  );
  await directory.create(recursive: true);
  return directory;
}

String _fileName(String key) => sha256.convert(utf8.encode(key)).toString();

Future<Uint8List?> readMediaCache(String key) async {
  try {
    final directory = await _mediaDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}${_fileName(key)}',
    );
    if (!await file.exists()) return null;
    await file.setLastModified(DateTime.now());
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}

Future<void> writeMediaCache(String key, Uint8List bytes) async {
  if (bytes.isEmpty) return;
  try {
    final directory = await _mediaDirectory();
    final name = _fileName(key);
    final file = File('${directory.path}${Platform.pathSeparator}$name');
    if (await file.exists()) {
      await file.setLastModified(DateTime.now());
      return;
    }
    final temporary = File(
      '${directory.path}${Platform.pathSeparator}.$name.'
      '${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.writeAsBytes(bytes, flush: true);
    try {
      await temporary.rename(file.path);
    } on FileSystemException {
      await temporary.delete().catchError((_) => temporary);
    }
    await _pruneMediaCache(directory);
  } catch (_) {
    // Local persistence is best-effort; network display must keep working.
  }
}

Future<void> _pruneMediaCache(Directory directory) async {
  final files = <({File file, FileStat stat})>[];
  var total = 0;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File || entity.path.endsWith('.tmp')) continue;
    try {
      final stat = await entity.stat();
      total += stat.size;
      files.add((file: entity, stat: stat));
    } catch (_) {}
  }
  if (total <= _maxCacheBytes) return;
  files.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
  for (final entry in files) {
    if (total <= _targetCacheBytes) break;
    try {
      await entry.file.delete();
      total -= entry.stat.size;
    } catch (_) {}
  }
}

Future<void> clearMediaCache() async {
  try {
    final directory = await _mediaDirectory();
    if (await directory.exists()) await directory.delete(recursive: true);
  } catch (_) {}
}
