import 'dart:math' as math;
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

List<String> recipientListValues(String text) {
  final cells = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '"') {
      if (quoted && i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (!quoted && ',;\n\r\t'.contains(c)) {
      if (cell.isNotEmpty) cells.add(cell.toString().trim());
      cell.clear();
    } else {
      cell.write(c);
    }
  }
  if (cell.isNotEmpty) cells.add(cell.toString().trim());
  return cells.where((v) => v.isNotEmpty).toList();
}

String _normalized(String value) =>
    value.replaceAll('\uFEFF', '').trim().toLowerCase();

Set<String> matchEducationRecipients(
    String text, List<Map<String, dynamic>> members) {
  final values = recipientListValues(text).map(_normalized).toSet();
  return members
      .where((m) => ['id', 'name', 'email', 'phone'].any((key) {
            final value = _normalized(m[key]?.toString() ?? '');
            return value.isNotEmpty && values.contains(value);
          }))
      .map((m) => m['id'].toString())
      .toSet();
}

bool educationFormMatches(Map<String, dynamic> form, String query) {
  final text = [
    form['title'],
    form['description'],
    form['file_name'],
    for (final q in (form['questions'] as List? ?? [])) q['text']
  ].join(' ').toLowerCase();
  return text.contains(query.trim().toLowerCase());
}

Future<List<String>?> showEducationRecipientsDialog(
  BuildContext context, {
  required String api,
  required String token,
  required String groupId,
  List<String>? initialIds,
  Set<String> excludeIds = const {},
}) async {
  final response = await http.get(Uri.parse('$api/groups/$groupId'),
      headers: {'Authorization': 'Bearer $token'});
  final data = jsonDecode(response.body) as Map<String, dynamic>;
  if (response.statusCode != 200)
    throw Exception(data['error'] ?? 'טעינת הנמענים נכשלה');
  final members = (data['members'] as List)
      .map((m) => Map<String, dynamic>.from(m))
      .where(
          (m) => m['id'] != data['viewer_id'] && !excludeIds.contains(m['id']))
      .toList();
  if (!context.mounted) return null;
  return showDialog<List<String>>(
      context: context,
      builder: (_) =>
          _RecipientDialog(members: members, initialIds: initialIds));
}

class _RecipientDialog extends StatefulWidget {
  const _RecipientDialog({required this.members, this.initialIds});
  final List<Map<String, dynamic>> members;
  final List<String>? initialIds;
  @override
  State<_RecipientDialog> createState() => _RecipientDialogState();
}

class _RecipientDialogState extends State<_RecipientDialog> {
  late final Set<String> _selected = widget.initialIds?.toSet() ??
      widget.members.map((m) => m['id'].toString()).toSet();
  String _query = '', _notice = '';
  Future<void> _import() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
          withData: true,
          type: FileType.custom,
          allowedExtensions: ['csv', 'txt']);
      if (picked == null || !mounted) return;
      final bytes = picked.files.single.bytes;
      if (bytes == null || bytes.length > 1024 * 1024)
        throw Exception('יש לבחור קובץ עד 1MB');
      final matches =
          matchEducationRecipients(utf8.decode(bytes), widget.members);
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _selected.addAll(matches);
        _notice =
            'נבחרו ${matches.length} חברי קבוצה מהרשימה. בדוק את הבחירה לפני השליחה.';
      });
    } catch (e) {
      if (mounted)
        setState(() => _notice = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.members
        .where((m) =>
            m['name'].toString().toLowerCase().contains(_query.toLowerCase()))
        .toList();
    return AlertDialog(
      scrollable: true,
      title: const Text('בחירת נמענים'),
      content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                decoration:
                    const InputDecoration(labelText: 'חיפוש חברי קבוצה'),
                onChanged: (v) => setState(() => _query = v)),
            Wrap(children: [
              TextButton(
                  onPressed: () => setState(() {
                        _selected.clear();
                        _selected.addAll(
                            widget.members.map((m) => m['id'].toString()));
                      }),
                  child: const Text('בחר הכול')),
              TextButton(
                  onPressed: () => setState(_selected.clear),
                  child: const Text('נקה')),
            ]),
            OutlinedButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.upload_file),
                label: const Text('העלה רשימת שמות או מזהים (CSV / TXT)')),
            if (_notice.isNotEmpty)
              Text(_notice, style: const TextStyle(fontSize: 12)),
            SizedBox(
                height: math.min(
                    220,
                    math.max(
                        100,
                        MediaQuery.sizeOf(context).height -
                            MediaQuery.viewInsetsOf(context).bottom -
                            430)),
                child: visible.isEmpty
                    ? const Center(child: Text('אין נמענים מתאימים'))
                    : ListView(children: [
                        for (final m in visible)
                          CheckboxListTile(
                              title: Text(m['name']?.toString() ?? ''),
                              value: _selected.contains(m['id']),
                              onChanged: (v) => setState(() {
                                    if (v == true) {
                                      _selected.add(m['id'].toString());
                                    } else {
                                      _selected.remove(m['id']);
                                    }
                                  }))
                      ])),
          ])),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ביטול')),
        ElevatedButton(
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.pop(context, _selected.toList()),
            child: Text('בחר (${_selected.length})'))
      ],
    );
  }
}

class EducationQuestionDialog extends StatefulWidget {
  const EducationQuestionDialog({super.key, this.initial});
  final Map<String, dynamic>? initial;
  @override
  State<EducationQuestionDialog> createState() =>
      _EducationQuestionDialogState();
}

class _EducationQuestionDialogState extends State<EducationQuestionDialog> {
  late final _question =
      TextEditingController(text: widget.initial?['text']?.toString());
  late final _options = TextEditingController(
      text: (widget.initial?['options'] as List?)?.join('\n'));
  String? _error;
  @override
  void dispose() {
    _question.dispose();
    _options.dispose();
    super.dispose();
  }

  void _save() {
    final text = _question.text.trim();
    final options = _options.text
        .split('\n')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();
    if (text.isEmpty ||
        text.length > 300 ||
        options.length < 2 ||
        options.length > 12 ||
        options.any((v) => v.length > 150) ||
        options.toSet().length != options.length) {
      setState(
          () => _error = 'יש להזין שאלה ועד 12 אפשרויות שונות, לפחות שתיים.');
      return;
    }
    Navigator.pop(context, {'text': text, 'options': options});
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: const Text('שאלת סקר'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: _question,
              decoration: const InputDecoration(labelText: 'השאלה')),
          const SizedBox(height: 10),
          TextField(
              controller: _options,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                  labelText: 'אפשרויות — כל אפשרות בשורה')),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ביטול')),
          ElevatedButton(
              onPressed: _save,
              child: Text(widget.initial == null ? 'הוסף' : 'שמור'))
        ],
      );
}
