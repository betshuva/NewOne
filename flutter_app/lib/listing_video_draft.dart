import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'listing_background_images.dart';
import 'listing_capture.dart';

/// Owns the one video slot and its upload even after the editor is disposed.
class ListingVideoDraft extends ChangeNotifier {
  String? _url, _error;
  XFile? _file;
  Completer<ListingImageAttachment?>? _task;
  bool _uploading = false, _changed = false, _disposed = false;

  String? get url => _url;
  String? get error => _error;
  String? get fileName => _file?.name;
  bool get uploading => _uploading;
  bool get changed => _changed;
  Future<ListingImageAttachment?>? get pendingUpload =>
      _uploading ? _task?.future : null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void load(String? url) {
    _url = url;
    _changed = false;
  }

  Future<void> upload(XFile file, Future<String> Function(XFile) send) async {
    if (_uploading) return;
    final previous = _url;
    final task = Completer<ListingImageAttachment?>();
    _task = task;
    _file = file;
    _error = null;
    _uploading = true;
    _notify();
    try {
      final url = await send(file);
      if (url.trim().isEmpty) throw StateError('לא התקבלה כתובת לסרטון');
      _url = url;
      _changed = true;
      task.complete(ListingImageAttachment(
          url: url, expectedOldUrl: previous, video: true));
    } catch (error) {
      _error = error.toString().replaceFirst('Exception: ', '');
      task.complete(null);
    } finally {
      _uploading = false;
      _notify();
    }
  }

  Future<void> retry(Future<String> Function(XFile) send) async {
    final file = _file;
    if (file != null && _error != null) await upload(file, send);
  }

  void remove() {
    if (_uploading) return;
    _url = null;
    _file = null;
    _error = null;
    _task = null;
    _changed = true;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class ListingVideoPicker extends StatefulWidget {
  final ListingVideoDraft draft;
  final Future<String> Function(XFile) upload;
  final Future<bool> Function(XFile) validate;
  final Widget Function(String) preview;
  final String creatorId;
  final bool enabled;
  final ValueChanged<bool>? onPreparingChanged;

  const ListingVideoPicker({
    super.key,
    required this.draft,
    required this.upload,
    required this.validate,
    required this.preview,
    this.creatorId = 'listing',
    this.enabled = true,
    this.onPreparingChanged,
  });

  @override
  State<ListingVideoPicker> createState() => _ListingVideoPickerState();
}

class _ListingVideoPickerState extends State<ListingVideoPicker> {
  bool _picking = false;

  Future<void> _pick(bool camera) async {
    if (_picking || !widget.enabled || widget.draft.uploading) return;
    setState(() => _picking = true);
    widget.onPreparingChanged?.call(true);
    try {
      final file = camera
          ? await captureListingVideo(context, creatorId: widget.creatorId)
          : await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (!mounted || file == null || !widget.enabled) return;
      if (!await widget.validate(file) || !mounted || !widget.enabled) return;
      // Start before returning to the form; save can now retain this future.
      unawaited(widget.draft.upload(file, widget.upload));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('לא ניתן לפתוח את הסרטון. נסה שוב')));
      }
    } finally {
      if (mounted) {
        setState(() => _picking = false);
        widget.onPreparingChanged?.call(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.draft,
        builder: (context, _) {
          final draft = widget.draft;
          final enabled = widget.enabled && !_picking && !draft.uploading;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('סרטון אחד למודעה, עד 10 שניות',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                    onPressed: enabled ? () => _pick(true) : null,
                    icon: const Icon(Icons.videocam_outlined),
                    label: const Text('צילום סרטון')),
                OutlinedButton.icon(
                    onPressed: enabled ? () => _pick(false) : null,
                    icon: const Icon(Icons.video_library_outlined),
                    label: Text(
                        draft.url == null ? 'בחירת סרטון' : 'החלפת סרטון')),
                if (draft.url != null || draft.error != null)
                  TextButton.icon(
                      onPressed: enabled ? draft.remove : null,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('הסרת סרטון')),
              ]),
              if (_picking || draft.uploading) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
                const SizedBox(height: 6),
                Text(_picking
                    ? 'פותח סרטון'
                    : 'הסרטון עולה ונבדק. אפשר לשמור את המודעה ולהמשיך'),
              ],
              if (draft.error != null) ...[
                Text(draft.error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed:
                        enabled ? () => draft.retry(widget.upload) : null,
                    child: const Text('ניסיון נוסף להעלאת הסרטון'),
                  ),
                ),
              ],
              if (draft.url != null) ...[
                const SizedBox(height: 8),
                Align(
                    alignment: Alignment.centerRight,
                    child: widget.preview(draft.url!)),
              ],
              const SizedBox(height: 4),
              const Text('התמונות והסרטון יוצגו לאחר אישור הסריקה',
                  style: TextStyle(fontSize: 12)),
            ],
          );
        },
      );
}
