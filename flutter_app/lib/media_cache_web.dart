// Legacy IndexedDB bridge required by the current Flutter web plugin interface.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

const _databaseName = 'betshuva_media_cache';
const _storeName = 'media';
Future<dynamic>? _database;

Future<dynamic> _openDatabase() {
  final indexedDb = html.window.indexedDB;
  if (indexedDb == null) {
    return Future<dynamic>.error(
      StateError('IndexedDB is unavailable'),
    );
  }
  return _database ??= indexedDb.open(
    _databaseName,
    version: 1,
    onUpgradeNeeded: (event) {
      final dynamic request = event.target;
      final dynamic database = request.result;
      if (!database.objectStoreNames!.contains(_storeName)) {
        database.createObjectStore(_storeName);
      }
    },
  );
}

Future<Uint8List?> readMediaCache(String key) async {
  try {
    final database = await _openDatabase();
    final transaction = database.transaction(_storeName, 'readonly');
    final value = await transaction.objectStore(_storeName).getObject(key);
    await transaction.completed;
    if (value is Uint8List) return value;
    if (value is ByteBuffer) return value.asUint8List();
    if (value is List<int>) return Uint8List.fromList(value);
  } catch (_) {}
  return null;
}

Future<void> writeMediaCache(String key, Uint8List bytes) async {
  if (bytes.isEmpty) return;
  try {
    final database = await _openDatabase();
    final transaction = database.transaction(_storeName, 'readwrite');
    await transaction.objectStore(_storeName).put(bytes, key);
    await transaction.completed;
  } catch (_) {
    // Browsers may deny or evict persistent storage; network loading remains.
  }
}

Future<void> clearMediaCache() async {
  try {
    final database = await _openDatabase();
    final transaction = database.transaction(_storeName, 'readwrite');
    await transaction.objectStore(_storeName).clear();
    await transaction.completed;
  } catch (_) {}
}
