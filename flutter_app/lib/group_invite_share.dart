import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class GroupInviteShareScreen extends StatefulWidget {
  const GroupInviteShareScreen({
    super.key,
    required this.api,
    required this.token,
    required this.group,
  });

  final String api;
  final String token;
  final Map<String, dynamic> group;

  @override
  State<GroupInviteShareScreen> createState() => _GroupInviteShareScreenState();
}

class _GroupInviteShareScreenState extends State<GroupInviteShareScreen> {
  String? _url;
  String? _error;
  bool _loading = true;

  String get _name => widget.group['name']?.toString() ?? 'הקבוצה';
  String get _message =>
      'ממשיכים את קבוצת „$_name” בבתשובה. לחצו להצטרפות — אפשר להתחיל ישר מהדפדפן:\n$_url';

  @override
  void initState() {
    super.initState();
    _loadLink();
  }

  Future<void> _loadLink({bool reset = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await http
          .post(
            Uri.parse('${widget.api}/groups/${widget.group['id']}/invite-link'),
            headers: {
              'Authorization': 'Bearer ${widget.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'reset': reset}),
          )
          .timeout(const Duration(seconds: 20));
      final data = jsonDecode(response.body);
      if (response.statusCode != 200 || data is! Map) {
        throw StateError(data is Map
            ? data['error']?.toString() ?? 'לא ניתן ליצור קישור כרגע'
            : 'לא ניתן ליצור קישור כרגע');
      }
      final url = Uri.tryParse(data['url']?.toString() ?? '');
      if (url == null ||
          url.scheme != 'https' ||
          url.host != 'betshuva.com' ||
          url.path != '/betshuva-app/group-invite.html' ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$')
              .hasMatch(url.queryParameters['groupInvite'] ?? '')) {
        throw StateError('השרת לא החזיר קישור הזמנה תקין');
      }
      if (mounted) setState(() => _url = url.toString());
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is StateError
            ? error.message.toString()
            : 'לא ניתן ליצור קישור כרגע. בדקו את החיבור ונסו שוב.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy({bool message = false}) async {
    await Clipboard.setData(ClipboardData(text: message ? _message : _url!));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(message ? 'הודעת ההזמנה הועתקה' : 'הקישור הועתק')));
    }
  }

  Future<void> _share() async {
    try {
      final opened = await launchUrl(
        Uri.https('wa.me', '/', {'text': _message}),
        mode: LaunchMode.externalApplication,
      );
      if (opened || !mounted) return;
    } catch (_) {}
    if (mounted) await _copy(message: true);
  }

  Future<void> _reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('חידוש קישור ההזמנה'),
        content: const Text(
            'הקישור הקודם יפסיק לפעול. חברים שכבר הצטרפו יישארו בקבוצה.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('חדש קישור')),
        ],
      ),
    );
    if (confirmed == true && mounted) await _loadLink(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final ready = !_loading && _error == null && _url != null;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('מזמינים את הקבוצה מוואטסאפ')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Icon(Icons.groups_outlined,
                    size: 64, color: Color(0xFF1B6CA8)),
                const SizedBox(height: 16),
                Text(_name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 25, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                const Text(
                    'שלחו הודעה אחת בקבוצת הוואטסאפ. כל חבר יוכל להצטרף מאותו קישור, גם דרך הדפדפן.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 24),
                if (_loading) const Center(child: CircularProgressIndicator()),
                if (_error != null) ...[
                  Text(_error!, textAlign: TextAlign.center),
                  TextButton.icon(
                      onPressed: () => _loadLink(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('נסה שוב')),
                ],
                if (ready) ...[
                  FilledButton.icon(
                    key: const ValueKey('share-group-in-whatsapp'),
                    onPressed: _share,
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('שתף בקבוצת וואטסאפ'),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52)),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                      onPressed: () => _copy(message: true),
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('העתק הודעת הזמנה')),
                  const SizedBox(height: 20),
                  SelectableText(_url!,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.center),
                  TextButton(
                      onPressed: _copy, child: const Text('העתק רק את הקישור')),
                  const SizedBox(height: 12),
                  const Text(
                      'כל מי שמחזיק בקישור יכול להצטרף. אפשר לחדש אותו כדי לעצור הצטרפות דרך קישור קודם.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.black54)),
                  TextButton(
                      onPressed: _reset, child: const Text('חדש קישור הזמנה')),
                ],
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('פתח את הקבוצה'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
