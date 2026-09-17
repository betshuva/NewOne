import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class MediaDeleteResult {
  final Set<String> deletedIds;
  final List<Map<String, dynamic>> failed;
  final int deletedBytes;
  final int cleanupPendingCount;

  const MediaDeleteResult({
    required this.deletedIds,
    required this.failed,
    required this.deletedBytes,
    this.cleanupPendingCount = 0,
  });
}

class MediaDeleteException implements Exception {
  final String message;
  const MediaDeleteException(this.message);
}

List<Map<String, dynamic>> _rows(Object? value) => value is List
    ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
    : [];

String _linkedUseName(Object? type) => switch (type) {
      'profile' || 'user_profile' => 'תמונות פרופיל',
      'group' || 'group_profile' => 'תמונות של קבוצות',
      'listing' || 'listing_image' || 'listingImage' => 'תמונות במודעות',
      'form' || 'education_form' => 'קבצים בטפסים',
      'gif' || 'shared_gif' => 'קבצים משותפים',
      _ => 'שימושים נוספים',
    };

Future<bool> _confirmPreview(
  BuildContext context,
  Map<String, dynamic> preview, {
  required bool changed,
  required int selectedCount,
}) async {
  final files = _rows(preview['files']);
  final recipients = _rows(preview['pendingRecipients']);
  final uses = _rows(preview['linkedUses']);
  final count = (preview['fileCount'] as num?)?.toInt() ?? files.length;
  final copies = (preview['copyCount'] as num?)?.toInt() ?? files.length;
  final pending =
      (preview['pendingCount'] as num?)?.toInt() ?? recipients.length;
  final hasBackup = preview['hasBackup'] == true ||
      files.any((file) => file['hasBackup'] == true);
  return await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (dialogContext) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('מחיקה לצמיתות'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (changed) ...[
                      const Text(
                        'מצב הקבצים השתנה. יש לבדוק ולאשר שוב.',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(count == 1 && files.isNotEmpty
                        ? 'למחוק את „${files.first['name']}” מהמדיה שלך?'
                        : 'למחוק $count קבצים מהמדיה שלך?'),
                    if (copies > count)
                      Text('יימחקו כל $copies העותקים הזהים של הקבצים שנבחרו.'),
                    if (selectedCount > copies)
                      Text('נבחרו $selectedCount עותקים בסך הכול. '
                          'יתרת הקבצים תוצג לאישור בהמשך.'),
                    if (pending > 0 || recipients.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const Text(
                        'שים לב: הקובץ טרם התקבל אצל חלק מהנמענים. '
                        'מחיקה כעת עלולה למנוע את קבלתו.',
                        style: TextStyle(
                          color: Color(0xFFAD4C24),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      for (final recipient in recipients)
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Text(
                            '${recipient['name'] ?? 'נמען'}'
                            '${recipient['groupName'] == null ? '' : ' · ${recipient['groupName']}'}'
                            '${(recipient['count'] as num? ?? 1) > 1 ? ' (${recipient['count']} קבצים)' : ''}',
                          ),
                        ),
                      if (recipients.isEmpty)
                        Text('$pending שליחות עדיין ממתינות.'),
                    ],
                    if (uses.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const Text('הקבצים יוסרו גם מהמקומות הבאים:'),
                      for (final use in uses)
                        Text('${_linkedUseName(use['type'])}: ${use['count']}'),
                    ],
                    const SizedBox(height: 12),
                    const Text('עותקים שכבר התקבלו יישמרו אצל הנמענים.'),
                    if (hasBackup)
                      const Text('גם העותק המוצפן ב־Google Drive יימחק.'),
                    const SizedBox(height: 8),
                    const Text('לא ניתן לבטל פעולה זו.'),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('ביטול'),
              ),
              FilledButton(
                key: const ValueKey('media-delete-confirm'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFAF5157),
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('מחק לצמיתות'),
              ),
            ],
          ),
        ),
      ) ==
      true;
}

/// A preview is bound to the exact files and their current delivery state.
/// Changes always return to the confirmation dialog before any retry.
Future<MediaDeleteResult?> confirmPersonalMediaDeletion({
  required BuildContext context,
  required String api,
  required String token,
  required List<String> ids,
  required bool Function() isCurrent,
}) async {
  final chosen = ids.toSet().toList();
  final deleted = <String>{};
  final failed = <Map<String, dynamic>>[];
  var bytes = 0;
  var cleanupPending = 0;
  MediaDeleteResult? result() => deleted.isEmpty && failed.isEmpty
      ? null
      : MediaDeleteResult(
          deletedIds: deleted,
          failed: failed,
          deletedBytes: bytes,
          cleanupPendingCount: cleanupPending);

  Future<({int status, Map<String, dynamic> body})> post(
      String path, Map<String, dynamic> body) async {
    final response = await http
        .post(
          Uri.parse('$api/media-library/$path'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(Duration(seconds: path == 'delete-confirm' ? 120 : 20));
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const MediaDeleteException('לא התקבלה תשובה תקינה מהשרת');
    }
    return (
      status: response.statusCode,
      body: Map<String, dynamic>.from(decoded)
    );
  }

  for (var offset = 0; offset < chosen.length; offset += 1000) {
    if (!context.mounted || !isCurrent()) return result();
    final batch = chosen.skip(offset).take(1000).toList();
    try {
      final response = await post('delete-preview', {'ids': batch});
      if (!context.mounted || !isCurrent()) return result();
      if (response.status != 200) {
        throw MediaDeleteException(
          response.body['error']?.toString() ?? 'לא ניתן לבדוק את המחיקה כרגע',
        );
      }
      var preview = response.body;
      var changed = false;
      while (context.mounted && isCurrent()) {
        final previewIds =
            (preview['ids'] as List? ?? []).map((id) => id.toString()).toSet();
        if (previewIds.length != batch.length ||
            !previewIds.containsAll(batch) ||
            preview['confirmationToken'] is! String) {
          throw const MediaDeleteException(
              'פרטי המחיקה אינם תואמים לבחירה. יש לרענן ולנסות שוב.');
        }
        final confirmed = await _confirmPreview(context, preview,
            changed: changed, selectedCount: chosen.length - offset);
        if (!confirmed || !context.mounted || !isCurrent()) return result();
        final completed = await post('delete-confirm', {
          'ids': batch,
          'confirmationToken': preview['confirmationToken'],
        });
        if (!context.mounted || !isCurrent()) return result();
        if (completed.status == 409 &&
            completed.body['code'] == 'DELETE_PREVIEW_CHANGED' &&
            completed.body['preview'] is Map) {
          preview = Map<String, dynamic>.from(completed.body['preview'] as Map);
          changed = true;
          continue;
        }
        if (completed.status != 200) {
          throw MediaDeleteException(
              completed.body['error']?.toString() ?? 'מחיקת הקבצים נכשלה');
        }
        deleted.addAll((completed.body['deletedIds'] as List? ?? [])
            .map((id) => id.toString())
            .where(batch.contains));
        failed.addAll(_rows(completed.body['failed']));
        bytes += (completed.body['deletedBytes'] as num?)?.toInt() ?? 0;
        cleanupPending +=
            (completed.body['cleanupPendingCount'] as num?)?.toInt() ?? 0;
        break;
      }
    } catch (error) {
      if (!context.mounted || !isCurrent()) return result();
      final message = error is MediaDeleteException
          ? error.message
          : 'שגיאת תקשורת. לא התקבל אישור מלא למחיקה. יש לרענן את המדיה.';
      failed.addAll(batch
          .where((id) => !deleted.contains(id))
          .map((id) => {'id': id, 'error': message}));
      return result();
    }
  }
  return result();
}
