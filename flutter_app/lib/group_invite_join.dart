import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class GroupInviteJoinException implements Exception {
  const GroupInviteJoinException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  bool get isTerminal => statusCode == 404 || statusCode == 410;
  bool get terminal => isTerminal;

  @override
  String toString() => message;
}

String _failureMessage(int status) => switch (status) {
      401 => 'יש להתחבר מחדש כדי להצטרף לקבוצה',
      403 => 'לא ניתן להצטרף לקבוצה עם החשבון הזה',
      404 || 410 => 'קישור ההזמנה אינו פעיל. בקשו קישור חדש ממנהל הקבוצה',
      429 => 'בוצעו ניסיונות רבים. נסו להצטרף שוב בעוד זמן קצר',
      _ => 'לא ניתן להצטרף לקבוצה כעת. נסו שוב',
    };

String? _errorCode(Object? data, String inviteToken, String sessionToken) {
  final code = data is Map ? data['code'] : null;
  return code is String &&
          RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(code) &&
          !code.contains(inviteToken) &&
          !code.contains(sessionToken)
      ? code
      : null;
}

bool _nonEmptyString(Object? value) =>
    value is String && value.trim().isNotEmpty;

/// Accepts a shared link without changing the server-projected group fields.
/// Callers consume the persisted intent only after this operation succeeds.
Future<Map<String, dynamic>> joinSharedGroupInvite({
  required String api,
  required String sessionToken,
  required String inviteToken,
}) async {
  if (inviteToken.length != 43 ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(inviteToken)) {
    throw const GroupInviteJoinException('קישור ההזמנה אינו תקין',
        code: 'INVALID_GROUP_INVITE');
  }
  if (sessionToken.trim().isEmpty) {
    throw const GroupInviteJoinException('יש להתחבר מחדש כדי להצטרף לקבוצה',
        statusCode: 401, code: 'NOT_AUTHENTICATED');
  }

  final base = api.replaceFirst(RegExp(r'/+$'), '');
  late http.Response response;
  try {
    response = await http
        .post(
          Uri.parse('$base/group-invites/$inviteToken/join'),
          headers: {
            'Authorization': 'Bearer $sessionToken',
            'Content-Type': 'application/json',
          },
          body: '{}',
        )
        .timeout(const Duration(seconds: 20));
  } on TimeoutException {
    throw const GroupInviteJoinException('השרת לא הגיב בזמן. נסו להצטרף שוב');
  } catch (_) {
    // Client errors can contain the secret link or authorization token.
    throw const GroupInviteJoinException(
        'לא ניתן להתחבר לשרת. בדקו את החיבור ונסו שוב');
  }

  Object? data;
  try {
    data = jsonDecode(utf8.decode(response.bodyBytes));
  } on FormatException {
    // Keep the HTTP status even when an error response is not JSON.
  }

  if (response.statusCode != 200) {
    throw GroupInviteJoinException(_failureMessage(response.statusCode),
        statusCode: response.statusCode,
        code: _errorCode(data, inviteToken, sessionToken));
  }

  final group = data is Map ? data['group'] : null;
  if (group is! Map ||
      !_nonEmptyString(group['id']) ||
      !_nonEmptyString(group['name']) ||
      group['status'] != 'member' ||
      !_nonEmptyString(group['role'])) {
    throw const GroupInviteJoinException('השרת לא החזיר פרטי קבוצה תקינים',
        statusCode: 200, code: 'INVALID_GROUP_INVITE_RESPONSE');
  }
  return Map<String, dynamic>.from(group);
}
