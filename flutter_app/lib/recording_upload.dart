import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

/// A private, bounded transfer. No destination or send request exists until
/// finish() is called by the normal chat upload flow after its permission checks.
class RecordingUpload {
  RecordingUpload(
      {required this.api,
      required this.token,
      required this.name,
      required this.mime,
      required this.length,
      required this.read,
      http.Client? client,
      bool autoStart = true})
      : _client = client ?? http.Client() {
    if (autoStart) {
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => pump());
    }
  }

  factory RecordingUpload.file(
      {required String api,
      required String token,
      required String name,
      required String mime,
      required String path}) {
    // A fresh XFile avoids caching a growing file's size.
    return RecordingUpload(
        api: api,
        token: token,
        name: name,
        mime: mime,
        length: () => XFile(path).length(),
        read: (start, end) => readRecordingRange(XFile(path), start, end));
  }

  final String api, token, name, mime;
  final Future<int> Function() length;
  final Future<Uint8List> Function(int start, int end) read;
  final http.Client _client;
  final String id = _uuid();
  final _blocks = <({int offset, int length, String hash})>[];
  int _offset = 0;
  bool _created = false, _failed = false, _cancelled = false, _stopped = false;
  Future<void>? _flight;
  Timer? _timer, _expiry;
  String? _path;
  static final _pending = <String, RecordingUpload>{};
  static final _objects = Expando<RecordingUpload>();
  static const _blockBytes = 256 * 1024;

  static String _uuid() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};
  Uri get _url => Uri.parse('$api/upload-sessions/$id');
  Future<http.Response> _json(String url, Map<String, dynamic> data) => _client
      .post(Uri.parse(url),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode(data))
      .timeout(const Duration(seconds: 30));
  void _check(http.Response response) {
    if (response.statusCode != 200) {
      throw StateError('Recording transfer ${response.statusCode}');
    }
  }

  Future<void> _ensureCreated() async {
    if (_created) return;
    // Mark before sending so cancellation also covers a lost create response.
    _created = true;
    _check(await _json('$api/upload-sessions', {
      'id': id,
      'name': name,
      'size': 0,
      'mime': mime,
      'recording': true,
    }));
  }

  Future<void> _write(int offset, Uint8List bytes, {bool patch = false}) async {
    final request = http.Request(patch ? 'PATCH' : 'PUT', _url)
      ..headers.addAll({
        ..._headers,
        'Content-Type': 'application/octet-stream',
        'Upload-Offset': '$offset'
      })
      ..bodyBytes = bytes;
    final response = await _client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 30));
    _check(response);
    if (!patch &&
        jsonDecode(response.body)['offset'] != offset + bytes.length) {
      throw StateError('Recording offset mismatch');
    }
  }

  /// Best effort; microphone/camera operation never waits for the network.
  Future<void> pump() {
    if (_flight != null) return _flight!;
    if (_stopped || _failed || _cancelled) return Future.value();
    return _flight = _pump().catchError((Object _) {
      _failed = true;
      _timer?.cancel();
    }).whenComplete(() => _flight = null);
  }

  Future<void> _pump() async {
    final available = await length();
    if (available - _offset < 4096) return;
    await _ensureCreated();
    while (!_cancelled && !_stopped && available - _offset >= 4096) {
      final end = min(available, _offset + _blockBytes);
      final bytes = await read(_offset, end);
      if (bytes.length != end - _offset) {
        throw StateError('Short recording read');
      }
      await _write(_offset, bytes);
      _blocks.add((
        offset: _offset,
        length: bytes.length,
        hash: sha256.convert(bytes).toString()
      ));
      _offset = end;
    }
  }

  /// Retain the session through the existing final send/recipient checks.
  void attach(XFile file) {
    _stopped = true;
    _timer?.cancel();
    _objects[file] = this;
    if (file.path.isNotEmpty) _pending[_path = file.path] = this;
    _expiry = Timer(const Duration(minutes: 10), cancel);
  }

  static Future<void> discard(dynamic file) async {
    if (file is! XFile) return;
    final stage = _objects[file] ?? _pending[file.path];
    _objects[file] = null;
    await stage?.cancel();
  }

  static Future<({int statusCode, String body})?> upload(
      {required dynamic file,
      required String token,
      required String name,
      required Map<String, String> fields}) async {
    if (file is! XFile) return null;
    final stage = _objects[file] ?? _pending[file.path];
    if (stage == null) return null;
    _objects[file] = null;
    if (stage.token != token) {
      await stage.cancel();
      return null;
    }
    return stage.finish(file, name: name, fields: fields);
  }

  void _forget() {
    _timer?.cancel();
    _expiry?.cancel();
    if (_path != null && identical(_pending[_path], this)) {
      _pending.remove(_path);
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    _forget();
    await _flight;
    if (_created) {
      // A disconnected client may leave the server finishing a chunk briefly.
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final response = await _client
              .delete(_url, headers: _headers)
              .timeout(const Duration(seconds: 5));
          if (response.statusCode != 409) break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        } catch (_) {
          break;
        } // Server TTL cleans up abandoned offline sessions.
      }
    }
    _client.close();
  }

  Future<({int statusCode, String body})?> finish(XFile file,
      {required String name, required Map<String, String> fields}) async {
    _stopped = true;
    _forget();
    await _flight;
    if (_failed || _cancelled) {
      await cancel();
      return null;
    }
    try {
      await _ensureCreated();
      final size = await file.length();
      if (size < _offset || size == 0) throw StateError('Recording truncated');
      // Native encoders can rewrite the MP4/WAV header on stop. Reconcile all
      // uploaded blocks and verify the final digest on the server before send.
      for (final block in _blocks) {
        final bytes = await readRecordingRange(
            file, block.offset, block.offset + block.length);
        if (sha256.convert(bytes).toString() != block.hash) {
          await _write(block.offset, bytes, patch: true);
        }
      }
      while (_offset < size) {
        final end = min(size, _offset + _blockBytes);
        await _write(_offset, await readRecordingRange(file, _offset, end));
        _offset = end;
      }
      final digest = await sha256.bind(file.openRead()).first;
      _check(await _json('$api/upload-sessions/$id/seal', {
        'size': size,
        'name': name,
        'mime': file.mimeType ?? mime,
        'fields': fields,
        'sha256': digest.toString(),
      }));
    } catch (_) {
      // Nothing was submitted for delivery: the original file is safe to upload
      // through the normal path (including offline/quota/older-server fallback).
      await cancel();
      return null;
    }
    // After this boundary NEVER fall back to a new multipart upload: the server
    // may have accepted the send even if its response was lost.
    try {
      for (var attempt = 0; attempt < 60; attempt++) {
        try {
          final response = await _json('$api/upload', {'uploadSessionId': id});
          if (response.statusCode != 202) {
            return (statusCode: response.statusCode, body: response.body);
          }
        } on TimeoutException {
          // Retrying this same id returns the saved receipt or processing state.
        } on http.ClientException {
          if (attempt >= 2) rethrow;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      throw StateError(
          'ההקלטה עדיין בטיפול. יש לבדוק את השיחה לפני שליחה חוזרת');
    } finally {
      _client.close();
    }
  }
}

Future<Uint8List> readRecordingRange(XFile file, int start, int end) async {
  final builder = BytesBuilder(copy: false);
  await for (final bytes in file.openRead(start, end)) {
    builder.add(bytes);
  }
  final result = builder.takeBytes();
  if (result.length != end - start) throw StateError('Short recording read');
  return result;
}
