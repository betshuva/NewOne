import 'dart:convert';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only device-owned names and addresses are persisted, never server profile
/// permissions or the app directory. Each account owns a separate cache.
class DeviceContactCache {
  static final Map<String, int> _epochs = {};
  final String accountId;
  DeviceContactCache(this.accountId);
  List<Map<String, dynamic>>? _memory;
  Future<List<Map<String, dynamic>>>? _refreshing;
  String get _key => 'device_contact_names_v1_$accountId';

  static String normalizePhone(String value) {
    var digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('972') && digits.length > 10) {
      digits = '0${digits.substring(3)}';
    }
    return digits;
  }

  Future<List<Map<String, dynamic>>> load(
      {bool requestPermission = false}) async {
    var granted = await Permission.contacts.isGranted;
    if (!granted && requestPermission) {
      granted = await FlutterContacts.requestPermission(readonly: true);
    }
    if (!granted) {
      _memory = null;
      await clear(accountId);
      return [];
    }
    if (_memory != null) return _memory!;
    final prefs = await SharedPreferences.getInstance();
    try {
      final cached = prefs.getString(_key);
      if (cached != null) {
        _memory = (jsonDecode(cached) as List).cast<Map<String, dynamic>>();
        refresh().ignore();
        return _memory!;
      }
    } catch (_) {
      await prefs.remove(_key);
    }
    return refresh();
  }

  Future<List<Map<String, dynamic>>> refresh() =>
      _refreshing ??= _read().whenComplete(() => _refreshing = null);

  Future<List<Map<String, dynamic>>> _read() async {
    final epoch = _epochs[accountId] ?? 0;
    if (!await Permission.contacts.isGranted) {
      _memory = null;
      await clear(accountId);
      return [];
    }
    final contacts = await FlutterContacts.getContacts(withProperties: true);
    final rows = <Map<String, dynamic>>[];
    for (final contact in contacts) {
      final phones = contact.phones
          .map((p) => normalizePhone(p.number))
          .where((p) => p.isNotEmpty)
          .toSet();
      final emails = contact.emails
          .map((e) => e.address.trim().toLowerCase())
          .where((e) => e.contains('@'))
          .toSet();
      // Preserve every number/email, so secondary phone numbers also match.
      for (final phone in phones.isEmpty ? [''] : phones) {
        for (final email in emails.isEmpty ? [''] : emails) {
          if (phone.isEmpty && email.isEmpty) continue;
          rows.add({
            'name': contact.displayName.trim().isEmpty
                ? (phone.isEmpty ? email : phone)
                : contact.displayName.trim(),
            'phone': phone,
            'email': email
          });
        }
      }
    }
    if (epoch != (_epochs[accountId] ?? 0)) return [];
    if (!await Permission.contacts.isGranted) {
      await clear(accountId);
      _memory = null;
      return [];
    }
    _memory = rows;
    final prefs = await SharedPreferences.getInstance();
    if (epoch != (_epochs[accountId] ?? 0)) return [];
    await prefs.setString(_key, jsonEncode(rows));
    if (epoch != (_epochs[accountId] ?? 0)) await prefs.remove(_key);
    return rows;
  }

  static Future<void> clear(String accountId) async {
    _epochs[accountId] = (_epochs[accountId] ?? 0) + 1;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('device_contact_names_v1_$accountId');
  }
}
