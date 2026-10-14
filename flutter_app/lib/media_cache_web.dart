// Legacy IndexedDB bridge required by the current Flutter web plugin interface.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

const _databaseName = 'betshuva_media_cache';
const _storeName = 'media';
const _metadataStore = 'metadata';
const _maxCacheBytes = 512 * 1024 * 1024;
const _maxCacheEntries = 200;
Future<dynamic>? _database;

Future<dynamic> _openDatabase() {
  final indexedDb = html.window.indexedDB;
  if (indexedDb == null) {
    return Future<dynamic>.error(
      StateError('IndexedDB is unavailable'),
    );
  }
  if (_database != null) return _database!;
  var expired = false;
  final opening = indexedDb.open(
    _databaseName,
    version: 2,
    onUpgradeNeeded: (event) {
      final dynamic request = event.target;
      final dynamic database = request.result;
      if (!database.objectStoreNames!.contains(_storeName)) {
        database.createObjectStore(_storeName);
      }
      if (!database.objectStoreNames!.contains(_metadataStore)) {
        database.createObjectStore(_metadataStore);
        // Old cached bytes had no size/access metadata. These are disposable
        // copies, not uploads; start the bounded cache with consistent metadata.
        request.transaction.objectStore(_storeName).clear();
      }
    },
  ).then((dynamic database) {
    if (expired) {
      database.close();
      _database = null;
      throw StateError('Cache opening completed after timeout');
    }
    database.onVersionChange.listen((_) {
      database.close();
      _database = null;
    });
    return database;
  });
  // An older open tab can block a schema upgrade. Display must fall back to
  // the network instead of waiting indefinitely for that tab to close.
  return _database = opening.timeout(const Duration(seconds: 2), onTimeout: () {
    expired = true;
    throw StateError('Media cache upgrade is blocked');
  });
}

Future<Uint8List?> readMediaCache(String key) async {
  try {
    final database = await _openDatabase();
    final transaction = database.transaction(_storeName, 'readonly');
    final value = await transaction.objectStore(_storeName).getObject(key);
    await transaction.completed;
    if (value != null) {
      final touch = database.transaction(_metadataStore, 'readwrite');
      final store = touch.objectStore(_metadataStore);
      final metadata = await store.getObject(key);
      if (metadata is Map) {
        await store.put(
            {...metadata, 'at': DateTime.now().millisecondsSinceEpoch}, key);
      }
      await touch.completed;
    }
    if (value is Uint8List) return value;
    if (value is ByteBuffer) return value.asUint8List();
    if (value is List<int>) return Uint8List.fromList(value);
  } catch (_) {}
  return null;
}

Future<void> writeMediaCache(String key, Uint8List bytes) async {
  if (bytes.isEmpty || bytes.lengthInBytes > _maxCacheBytes) return;
  try {
    final database = await _openDatabase();
    final transaction =
        database.transactionList([_storeName, _metadataStore], 'readwrite');
    final media = transaction.objectStore(_storeName);
    final metadata = transaction.objectStore(_metadataStore);
    await media.put(bytes, key);
    await metadata.put({
      'key': key,
      'size': bytes.lengthInBytes,
      'at': DateTime.now().millisecondsSinceEpoch
    }, key);
    await transaction.completed;
    await _pruneMediaCache(database);
  } catch (_) {
    // Browsers may deny or evict persistent storage; network loading remains.
  }
}

Future<void> _pruneMediaCache(dynamic database) async {
  final read = database.transaction(_metadataStore, 'readonly');
  final List<Map<String, dynamic>> entries = await read
      .objectStore(_metadataStore)
      .openCursor(autoAdvance: true)
      .map<Map<String, dynamic>>(
          (dynamic cursor) => Map<String, dynamic>.from(cursor.value as Map))
      .toList();
  await read.completed;
  entries.sort((a, b) {
    final order = (a['at'] as num).compareTo(b['at'] as num);
    return order != 0
        ? order
        : (a['key'] as String).compareTo(b['key'] as String);
  });
  var total = entries.fold<int>(
      0, (sum, entry) => sum + (entry['size'] as num).toInt());
  var count = entries.length;
  final remove = <String>[];
  for (final entry in entries) {
    if (total <= _maxCacheBytes && count <= _maxCacheEntries) break;
    remove.add(entry['key'] as String);
    total -= (entry['size'] as num).toInt();
    count--;
  }
  if (remove.isEmpty) return;
  final cleanup =
      database.transactionList([_storeName, _metadataStore], 'readwrite');
  for (final key in remove) {
    cleanup.objectStore(_storeName).delete(key);
    cleanup.objectStore(_metadataStore).delete(key);
  }
  await cleanup.completed;
}

Future<void> clearMediaCache() async {
  try {
    final database = await _openDatabase();
    final transaction =
        database.transactionList([_storeName, _metadataStore], 'readwrite');
    await transaction.objectStore(_storeName).clear();
    await transaction.objectStore(_metadataStore).clear();
    await transaction.completed;
  } catch (_) {}
}
