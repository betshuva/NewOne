import 'dart:convert';
import 'package:http/http.dart' as http;
import 'attachment_read_error.dart';

Future<void> reportAttachmentReadFailure({
  required String api,
  required String token,
  required AttachmentReadException error,
  required int fileSize,
}) async {
  if (error.diagnostics == null) return;
  final suffix = error.fileName.split('.').last.toLowerCase();
  const extensions = {
    'docx',
    'xlsx',
    'pdf',
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'mp3',
    'aac',
    'm4a',
    'ogg',
    'wav',
    'mp4',
    'webm',
    'mov'
  };
  try {
    await http
        .post(Uri.parse('$api/attachment-read-failures'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              ...error.diagnostics!,
              'extension': extensions.contains(suffix) ? suffix : 'unknown',
              'fileSize': fileSize,
            }))
        .timeout(const Duration(seconds: 5));
  } catch (_) {
    // Diagnostics must never interrupt the upload queue or replace its error.
  }
}
