import 'dart:convert';
import 'package:http/http.dart' as http;

Future<bool> reportRejectedUpload({
  required String api,
  required String token,
  required String fileName,
  required int fileSize,
  required String fileType,
  required int maxBytes,
}) async {
  try {
    final response = await http.post(
      Uri.parse('$api/upload-attempts/rejected'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'fileName': fileName,
        'fileSize': fileSize,
        'fileType': fileType,
        'maxBytes': maxBytes,
        'reasonCode': 'file_too_large',
      }),
    ).timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) return false;
    final result = jsonDecode(response.body);
    return result is Map && result['recorded'] == true;
  } catch (_) {
    return false;
  }
}
