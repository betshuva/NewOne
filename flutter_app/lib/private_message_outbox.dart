import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-account, per-recipient records survive navigation and process death.
/// No automatic resend: the sender explicitly retries a failed message.
class PrivateMessageOutbox {
  final String accountId;
  final String recipientId;
  PrivateMessageOutbox(this.accountId, this.recipientId);
  String get _prefix => 'private_outbox_${accountId}_${recipientId}_';
  static final Set<String> sending = {};
  static Future<void>? _writes;

  static String newId() {
    final random = Random.secure();
    return 'msg_${DateTime.now().microsecondsSinceEpoch}_'
        '${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  Future<void> _write(Future<void> Function(SharedPreferences) action) {
    final operation = (_writes ?? Future<void>.value())
        .then((_) async => action(await SharedPreferences.getInstance()));
    final tail = operation.catchError((_) {});
    _writes = tail;
    tail.then((_) {
      if (identical(_writes, tail)) _writes = null;
    });
    return operation;
  }

  Future<void> save(Map<String, dynamic> message) {
    final key = '$_prefix${message['outboxId']}';
    final encoded = jsonEncode(message);
    return _write((prefs) async {
      if (!await prefs.setString(key, encoded)) {
        throw StateError('לא ניתן לשמור את ההודעה במכשיר');
      }
    });
  }

  Future<void> remove(String id) => _write((prefs) async {
        await prefs.remove('$_prefix$id');
      });

  Future<List<Map<String, dynamic>>> load() async {
    if (_writes != null) await _writes;
    final prefs = await SharedPreferences.getInstance();
    final rows = <Map<String, dynamic>>[];
    for (final key in prefs.getKeys().where((key) => key.startsWith(_prefix))) {
      final message =
          Map<String, dynamic>.from(jsonDecode(prefs.getString(key)!));
      message['status'] =
          sending.contains(message['outboxId']) ? 'sending' : 'failed';
      rows.add(message);
    }
    rows.sort((a, b) =>
        a['createdAt'].toString().compareTo(b['createdAt'].toString()));
    return rows;
  }
}
