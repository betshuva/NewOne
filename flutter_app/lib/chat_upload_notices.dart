import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ChatUploadNotices {
  final String api, token, account, kind, target;
  const ChatUploadNotices(
      {required this.api,
      required this.token,
      required this.account,
      required this.kind,
      required this.target});
  String get _key => 'upload_notices_v1_${account}_${kind}_$target';
  Map<String, String> get _headers =>
      {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
  static final _changes = StreamController<String>.broadcast();
  Stream<void> get changes =>
      _changes.stream.where((key) => key == _key).map((_) {});
  static final _writes = <String, Future<void>>{};

  Future<List<Map<String, dynamic>>> _cached() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    return value == null
        ? []
        : (jsonDecode(value) as List).cast<Map<String, dynamic>>();
  }

  Future<void> _remember(Iterable<Map<String, dynamic>> notices) async {
    final previous = _writes[_key] ?? Future<void>.value();
    final operation = previous.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final merged = {for (final item in await _cached()) item['id']: item};
      for (final item in notices) {
        merged[item['id']] = item;
      }
      if (!await prefs.setString(_key, jsonEncode(merged.values.toList()))) {
        throw StateError('שמירת הודעות ההעלאה נכשלה');
      }
    });
    _writes[_key] = operation;
    try {
      await operation;
    } finally {
      if (identical(_writes[_key], operation)) _writes.remove(_key);
    }
  }

  Future<void> save(Map<String, dynamic> notice) async {
    await _remember([
      {...notice, '_noticeSaved': false}
    ]);
    await _sync(notice);
    _changes.add(_key);
  }

  Future<void> _sync(Map<String, dynamic> notice) async {
    try {
      final response = await http
          .post(Uri.parse('$api/upload-batch-notices'),
              headers: _headers,
              body: jsonEncode({...notice, 'kind': kind, 'target': target}))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 201) {
        await _remember([
          {...notice, '_noticeSaved': true}
        ]);
      }
    } catch (_) {/* The local copy is retried when the conversation reopens. */}
  }

  Future<List<Map<String, dynamic>>> load() async {
    final cached = await _cached();
    for (final notice in cached.where((item) => item['_noticeSaved'] != true)) {
      await _sync(notice);
    }
    try {
      final response = await http
          .get(
              Uri.parse('$api/upload-batch-notices')
                  .replace(queryParameters: {'kind': kind, 'target': target}),
              headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 && jsonDecode(response.body) is List) {
        final rows =
            (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
        await _remember(rows.map((item) => {...item, '_noticeSaved': true}));
      }
    } catch (_) {/* Offline history still includes saved queue boundaries. */}
    return await _cached();
  }
}
