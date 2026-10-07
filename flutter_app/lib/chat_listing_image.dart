import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

const _messageUuidPattern =
    r'[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
final _messageId =
    RegExp('^$_messageUuidPattern' r'$', caseSensitive: false);
bool _isRequestImageId(String id) =>
    id.startsWith('request_') && _messageId.hasMatch(id.substring(8));

/// Called only for an explicit contact-request acknowledgement/history record.
/// This source identity is separate from the message id used for delivery.
String? contactRequestListingImageSourceId(Object? requestId) {
  final id = requestId?.toString() ?? '';
  if (_isRequestImageId(id)) return id;
  return _messageId.hasMatch(id) ? 'request_$id' : null;
}

String? chatListingImageSourceId(Map<String, dynamic> message) {
  final id = message['id']?.toString() ?? '';
  if (_isRequestImageId(id)) return id;
  if (!_messageId.hasMatch(id)) return null;
  if ((message['status'] ?? message['message_status']) ==
      'awaiting_contact_approval') {
    // A raw UUID cannot identify a request unless its producer explicitly binds
    // it to the request namespace. Never reinterpret arbitrary message ids.
    final source = message['listingImageSourceId'];
    return source == 'request_$id' ? source as String : null;
  }
  return id;
}

/// The server checks message access and moderation again before returning bytes.
bool canAddChatImageToListing(Map<String, dynamic> message,
    {String? currentUserId}) {
  final sourceId = chatListingImageSourceId(message);
  final url = message['fileUrl'] ?? message['file_url'];
  final status = message['status'] ?? message['message_status'];
  final moderation =
      message['moderationStatus'] ?? message['moderation_status'];
  final isRequest = sourceId != null && _isRequestImageId(sourceId);
  final sender = message['from'] ?? message['senderId'] ?? message['sender_id'];
  return sourceId != null &&
      (!isRequest ||
          status == 'awaiting_contact_approval' &&
              currentUserId != null && currentUserId.isNotEmpty &&
              sender?.toString() == currentUserId && moderation == 'approved') &&
      (message['fileType'] ?? message['type']) == 'image' &&
      url is String &&
      url.trim().isNotEmpty &&
      !const {
        'uploading',
        'pending_scan',
        'failed',
        'rejected_scan',
        'stopped_scan',
        'blocked_content',
        'rejected_request',
      }.contains(status) &&
      (moderation == null || moderation == 'approved') &&
      message['fileDeleted'] != true &&
      message['file_deleted'] != true &&
      message['filterHidden'] != true &&
      message['filter_hidden'] != true &&
      message['isUploadBatchNotice'] != true &&
      message['contentPurged'] != true &&
      message['content_purged_at'] == null &&
      message['scanStopped'] != true &&
      message['deletedForEveryone'] != true &&
      message['deleted_for_everyone'] != true &&
      message['isDeleted'] != true;
}

String chatListingImageUnavailableReason(Map<String, dynamic> message) {
  final status = message['status'] ?? message['message_status'];
  final moderation = message['moderationStatus'] ?? message['moderation_status'];
  if (message['fileDeleted'] == true || message['file_deleted'] == true ||
      message['contentPurged'] == true || message['content_purged_at'] != null ||
      message['deletedForEveryone'] == true ||
      message['deleted_for_everyone'] == true || message['isDeleted'] == true) {
    return 'התמונה אינה זמינה עוד';
  }
  if (message['filterHidden'] == true || message['filter_hidden'] == true) {
    return 'התמונה מוסתרת לפי הסינון';
  }
  if (message['scanStopped'] == true || status == 'stopped_scan') {
    return 'סריקת התמונה הופסקה';
  }
  if (status == 'pending_scan' || status == 'uploading' || moderation == 'pending') {
    return 'אפשר להוסיף לאחר השלמת הסריקה';
  }
  if (status == 'rejected_scan' || status == 'blocked_content' ||
      moderation != null && moderation != 'approved') {
    return 'התמונה לא אושרה בסריקה';
  }
  if (status == 'awaiting_contact_approval') {
    return 'התמונה ממתינה לאישור חברות ואינה זמינה להוספה למודעה';
  }
  if (chatListingImageSourceId(message) == null) {
    return 'התמונה אינה מקושרת להודעה שמורה בשיחה';
  }
  return 'התמונה אינה זמינה להוספה למודעה';
}

class ChatListingImageException implements Exception {
  const ChatListingImageException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Fetches only an approved, accessible source. This is not a listing approval;
/// the caller uploads the bytes through the normal listing scan before linking.
Future<XFile> loadChatListingImageSource({
  required String api,
  required String token,
  required String messageId,
  http.Client? client,
  Duration timeout = const Duration(seconds: 45),
}) async {
  const unavailable = 'לא ניתן לצרף את התמונה מהשיחה כרגע. נסה שוב';
  if (!(_messageId.hasMatch(messageId) || _isRequestImageId(messageId)) ||
      token.trim().isEmpty) {
    throw const ChatListingImageException(unavailable);
  }
  try {
    final get = client?.get ?? http.get;
    final response = await get(
      Uri.parse(
          '$api/messages/${Uri.encodeComponent(messageId)}/listing-image-source'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(timeout);
    if (response.statusCode != 200) {
      String? reason;
      try {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        if (data is Map && data['error'] is String) {
          reason = (data['error'] as String).trim();
        }
      } catch (_) {/* Non-JSON errors use the same clear fallback. */}
      throw ChatListingImageException(
          reason == null || reason.isEmpty ? unavailable : reason);
    }
    final headers = {
      for (final entry in response.headers.entries)
        entry.key.toLowerCase(): entry.value,
    };
    final mime = headers['content-type']?.split(';').first.trim().toLowerCase();
    const extensions = {
      'image/jpeg': 'jpg',
      'image/png': 'png',
      'image/webp': 'webp',
      'image/gif': 'gif',
    };
    final extension = extensions[mime];
    if (extension == null || response.bodyBytes.isEmpty) {
      throw const ChatListingImageException(unavailable);
    }
    var name = headers['x-image-file-name'] ?? '';
    try {
      name = Uri.decodeComponent(name);
    } catch (_) {
      name = '';
    }
    name = name
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .trim();
    if (!RegExp(r'\.(jpg|jpeg|png|webp|gif)$', caseSensitive: false)
        .hasMatch(name)) {
      name = 'chat-image.$extension';
    }
    // Native XFile derives name from path even for in-memory data. Web must
    // create its own Blob URL; supplying a filename as its path loses the bytes.
    return XFile.fromData(response.bodyBytes,
        name: name, path: kIsWeb ? null : name, mimeType: mime);
  } on ChatListingImageException {
    rethrow;
  } catch (_) {
    throw const ChatListingImageException(unavailable);
  }
}

class ChatListingImageTarget {
  const ChatListingImageTarget({this.listingId});
  final String? listingId;
  bool get isNewListing => listingId == null;
}

Future<ChatListingImageTarget?> showChatListingImageTargetChooser({
  required BuildContext context,
  required String api,
  required String token,
  http.Client? client,
}) =>
    showDialog<ChatListingImageTarget>(
      context: context,
      builder: (_) =>
          _ChatListingImageTargets(api: api, token: token, client: client),
    );

class _ChatListingImageTargets extends StatefulWidget {
  const _ChatListingImageTargets(
      {required this.api, required this.token, this.client});
  final String api, token;
  final http.Client? client;
  @override
  State<_ChatListingImageTargets> createState() =>
      _ChatListingImageTargetsState();
}

class _ChatListingImageTargetsState extends State<_ChatListingImageTargets> {
  final _items = <Map<String, dynamic>>[];
  bool _loading = false, _hasMore = true;
  int _page = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final get = widget.client?.get ?? http.get;
      final response = await get(
        Uri.parse('${widget.api}/listings?mine=true&page=$_page'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw const FormatException();
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! List) throw const FormatException();
      if (!mounted) return;
      setState(() {
        for (final item in data.whereType<Map>()) {
          final id = item['id'];
          if (id is String &&
              id.isNotEmpty &&
              !_items.any((existing) => existing['id'] == id)) {
            _items.add(Map<String, dynamic>.from(item));
          }
        }
        _hasMore = data.length == 20;
        _page++;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'לא ניתן לטעון את המודעות שלך כרגע');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          key: const ValueKey('chat-listing-image-targets'),
          title: const Text('לאיזו מודעה להוסיף?'),
          content: SizedBox(
            width: 360,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .6),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                  key: const ValueKey('chat-listing-image-new'),
                  leading: const Icon(Icons.post_add_outlined),
                  title: const Text('מודעה חדשה'),
                  onTap: () =>
                      Navigator.pop(context, const ChatListingImageTarget()),
                ),
                const Divider(),
                Flexible(
                    child: ListView(shrinkWrap: true, children: [
                  for (final item in _items) _listingTile(context, item),
                  if (_loading)
                    const Padding(
                        padding: EdgeInsets.all(12),
                        child: Center(child: CircularProgressIndicator())),
                  if (!_loading && _error == null && _items.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('אין לך מודעות קיימות')),
                  if (_error != null) ...[
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('נסה שוב')),
                  ] else if (!_loading && _hasMore)
                    TextButton(
                        onPressed: _load, child: const Text('מודעות נוספות')),
                ])),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('ביטול'))
          ],
        ),
      );

  Widget _listingTile(BuildContext context, Map<String, dynamic> item) {
    final images = item['images'];
    final count = images is List
        ? images.length
        : item['image_url'] == null
            ? 0
            : 1;
    final full = count >= 8;
    return ListTile(
      key: ValueKey('chat-listing-image-existing-${item['id']}'),
      leading: const Icon(Icons.article_outlined),
      title: Text(item['title']?.toString() ?? 'מודעה שלי',
          maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle:
          Text(full ? 'המודעה כבר כוללת 8 תמונות' : '$count מתוך 8 תמונות'),
      enabled: !full,
      onTap: full
          ? null
          : () => Navigator.pop(
              context, ChatListingImageTarget(listingId: item['id'] as String)),
    );
  }
}
