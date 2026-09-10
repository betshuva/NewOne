import 'dart:convert';

import 'package:http/http.dart' as http;

final _guideFileUuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

String? guideFileIdFromUrl(String fileUrl, String api) {
  final base = Uri.tryParse(api);
  final reference = Uri.tryParse(fileUrl);
  final uri = reference == null ? null : base?.resolveUri(reference);
  if (base == null ||
      uri == null ||
      !['http', 'https'].contains(base.scheme) ||
      base.host.isEmpty ||
      uri.scheme != base.scheme ||
      uri.host != base.host ||
      uri.port != base.port ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return null;
  }
  final prefix = '${base.path.replaceFirst(RegExp(r'/$'), '')}/guide-files/';
  if (!uri.path.startsWith(prefix) || !uri.path.endsWith('/download')) {
    return null;
  }
  final id = uri.path.substring(prefix.length, uri.path.length - 9);
  return _guideFileUuid.hasMatch(id) ? id.toLowerCase() : null;
}

class GuideFile {
  const GuideFile({
    required this.id,
    required this.fileUrl,
    required this.fileName,
    required this.downloadUrl,
  });

  final String id;
  final String fileUrl;
  final String fileName;
  final Uri downloadUrl;
}

/// Looks up a persistent chat file using the current account. Only the
/// short-lived download URL is handed to the browser or native file opener.
Future<GuideFile> loadGuideFile({
  required String api,
  required String token,
  required String id,
  http.Client? client,
}) async {
  if (!_guideFileUuid.hasMatch(id) || token.isEmpty) {
    throw const FormatException('הקובץ אינו זמין לפתיחה');
  }
  final transport = client ?? http.Client();
  try {
    final response = await transport.get(
      Uri.parse('$api/guide-files/$id'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw const FormatException('הקובץ אינו זמין או שאין הרשאה לצפות בו');
    }
    final value = jsonDecode(utf8.decode(response.bodyBytes));
    if (value is! Map ||
        value['fileUrl'] is! String ||
        value['downloadUrl'] is! String ||
        value['fileName'] is! String ||
        value['fileType'] != 'document') {
      throw const FormatException('התקבל קישור קובץ לא תקין');
    }
    final fileUrl = value['fileUrl'] as String;
    final downloadUrl = value['downloadUrl'] as String;
    final name = (value['fileName'] as String).trim();
    if (guideFileIdFromUrl(fileUrl, api) != id.toLowerCase() ||
        guideFileIdFromUrl(downloadUrl, api) != id.toLowerCase() ||
        name.isEmpty ||
        name.length > 255) {
      throw const FormatException('התקבל קישור קובץ לא תקין');
    }
    return GuideFile(
      id: id,
      fileUrl: fileUrl,
      fileName: name,
      downloadUrl: Uri.parse(api).resolve(downloadUrl),
    );
  } finally {
    if (client == null) transport.close();
  }
}
