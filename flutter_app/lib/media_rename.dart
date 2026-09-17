import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class OwnedMediaName {
  final String id;
  final String name;
  const OwnedMediaName({required this.id, required this.name});
}

Future<OwnedMediaName?> resolveMediaName({
  required String api,
  required String token,
  required String url,
}) async {
  final apiUri = Uri.parse(api);
  final mediaUri = Uri.tryParse(url);
  // Viewers may receive an absolute version of the server's stored URL.
  final lookupUrl = mediaUri != null &&
          mediaUri.hasAuthority &&
          mediaUri.origin == apiUri.origin
      ? '${mediaUri.path}${mediaUri.hasQuery ? '?${mediaUri.query}' : ''}'
      : url;
  final response = await http.get(
    Uri.parse('$api/media-library/resolve')
        .replace(queryParameters: {'url': lookupUrl}),
    headers: {'Authorization': 'Bearer $token'},
  ).timeout(const Duration(seconds: 10));
  if (response.statusCode == 404) return null;
  if (response.statusCode != 200) throw StateError('לא ניתן לטעון את שם הקובץ');
  final data = jsonDecode(response.body);
  final item = data is Map ? data['item'] : null;
  if (item is! Map ||
      item['id'] is! String ||
      item['name'] is! String ||
      (item['id'] as String).isEmpty ||
      (item['name'] as String).isEmpty) {
    return null;
  }
  return OwnedMediaName(id: item['id'] as String, name: item['name'] as String);
}

Future<String?> renameMediaByUrl(
  BuildContext context, {
  required String api,
  required String token,
  required String url,
  OwnedMediaName? media,
}) async {
  final owned =
      media ?? await resolveMediaName(api: api, token: token, url: url);
  if (owned == null || !context.mounted) return null;
  final name = await showMediaRenameDialog(context, filename: owned.name);
  if (name == null || !context.mounted) return null;
  if (name == owned.name) return name;
  final response = await http
      .patch(
        Uri.parse('$api/media-library/${Uri.encodeComponent(owned.id)}'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({'name': name}),
      )
      .timeout(const Duration(seconds: 10));
  if (response.statusCode != 200) throw StateError('לא ניתן לשנות את שם הקובץ');
  final data = jsonDecode(response.body);
  final item = data is Map ? data['item'] : null;
  if (item is! Map ||
      item['name'] is! String ||
      (item['name'] as String).isEmpty) {
    throw StateError('לא ניתן לשנות את שם הקובץ');
  }
  return item['name'] as String;
}

final _extensionPattern = RegExp(r'\.[a-z0-9]{1,16}$', caseSensitive: false);
final _invalidNameCharacters = RegExp(r'[\x00-\x1f\x7f/\\]');

/// The original extension is displayed separately and is never editable.
String mediaFilenameExtension(String filename) =>
    _extensionPattern.firstMatch(filename)?.group(0) ?? '';

String mediaFilenameBasename(String filename) {
  final extension = mediaFilenameExtension(filename);
  return filename.substring(0, filename.length - extension.length);
}

String? mediaFilenameFromBasename(String basename, String originalFilename) {
  final trimmed = basename.trim();
  if (trimmed.isEmpty ||
      trimmed == '.' ||
      trimmed == '..' ||
      _invalidNameCharacters.hasMatch(trimmed)) {
    return null;
  }
  final name = '$trimmed${mediaFilenameExtension(originalFilename)}';
  return name.runes.length <= 255 ? name : null;
}

Future<String?> showMediaRenameDialog(BuildContext context,
        {required String filename}) =>
    showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (_) => _MediaRenameDialog(filename: filename),
    );

class _MediaRenameDialog extends StatefulWidget {
  final String filename;
  const _MediaRenameDialog({required this.filename});

  @override
  State<_MediaRenameDialog> createState() => _MediaRenameDialogState();
}

class _MediaRenameDialogState extends State<_MediaRenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: mediaFilenameBasename(widget.filename));

  String? get _name =>
      mediaFilenameFromBasename(_controller.text, widget.filename);

  void _save() {
    final name = _name;
    if (name != null) Navigator.pop(context, name);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final extension = mediaFilenameExtension(widget.filename);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('שינוי שם הקובץ'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('media-rename-input'),
                controller: _controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'שם הקובץ'),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
              ),
              if (extension.isNotEmpty) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('סיומת הקובץ: '),
                    Text(
                      extension,
                      key: const ValueKey('media-rename-extension'),
                      textDirection: TextDirection.ltr,
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.lock_outline, size: 16),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              const Text('השם ישתנה במדיה שלך. סיומת הקובץ תישמר.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ביטול'),
          ),
          FilledButton(
            key: const ValueKey('media-rename-save'),
            onPressed: _name == null ? null : _save,
            child: const Text('שמור'),
          ),
        ],
      ),
    );
  }
}
