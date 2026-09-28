import 'dart:convert';
import 'package:http/http.dart' as http;

/// One playback session. Saves are serialized and scoped by the server's
/// authenticated user; a stale session cannot overwrite another device.
class MediaPlaybackProgress {
  MediaPlaybackProgress({required String api, required this.token, required String url, String mediaType = 'audio'})
      : uri = Uri.parse('$api/$mediaType-progress').replace(queryParameters: {
          'fileUrl': Uri.parse(url).path,
        });

  final Uri uri;
  final String token;
  int _version = 0;
  bool _loaded = false;
  Future<void> _pending = Future.value();
  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token', 'Content-Type': 'application/json',
  };

  Future<int?> load() async {
    await _pending;
    try {
      final response = await http.get(uri, headers: _headers)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      final value = jsonDecode(response.body) as Map<String, dynamic>;
      _version = (value['version'] as num).toInt();
      _loaded = true;
      return (value['positionMs'] as num).toInt();
    } catch (_) { return null; }
  }

  Future<bool> save(int positionMs) {
    final result = _pending.then((_) async {
      if (!_loaded) return false;
      try {
        final response = await http.put(uri, headers: _headers,
          body: jsonEncode({'positionMs': positionMs, 'version': _version}))
            .timeout(const Duration(seconds: 5));
        if (response.statusCode == 409) _loaded = false;
        if (response.statusCode != 200) return false;
        _version = (jsonDecode(response.body)['version'] as num).toInt();
        return true;
      } catch (_) { return false; }
    });
    _pending = result.then((_) {});
    return result;
  }
}
