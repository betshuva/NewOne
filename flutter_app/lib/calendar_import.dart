import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'calendar.dart';

const maxCalendarImportBytes = 512 * 1024;

/// Returns true only after every selected event has been saved. The caller can
/// retain an original Android content URI when importing fails or is cancelled.
Future<bool> openCalendarImport(BuildContext context,
        {required String api,
        required String token,
        required String rawText,
        bool Function()? canImport}) =>
    _openPreview(context, CalendarApi(api, token), {'ics': rawText}, canImport);

Future<bool> openCalendarDraft(BuildContext context,
        {required String api,
        required String token,
        required Map<String, dynamic> draft,
        bool Function()? canImport}) =>
    _openPreview(context, CalendarApi(api, token), {'event': draft}, canImport);

Future<bool> _openPreview(BuildContext context, CalendarApi api,
    Map<String, dynamic> body, bool Function()? canImport) async {
  try {
    if (!context.mounted || canImport?.call() == false) return false;
    if (body['ics'] is String &&
        utf8.encode(body['ics'] as String).length > maxCalendarImportBytes) {
      throw Exception('אפשר לייבא קובץ אירוע עד 512KB.');
    }
    final preview =
        await api.call('import/preview', method: 'POST', body: body);
    if (!context.mounted || canImport?.call() == false) return false;
    final entries = (preview['drafts'] as List)
        .map((value) => Map<String, dynamic>.from(value as Map))
        .toList();
    final selected = await showDialog<List<Map<String, dynamic>>>(
        context: context,
        builder: (_) => _CalendarImportReview(
            entries: entries,
            warnings: (preview['warnings'] as List? ?? [])
                .map((value) => value.toString())
                .toList()));
    if (selected == null ||
        selected.isEmpty ||
        !context.mounted ||
        canImport?.call() == false) {
      return false;
    }
    for (final entry in selected) {
      if (!context.mounted || canImport?.call() == false) return false;
      final single = entry['requires_single_occurrence'] == true;
      if (single) {
        final accepted = await showDialog<bool>(
            context: context,
            builder: (ctx) => Directionality(
                textDirection: TextDirection.rtl,
                child: AlertDialog(
                    insetPadding: const EdgeInsets.all(16),
                    constraints: const BoxConstraints(maxWidth: 420),
                    title: const Text('ייבוא מופע אחד בלבד'),
                    content: const Text(
                        'כללי החזרה של האירוע הזה אינם נתמכים במלואם. רק המופע שמוצג יתווסף ליומן; שאר המופעים לא יתווספו.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('ביטול')),
                      FilledButton(
                          key: const ValueKey('calendar-import-single-confirm'),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('ייבוא המופע בלבד')),
                    ])));
        if (accepted != true ||
            !context.mounted ||
            canImport?.call() == false) {
          return false;
        }
      }
      final draft = Map<String, dynamic>.from(entry['draft'] as Map)
        ..['_import_key'] = entry['import_key']
        ..['_import_single_occurrence'] = single;
      if (!await openCalendarImportEditor(context,
              api: api, initialDraft: draft, canImport: canImport) ||
          !context.mounted ||
          canImport?.call() == false) {
        return false;
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('האירועים שבחרת נשמרו ביומן בתשובה.')));
    }
    return true;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', ''))));
    }
    return false;
  }
}

/// Available on both web and Android, in addition to Android's share sheet.
Future<bool> openCalendarImportInput(BuildContext context,
    {required String api,
    required String token,
    bool Function()? canImport}) async {
  final raw = await showDialog<String>(
      context: context, builder: (_) => const _CalendarImportInput());
  if (raw == null || !context.mounted) return false;
  return openCalendarImport(context,
      api: api, token: token, rawText: raw, canImport: canImport);
}

class _CalendarImportInput extends StatefulWidget {
  const _CalendarImportInput();
  @override
  State<_CalendarImportInput> createState() => _CalendarImportInputState();
}

class _CalendarImportInputState extends State<_CalendarImportInput> {
  final _text = TextEditingController();
  bool _picking = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
          type: FileType.custom, allowedExtensions: ['ics'], withData: true);
      if (result == null || !mounted) return;
      final file = result.files.single;
      if (file.size > maxCalendarImportBytes) {
        throw Exception('אפשר לייבא קובץ אירוע עד 512KB.');
      }
      if (file.bytes == null) {
        throw Exception('לא ניתן לקרוא את קובץ האירוע. יש לבחור אותו מחדש.');
      }
      final raw = utf8.decode(file.bytes!);
      if (!mounted) return;
      setState(() => _text.text = raw);
    } catch (error) {
      if (mounted) {
        setState(
            () => _error = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
          key: const ValueKey('calendar-import-input'),
          insetPadding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 420),
          scrollable: true,
          title: const Text('ייבוא אירוע ליומן בתשובה'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
                'בחרו קובץ ICS או הדביקו את תוכנו. האירוע יוצג לבדיקה לפני השמירה ביומן האישי.'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
                key: const ValueKey('calendar-import-file'),
                onPressed: _picking ? null : _pickFile,
                icon: const Icon(Icons.upload_file),
                label: Text(_picking ? 'קורא קובץ…' : 'בחירת קובץ אירוע')),
            const SizedBox(height: 12),
            TextField(
                key: const ValueKey('calendar-import-ics-text'),
                controller: _text,
                textDirection: TextDirection.ltr,
                minLines: 3,
                maxLines: 5,
                decoration: const InputDecoration(
                    labelText: 'תוכן קובץ ICS', hintText: 'BEGIN:VCALENDAR…')),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child:
                      Text(_error!, style: const TextStyle(color: Colors.red))),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('ביטול')),
            FilledButton(
                key: const ValueKey('calendar-import-preview'),
                onPressed: _picking
                    ? null
                    : () {
                        if (_text.text.trim().isEmpty) {
                          setState(() => _error =
                              'יש לבחור קובץ אירוע או להדביק את תוכנו.');
                          return;
                        }
                        Navigator.pop(context, _text.text);
                      },
                child: const Text('בדיקת האירוע')),
          ]));
}

class _CalendarImportReview extends StatefulWidget {
  final List<Map<String, dynamic>> entries;
  final List<String> warnings;
  const _CalendarImportReview({required this.entries, required this.warnings});
  @override
  State<_CalendarImportReview> createState() => _CalendarImportReviewState();
}

class _CalendarImportReviewState extends State<_CalendarImportReview> {
  late final _selected = List<bool>.filled(widget.entries.length, true);

  @override
  Widget build(BuildContext context) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
          key: const ValueKey('calendar-import-review'),
          insetPadding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 420),
          scrollable: true,
          title: const Text('הוספה ליומן בתשובה'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
                'בחרו את האירועים להוספה. ניתן לערוך כל אירוע לפני שמירתו ביומן האישי.'),
            for (final warning in widget.warnings)
              Text(warning, style: TextStyle(color: Colors.orange.shade900)),
            for (var index = 0; index < widget.entries.length; index++) ...[
              CheckboxListTile(
                  key: ValueKey('calendar-import-event-$index'),
                  value: _selected[index],
                  contentPadding: EdgeInsets.zero,
                  title:
                      Text(widget.entries[index]['draft']['title'].toString()),
                  subtitle: Text(
                      '${widget.entries[index]['draft']['start']} · ${widget.entries[index]['draft']['timezone']}'),
                  onChanged: (value) =>
                      setState(() => _selected[index] = value == true)),
              for (final warning
                  in widget.entries[index]['warnings'] as List? ?? [])
                Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(warning.toString(),
                        style: TextStyle(color: Colors.orange.shade900))),
            ],
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('ביטול')),
            FilledButton(
                key: const ValueKey('calendar-import-continue'),
                onPressed: !_selected.contains(true)
                    ? null
                    : () => Navigator.pop(context, [
                          for (var index = 0;
                              index < widget.entries.length;
                              index++)
                            if (_selected[index]) widget.entries[index],
                        ]),
                child: const Text('בדיקה ושמירה ביומן')),
          ]));
}
