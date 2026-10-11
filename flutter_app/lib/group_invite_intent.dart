import 'package:shared_preferences/shared_preferences.dart';

/// Keeps a shared group invitation through registration and app reloads.
class GroupInviteIntentStore {
  const GroupInviteIntentStore();

  static const _pendingKey = 'pending_group_invite_v1';
  static const _consumedKey = 'consumed_group_invite_v1';
  static const _consumedAccountKey = 'consumed_group_invite_account_v1';
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static Future<void>? _operations;

  static bool _isValidToken(String token) =>
      token.length == 43 && _tokenPattern.hasMatch(token);

  /// Duplicate or malformed query values cannot replace an existing invite.
  static String? tokenFromUri(Uri uri) {
    final values = uri.queryParametersAll['groupInvite'];
    if (values == null || values.length != 1) return null;
    return _isValidToken(values.single) ? values.single : null;
  }

  static String? _storedToken(SharedPreferences prefs, String key) {
    final value = prefs.get(key);
    return value is String && _isValidToken(value) ? value : null;
  }

  static String? _pendingToken(SharedPreferences prefs) {
    final pending = _storedToken(prefs, _pendingKey);
    return pending == _storedToken(prefs, _consumedKey) ? null : pending;
  }

  static String? _accountId(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  // Serialize reads and changes across instances so a completed older join
  // cannot erase a newer link opened while its request was in flight.
  static Future<T> _withPreferences<T>(
      Future<T> Function(SharedPreferences) action) {
    final operation = (_operations ?? Future<void>.value())
        .then((_) async => action(await SharedPreferences.getInstance()));
    final tail = operation.then<void>((_) {}, onError: (Object error) {});
    _operations = tail;
    tail.then((_) {
      if (identical(_operations, tail)) _operations = null;
    });
    return operation;
  }

  /// Capture once at startup, before selecting the login or home screen.
  /// A consumed URL is ignored on reload; another pending invite is retained.
  Future<String?> captureFromUri(Uri uri, {String? accountId}) =>
      _withPreferences((prefs) async {
        final token = tokenFromUri(uri);
        final account = _accountId(accountId);
        final consumedAccount = _accountId(prefs.get(_consumedAccountKey));
        if (token != null &&
            token == _storedToken(prefs, _consumedKey) &&
            account != null &&
            consumedAccount != null &&
            account != consumedAccount) {
          // A different person can accept the same link after switching
          // accounts. Startup without an account still ignores URL reloads.
          if (!await prefs.remove(_consumedKey) ||
              !await prefs.remove(_consumedAccountKey)) {
            throw StateError('לא ניתן לעדכן את ההזמנה לקבוצה');
          }
        }
        if (token != null && token != _storedToken(prefs, _consumedKey)) {
          if (!await prefs.setString(_pendingKey, token)) {
            throw StateError('לא ניתן לשמור את ההזמנה לקבוצה');
          }
        }
        return _pendingToken(prefs);
      });

  Future<String?> read() =>
      _withPreferences((prefs) async => _pendingToken(prefs));

  /// Call only after joining succeeds. A failed request remains retryable.
  Future<void> consume(String token, {String? accountId}) =>
      _complete(token, accountId: accountId);

  /// Permanently invalid or revoked invitations should not reappear on reload.
  /// Temporary connection and server failures must remain pending instead.
  Future<void> discard(String token) => _complete(token);

  Future<void> _complete(String token, {String? accountId}) {
    if (!_isValidToken(token)) {
      return Future<void>.error(ArgumentError('קוד ההזמנה אינו תקין'));
    }
    return _withPreferences((prefs) async {
      final account = _accountId(accountId);
      final accountSaved = account == null
          ? await prefs.remove(_consumedAccountKey)
          : await prefs.setString(_consumedAccountKey, account);
      if (!accountSaved) {
        throw StateError('לא ניתן לשמור את השלמת ההצטרפות לקבוצה');
      }
      if (!await prefs.setString(_consumedKey, token)) {
        throw StateError('לא ניתן לשמור את השלמת ההצטרפות לקבוצה');
      }
      if (_storedToken(prefs, _pendingKey) == token) {
        if (!await prefs.remove(_pendingKey)) {
          throw StateError('לא ניתן לנקות את ההזמנה לקבוצה');
        }
      }
    });
  }
}
