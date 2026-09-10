import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ConversationCleanupResult {
  final bool hidden;
  final DateTime? clearedAt;
  final int clearedMessages;
  final Map<String, dynamic> media;

  ConversationCleanupResult.fromJson(Map<String, dynamic> json)
      : hidden = json['hidden'] == true,
        clearedAt = DateTime.tryParse(json['clearedAt']?.toString() ?? ''),
        clearedMessages = (json['clearedMessages'] as num?)?.toInt() ?? 0,
        media = Map<String, dynamic>.from(json['media'] as Map? ?? const {});

  String get summary {
    final parts = <String>[hidden ? 'השיחה נמחקה מהרשימה שלך' : 'השיחה נוקתה'];
    final deleted = (media['deleted'] as num?)?.toInt() ?? 0;
    final skipped = (media['skipped'] as num?)?.toInt() ?? 0;
    final failed = (media['failed'] as num?)?.toInt() ?? 0;
    if (deleted > 0) parts.add('$deleted קבצים נמחקו');
    if (skipped > 0) parts.add('$skipped קבצים נשמרו כי הם משותפים או בשימוש');
    if (failed > 0) {
      parts.add('לא הושלמה מחיקת $failed קבצים. אפשר לנסות מהמדיה שלי');
    }
    return parts.join('. ');
  }
}

class ConversationChange {
  final String accountId;
  final String kind;
  final String targetId;
  final ConversationCleanupResult result;

  const ConversationChange(
      this.accountId, this.kind, this.targetId, this.result);
}

final conversationChanges =
    StreamController<ConversationChange>.broadcast(sync: true);

Map<String, dynamic> conversationListAfter(
    Map<String, dynamic> item, ConversationCleanupResult result) {
  final lastMessage =
      DateTime.tryParse(item['last_message_at']?.toString() ?? '');
  if (result.clearedAt != null &&
      lastMessage != null &&
      lastMessage.isAfter(result.clearedAt!)) {
    return item;
  }
  return {
    ...item,
    'conversation_hidden': result.hidden,
    if (result.clearedAt != null) ...{
      'last_message': null,
      'last_message_type': null,
      'last_message_at': null,
      'last_message_status': null,
      'last_message_sender_name': null,
    },
  };
}

bool conversationMessageAfter(Map<String, dynamic> message, DateTime? cutoff) {
  if (cutoff == null) return true;
  final createdAt = DateTime.tryParse(
      (message['createdAt'] ?? message['created_at'])?.toString() ?? '');
  return createdAt != null && createdAt.isAfter(cutoff);
}

Future<void> reopenConversation(
    {required String api,
    required String token,
    required String accountId,
    required String kind,
    required String targetId}) async {
  try {
    final response = await http.post(
        Uri.parse('$api/conversations/$kind/$targetId/open'),
        headers: {'Authorization': 'Bearer $token'});
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return;
      conversationChanges.add(ConversationChange(
          accountId, kind, targetId, ConversationCleanupResult.fromJson(data)));
    }
  } catch (_) {}
}

Future<ConversationCleanupResult?> showConversationCleanupDialog(
        BuildContext context,
        {required String api,
        required String token,
        required String kind,
        required String targetId,
        required String name,
        required bool deleteConversation}) =>
    showDialog<ConversationCleanupResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ConversationCleanupDialog(
          api: api,
          token: token,
          kind: kind,
          targetId: targetId,
          name: name,
          deleteConversation: deleteConversation),
    );

class ConversationCleanupDialog extends StatefulWidget {
  final String api, token, kind, targetId, name;
  final bool deleteConversation;

  const ConversationCleanupDialog(
      {super.key,
      required this.api,
      required this.token,
      required this.kind,
      required this.targetId,
      required this.name,
      required this.deleteConversation});

  @override
  State<ConversationCleanupDialog> createState() =>
      _ConversationCleanupDialogState();
}

class _ConversationCleanupDialogState extends State<ConversationCleanupDialog> {
  bool _deleteMedia = false;
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final response = await http.post(
        Uri.parse(
            '${widget.api}/conversations/${widget.kind}/${widget.targetId}/clear'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({
          'deleteConversation': widget.deleteConversation,
          'deleteMedia': _deleteMedia
        }),
      );
      final data = jsonDecode(response.body);
      if (response.statusCode != 200 ||
          data is! Map<String, dynamic> ||
          data['ok'] != true) {
        throw StateError(data is Map
            ? data['error']?.toString() ?? 'הפעולה נכשלה'
            : 'הפעולה נכשלה');
      }
      if (mounted) {
        Navigator.pop(context, ConversationCleanupResult.fromJson(data));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is StateError
              ? error.message.toString()
              : 'לא התקבל אישור מהשרת. אפשר לנסות שוב.';
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_busy,
        child: Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title:
                  Text(widget.deleteConversation ? 'מחיקת שיחה' : 'ניקוי שיחה'),
              content: SizedBox(
                  width: 420,
                  child: SingleChildScrollView(
                      child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'ההודעות בשיחה עם „${widget.name}” יוסרו אצלך בלבד.'),
                      if (widget.deleteConversation) ...[
                        const SizedBox(height: 8),
                        Text(widget.kind == 'group'
                            ? 'השיחה תוסר מהרשימה. החברות בקבוצה תישמר, והודעה חדשה תחזיר את השיחה לרשימה.'
                            : 'השיחה תוסר מהרשימה. איש הקשר יישמר, והודעה חדשה תחזיר את השיחה לרשימה.'),
                      ],
                      const SizedBox(height: 12),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _deleteMedia,
                        onChanged: _busy
                            ? null
                            : (value) =>
                                setState(() => _deleteMedia = value ?? false),
                        title: const Text('מחק גם קבצים מהמדיה שלי ומה־Drive'),
                        subtitle: const Text(
                            'קבצים שבבעלותך ואינם בשימוש יימחקו לצמיתות. קבצים משותפים יישמרו. ללא סימון, הקבצים יישארו במדיה שלך.'),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      if (_error != null)
                        Text(_error!,
                            style: const TextStyle(color: Colors.red)),
                    ],
                  ))),
              actions: [
                TextButton(
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    child: const Text('ביטול')),
                FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(widget.deleteConversation
                            ? 'מחק שיחה'
                            : 'נקה שיחה')),
              ],
            )),
      );
}
