import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Keep a device draft separate for each signed-in account. Never store tokens.
String? listingDraftAccountId(Map<String, dynamic>? profile, String token) {
  final profileId = profile?['id']?.toString();
  if (profileId != null && profileId.isNotEmpty) return profileId;
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    if (claims is! Map) return null;
    return (claims['id'] ?? claims['sub'] ?? claims['userId'])?.toString();
  } catch (_) {
    return null;
  }
}

class ListingFormDraftStore {
  ListingFormDraftStore(String accountId)
      : _key = 'listing_form_draft_v1_${Uri.encodeComponent(accountId)}';

  final String _key;
  static final Map<String, Future<void>> _writes = {};

  Future<Map<String, dynamic>?> load() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.reload();
    final raw = preferences.getString(_key);
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw);
      if (data is Map<String, dynamic> && data['version'] == 1) return data;
    } catch (_) {
      // A damaged/older draft must not prevent opening a new listing.
    }
    return null;
  }

  Future<void> _enqueue(Future<void> Function() write) {
    final previous = _writes[_key] ?? Future<void>.value();
    final next = previous.then((_) => write());
    late final Future<void> tail;
    void clear() {
      if (identical(_writes[_key], tail)) _writes.remove(_key);
    }

    tail = next.then<void>((_) => clear(),
        onError: (Object _, StackTrace __) => clear());
    _writes[_key] = tail;
    return next;
  }

  Future<void> save(Map<String, dynamic> data) => _enqueue(() async {
        final preferences = await SharedPreferences.getInstance();
        if (!await preferences.setString(_key, jsonEncode(data))) {
          throw StateError('שמירת הטיוטה נכשלה');
        }
      });

  /// Link uploads to the saved snapshot without replacing newer text or drafts.
  Future<void> updateMedia(String revision, List<String?> images,
          {String? videoUrl, bool updateVideo = false}) =>
      _enqueue(() async {
        final draft = await load();
        if (draft == null || draft['revision'] != revision) return;
        draft['images'] = images;
        if (updateVideo) draft['video_url'] = videoUrl;
        final preferences = await SharedPreferences.getInstance();
        if (!await preferences.setString(_key, jsonEncode(draft))) {
          throw StateError('שמירת המדיה בטיוטה נכשלה');
        }
      });

  Future<void> remove() => _enqueue(() async {
        final preferences = await SharedPreferences.getInstance();
        if (!await preferences.remove(_key)) {
          throw StateError('מחיקת הטיוטה נכשלה');
        }
      });
}
