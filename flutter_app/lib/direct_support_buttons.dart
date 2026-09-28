import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class DirectSupportButtons extends StatelessWidget {
  final String api, token, appVersion;
  final http.Client? client;
  const DirectSupportButtons(
      {super.key,
      required this.api,
      required this.token,
      required this.appVersion,
      this.client});

  Future<void> _open(BuildContext context, String type) async {
    final sent = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SupportForm(
            api: api,
            token: token,
            appVersion: appVersion,
            type: type,
            client: client));
    if (sent == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('הפנייה נשלחה. אפשר לעקוב אחריה ב״הפניות שלי״')));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(spacing: 8, runSpacing: 4, children: [
          OutlinedButton.icon(
              onPressed: () => _open(context, 'feature'),
              icon: const Icon(Icons.lightbulb_outline, size: 18),
              label: const Text('בקשה לשיפור')),
          OutlinedButton.icon(
              onPressed: () => _open(context, 'bug'),
              icon: const Icon(Icons.bug_report_outlined, size: 18),
              label: const Text('דיווח על תקלה')),
        ]),
      );
}

class _SupportForm extends StatefulWidget {
  final String api, token, appVersion, type;
  final http.Client? client;
  const _SupportForm(
      {required this.api,
      required this.token,
      required this.appVersion,
      required this.type,
      this.client});
  @override
  State<_SupportForm> createState() => _SupportFormState();
}

class _SupportFormState extends State<_SupportForm> {
  final _text = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _sending = false;
  String? _error;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || !_form.currentState!.validate()) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final post = widget.client?.post ?? http.post;
      final response = await post(Uri.parse('${widget.api}/support-issues'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({
            'issueType': widget.type,
            'description': _text.text.trim(),
            'clientContext': {
              'appVersion': widget.appVersion,
              'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
              'screen': 'israel-chat'
            }
          })).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (response.statusCode == 200 || response.statusCode == 201) {
        Navigator.pop(context, true);
        return;
      }
      final data = jsonDecode(response.body);
      setState(() => _error = data is Map
          ? data['error']?.toString() ?? 'לא ניתן לשלוח את הפנייה'
          : 'לא ניתן לשלוח את הפנייה');
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'לא התקבל אישור מהשרת. בדוק ב״הפניות שלי״ לפני ניסיון נוסף.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_sending,
      child: AlertDialog(
        title: Text(widget.type == 'feature' ? 'בקשה לשיפור' : 'דיווח על תקלה'),
        content: SingleChildScrollView(
            child: SizedBox(
                width: 420,
                child: Form(
                    key: _form,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextFormField(
                          controller: _text,
                          autofocus: true,
                          enabled: !_sending,
                          minLines: 4,
                          maxLines: 8,
                          maxLength: 1200,
                          textDirection: TextDirection.rtl,
                          decoration: InputDecoration(
                              labelText: widget.type == 'feature'
                                  ? 'מה תרצה לשפר?'
                                  : 'מה קרה ומה ציפית שיקרה?'),
                          validator: (value) => (value?.trim().length ?? 0) < 5
                              ? 'יש להזין לפחות 5 תווים'
                              : null),
                      if (_error != null)
                        Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                    ])))),
        actions: [
          TextButton(
              onPressed: _sending ? null : () => Navigator.pop(context),
              child: const Text('ביטול')),
          FilledButton(
              onPressed: _sending ? null : _send,
              child: Text(_sending ? 'שולח…' : 'שליחת הפנייה')),
        ],
      ));
}
