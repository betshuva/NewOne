import 'package:flutter/material.dart';
import 'media_rename.dart';

/// A persistent, owner-editable label independent of the media preview.
class ChatFileName extends StatefulWidget {
  final String api, token, url;
  final String? filename;
  final bool editable;
  final ValueChanged<String>? onRenamed;

  const ChatFileName(
      {super.key,
      required this.api,
      required this.token,
      required this.url,
      this.filename,
      required this.editable,
      this.onRenamed});

  @override
  State<ChatFileName> createState() => _ChatFileNameState();
}

class _ChatFileNameState extends State<ChatFileName> {
  OwnedMediaName? _owned;
  bool _saving = false;
  int _generation = 0;

  String get _name {
    final name = _owned?.name ?? widget.filename;
    if (name != null && name.trim().isNotEmpty) return name;
    final segments = Uri.tryParse(widget.url)?.pathSegments;
    return segments != null && segments.isNotEmpty ? segments.last : 'קובץ';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ChatFileName oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.url != widget.url ||
        oldWidget.token != widget.token ||
        oldWidget.editable != widget.editable) {
      _owned = null;
      _saving = false;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (!widget.editable) return;
    try {
      final owned = await resolveMediaName(
          api: widget.api, token: widget.token, url: widget.url);
      if (mounted && generation == _generation) setState(() => _owned = owned);
    } catch (_) {
      // Keep the original filename visible when the lookup is unavailable.
    }
  }

  Future<void> _rename() async {
    if (_saving) return;
    final generation = _generation;
    setState(() => _saving = true);
    try {
      final owned = _owned ??
          await resolveMediaName(
              api: widget.api, token: widget.token, url: widget.url);
      if (!mounted || generation != _generation) return;
      if (owned == null) {
        throw StateError('הקובץ אינו זמין לשינוי שם במדיה שלך');
      }
      final name = await renameMediaByUrl(context,
          api: widget.api, token: widget.token, url: widget.url, media: owned);
      if (!mounted || generation != _generation || name == null) return;
      setState(() => _owned = OwnedMediaName(id: owned.id, name: name));
      widget.onRenamed?.call(name);
    } catch (_) {
      if (mounted && generation == _generation) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('לא ניתן לשנות את שם הקובץ. אפשר לנסות שוב.')));
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 285,
        child: Tooltip(
          message: widget.editable ? '$_name — לחצו לשינוי שם' : _name,
          child: InkWell(
            onTap: widget.editable && !_saving ? _rename : null,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
              child: Row(textDirection: TextDirection.rtl, children: [
                Expanded(
                    child: Text(_name,
                        textAlign: TextAlign.right,
                        softWrap: true,
                        style: const TextStyle(fontSize: 12))),
                if (widget.editable) ...[
                  const SizedBox(width: 6),
                  if (_saving)
                    const Icon(Icons.hourglass_empty, size: 15)
                  else
                    const Icon(Icons.edit_outlined, size: 15),
                ],
              ]),
            ),
          ),
        ),
      );
}
