import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic>? decodeGuideMessageDraft(String? encoded) {
  if (encoded == null || encoded.length > 12000) return null;
  try {
    final value =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))));
    if (value is! Map ||
        value['text'] is! String ||
        value['recipientQuery'] is! String ||
        (value['text'] as String).length > 2000 ||
        (value['recipientQuery'] as String).length > 120) {
      return null;
    }
    return Map<String, dynamic>.from(value);
  } catch (_) {
    return null;
  }
}

class GuideMessageDraftCard extends StatefulWidget {
  final Map<String, dynamic> draft;
  final String api;
  final http.Client? client;
  final String token;
  final String messageId;
  const GuideMessageDraftCard(
      {super.key,
      required this.api,
      this.client,
      required this.draft,
      required this.token,
      required this.messageId});
  @override
  State<GuideMessageDraftCard> createState() => _GuideMessageDraftCardState();
}

class _GuideMessageDraftCardState extends State<GuideMessageDraftCard> {
  late final http.Client _client = widget.client ?? http.Client();
  late final TextEditingController _text =
      TextEditingController(text: widget.draft['text'] as String);
  late final TextEditingController _search =
      TextEditingController(text: widget.draft['recipientQuery'] as String);
  List<Map<String, dynamic>> _contacts = [];
  Map<String, dynamic>? _selected;
  bool _checking = true;
  bool _ready = false;
  bool _busy = false;
  bool _sent = false;
  bool _requestPending = false;
  bool _dismissed = false;
  String? _error;
  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json'
      };
  String get _dismissKey => 'guide_message_dismissed:${widget.messageId}';
  String get _query => _search.text.trim().toLowerCase();
  List<Map<String, dynamic>> get _matches => _contacts
      .where((contact) => [contact['name'], contact['phone'], contact['email']]
          .any((value) =>
              (value ?? '').toString().toLowerCase().contains(_query)))
      .toList();
  bool get _canSend =>
      _ready &&
      !_checking &&
      !_busy &&
      !_sent &&
      !_dismissed &&
      _selected != null &&
      _text.text.trim().isNotEmpty;

  void _selectUniqueMatch() {
    final matches = _matches;
    _selected =
        _query.isNotEmpty && matches.length == 1 ? matches.single : null;
  }

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _text.dispose();
    _search.dispose();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  Future<void> _restore() async {
    setState(() {
      _checking = true;
      _ready = false;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final response = await _client
          .get(
              Uri.parse(
                  '${widget.api}/guide-message-drafts/${widget.messageId}'),
              headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('לא ניתן לבדוק את מצב הטיוטה. נסה שוב.');
      }
      final value = jsonDecode(response.body) as Map;
      if (!mounted) return;
      _sent = value['sent'] == true;
      _requestPending = value['result']?['requestPending'] == true;
      _dismissed = prefs.getBool(_dismissKey) == true;
      if (_sent || _dismissed) return;
      final recipients = await _client
          .get(Uri.parse('${widget.api}/guide-message-recipients'),
              headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (recipients.statusCode != 200) {
        throw Exception('לא ניתן לטעון אנשי קשר. נסה שוב.');
      }
      if (!mounted) return;
      _contacts =
          (jsonDecode(recipients.body) as List).cast<Map<String, dynamic>>();
      _selectUniqueMatch();
      _ready = true;
    } catch (error) {
      if (mounted) {
        _error = error.toString().replaceFirst('Exception: ', '');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _send() async {
    if (!_canSend) return;
    final approved = {
      'toUserId': _selected!['id'],
      'text': _text.text.trim(),
      'confirmed': true,
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = await _client
          .post(
              Uri.parse(
                  '${widget.api}/guide-message-drafts/${widget.messageId}/send'),
              headers: _headers,
              body: jsonEncode(approved))
          .timeout(const Duration(seconds: 45));
      final data = jsonDecode(sent.body) as Map;
      if (sent.statusCode != 200) {
        throw Exception(data['error'] ?? 'השליחה לא הושלמה');
      }
      if (mounted) {
        setState(() {
          _sent = true;
          _requestPending = data['requestPending'] == true;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is Exception
            ? error.toString().replaceFirst('Exception: ', '')
            : 'לא ניתן לשלוח כעת. אפשר לנסות שוב בבטחה.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dismiss() async {
    if (_busy) return;
    setState(() => _dismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_dismissKey, true);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Padding(
          padding: EdgeInsets.all(8), child: LinearProgressIndicator());
    }
    if (_sent) {
      return Text(_requestPending
          ? 'נשלחה בקשת הודעה הממתינה לאישור הנמען'
          : 'ההודעה נשלחה');
    }
    if (_dismissed) return const Text('הטיוטה בוטלה');
    final matches = _matches;
    return Card(
        child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('טיוטת הודעה — ממתינה לאישור',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        TextField(
          controller: _search,
          enabled: _ready && !_busy,
          textDirection: TextDirection.rtl,
          decoration: const InputDecoration(labelText: 'חיפוש איש קשר שמור'),
          onChanged: (_) => setState(_selectUniqueMatch),
        ),
        if (_ready) ...[
          const SizedBox(height: 8),
          if (matches.isEmpty)
            const Text(
                'לא נמצאו אנשי קשר. אפשר לשנות את החיפוש או לשמור איש קשר במסך השיחות.')
          else ...[
            if (_selected == null) const Text('בחר את הנמען לשליחה'),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: ListView(
                shrinkWrap: true,
                children: matches
                    .map((contact) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(contact['name']?.toString() ?? ''),
                          subtitle: Text([contact['phone'], contact['email']]
                              .where((value) =>
                                  value != null && value.toString().isNotEmpty)
                              .join(' · ')),
                          selected: _selected?['id'] == contact['id'],
                          leading: Icon(_selected?['id'] == contact['id']
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off),
                          onTap: _busy
                              ? null
                              : () => setState(() => _selected = contact),
                        ))
                    .toList(),
              ),
            ),
          ],
        ],
        const SizedBox(height: 8),
        TextField(
          controller: _text,
          enabled: _ready && !_busy,
          minLines: 2,
          maxLines: 5,
          maxLength: 2000,
          textDirection: TextDirection.rtl,
          decoration: const InputDecoration(labelText: 'תוכן ההודעה שתישלח'),
          onChanged: (_) => setState(() {}),
        ),
        if (_selected != null)
          Text('ההודעה תישלח בשמך אל ${_selected!['name']}.',
              style: const TextStyle(fontWeight: FontWeight.bold)),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.red)),
        if (_busy) const LinearProgressIndicator(),
        Wrap(spacing: 8, children: [
          FilledButton(
              onPressed: _canSend ? _send : null,
              child: const Text('אישור ושליחה')),
          TextButton(
              onPressed: _busy ? null : _dismiss, child: const Text('ביטול')),
          if (_error != null)
            TextButton(
                onPressed: _busy ? null : _restore,
                child: const Text('בדיקת מצב')),
        ]),
      ]),
    ));
  }
}
