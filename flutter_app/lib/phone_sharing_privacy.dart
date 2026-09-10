import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'phone_sharing.dart';

class PhoneSharingPrivacyScreen extends StatefulWidget {
  final String api;
  final String token;
  const PhoneSharingPrivacyScreen(
      {super.key, required this.api, required this.token});

  @override
  State<PhoneSharingPrivacyScreen> createState() =>
      _PhoneSharingPrivacyScreenState();
}

class _PhoneSharingPrivacyScreenState extends State<PhoneSharingPrivacyScreen> {
  List<Map<String, dynamic>> _grants = [];
  List<Map<String, dynamic>> _requests = [];
  bool _loading = true;
  String? _busyId;
  String? _error;
  late final StreamSubscription<String> _changes;

  @override
  void initState() {
    super.initState();
    _load();
    _changes = phoneSharingChanges.stream.listen((_) {
      if (_busyId == null) _load();
    });
  }

  @override
  void dispose() {
    _changes.cancel();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _rows(String kind) async {
    final response = await http
        .get(Uri.parse('${widget.api}/phone-sharing/$kind'), headers: {
      'Authorization': 'Bearer ${widget.token}',
      'Cache-Control': 'no-store'
    });
    if (response.statusCode != 200) throw Exception();
    final data = jsonDecode(response.body);
    final rows = data is List
        ? data
        : data is Map
            ? data[kind]
            : null;
    if (rows is! List) throw Exception();
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<void> _load() async {
    try {
      final rows = await Future.wait([_rows('grants'), _rows('requests')]);
      if (mounted) {
        setState(() {
          _grants = rows[0];
          _requests = rows[1];
          _loading = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'לא ניתן לטעון את הרשאות הטלפון';
        });
      }
    }
  }

  Future<void> _choose(String id, Map<String, dynamic> choice) async {
    if (_busyId != null) return;
    setState(() {
      _busyId = id;
      _error = null;
    });
    try {
      await updatePhoneSharing(widget.api, widget.token, id, choice);
      await _load();
    } catch (_) {
      if (mounted) setState(() => _error = 'עדכון ההרשאה נכשל. נסה שוב.');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('שיתוף מספר הטלפון')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                      'כאן ניתן לראות למי אישרת לצפות במספר הטלפון שלך ולבטל הרשאה. מספר שכבר שמור בטלפון של החבר יישאר אצלו.'),
                  if (_error != null)
                    TextButton(
                        onPressed: _load, child: Text('$_error — נסה שוב')),
                  if (_requests.isNotEmpty) ...[
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('בקשות שממתינות לאישור',
                            style: TextStyle(fontWeight: FontWeight.bold))),
                    ..._requests.map((request) {
                      final id = request['user_id'].toString();
                      return Card(
                          child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(request['name']?.toString() ?? 'חבר'),
                                  Wrap(spacing: 8, children: [
                                    FilledButton(
                                        onPressed: _busyId != null
                                            ? null
                                            : () => _choose(id,
                                                {'phone_response': 'approve'}),
                                        child: const Text(
                                            'אשר ושתף את הטלפון שלי')),
                                    TextButton(
                                        onPressed: _busyId != null
                                            ? null
                                            : () => _choose(id,
                                                {'phone_response': 'decline'}),
                                        child: const Text('דחה')),
                                  ])
                                ],
                              )));
                    }),
                  ],
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('חברים שקיבלו הרשאה',
                          style: TextStyle(fontWeight: FontWeight.bold))),
                  if (_grants.isEmpty)
                    const Text('אין כרגע הרשאות שיתוף פעילות'),
                  ..._grants.map((grant) => ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text(grant['name']?.toString() ?? 'חבר'),
                        trailing: TextButton(
                            onPressed: _busyId != null
                                ? null
                                : () => _choose(grant['user_id'].toString(),
                                    {'share_my_phone': false}),
                            child: const Text('בטל הרשאה')),
                      )),
                  if (_busyId != null) const LinearProgressIndicator(),
                ],
              ),
      );
}
