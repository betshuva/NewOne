import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class DriveStorageSummary extends StatefulWidget {
  final String api;
  final String token;
  final int revision;

  const DriveStorageSummary({
    super.key,
    required this.api,
    required this.token,
    required this.revision,
  });

  @override
  State<DriveStorageSummary> createState() => _DriveStorageSummaryState();
}

class _DriveStorageSummaryState extends State<DriveStorageSummary> {
  Map<String, dynamic>? _storage;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DriveStorageSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token ||
        oldWidget.api != widget.api ||
        oldWidget.revision != widget.revision) {
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _storage = null;
      _loading = true;
    });
    Map<String, dynamic>? storage;
    try {
      final response = await http.get(
        Uri.parse('${widget.api}/backup/google/storage'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        storage = jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {
      // A Drive failure must not prevent browsing the media library.
    }
    if (!mounted || generation != _generation) return;
    setState(() {
      _storage = storage;
      _loading = false;
    });
  }

  String _size(Object? bytes, {bool remaining = false}) {
    final value = num.tryParse('$bytes');
    if (value == null || !value.isFinite || value < 0) {
      throw const FormatException();
    }
    const kb = 1024;
    const mb = kb * 1024;
    const gb = mb * 1024;
    const tb = gb * 1024;
    // Keep remaining capacity in GB so rounding to TB does not hide usage.
    final (unit, divisor) = switch (value) {
      >= tb when !remaining => ('TB', tb),
      >= gb => ('GB', gb),
      >= mb => ('MB', mb),
      >= kb => ('KB', kb),
      _ => ('B', 1),
    };
    final decimals = unit == 'B'
        ? 0
        : unit == 'MB'
            ? 1
            : 2;
    return '\u2066${(value / divisor).toStringAsFixed(decimals)} $unit\u2069';
  }

  String get _label {
    if (_loading) return 'בודק מקום פנוי ב־Google Drive…';
    switch (_storage?['status']) {
      case 'disconnected':
        return 'Google Drive אינו מחובר';
      case 'reconnect_required':
        return 'יש לחבר מחדש את Google Drive להצגת המקום הפנוי';
      case 'available':
        if (_storage?['unlimited'] == true) {
          try {
            return 'בשימוש ב־Google: ${_size(_storage?['usedBytes'])} · ללא מגבלת אחסון מדווחת';
          } on FormatException {
            break;
          }
        }
        try {
          return 'בשימוש ב־Google: ${_size(_storage?['usedBytes'])} מתוך ${_size(_storage?['limitBytes'])}\n'
              'מקום פנוי לפי Google: ${_size(_storage?['freeBytes'], remaining: true)}';
        } on FormatException {
          break;
        }
    }
    return 'נתוני האחסון ב־Google Drive אינם זמינים כרגע';
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _label,
            key: const ValueKey('drive-storage-summary'),
            textDirection: TextDirection.rtl,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (!_loading && _storage?['status'] == 'available')
            const Text(
              'נתוני Google כוללים Drive, Gmail ו־Google Photos. בחשבון ארגוני המכסה עשויה להיות משותפת לארגון.',
              textDirection: TextDirection.rtl,
              style: TextStyle(color: Color(0xFFD8EAF8), fontSize: 12),
            ),
        ],
      );
}
