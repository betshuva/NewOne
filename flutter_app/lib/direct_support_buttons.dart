import 'dart:async';
import 'dart:convert';
import 'clipboard_image_paste.dart';
import 'image_paste_menu.dart';
import 'web_chat_attachments.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http_parser/http_parser.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class DirectSupportButtons extends StatelessWidget {
  final String api, token, appVersion;
  final http.Client? client;
  final Future<List<XFile>> Function()? pickImages;
  final VoidCallback? onMyIssues;
  const DirectSupportButtons(
      {super.key,
      required this.api,
      required this.token,
      required this.appVersion,
      this.onMyIssues,
      this.client,
      this.pickImages});

  Future<void> _open(BuildContext context, String type) async {
    final sent = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SupportForm(
            api: api,
            token: token,
            appVersion: appVersion,
            type: type,
            client: client,
            pickImages: pickImages));
    if (sent == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('הפנייה נשלחה. אפשר לעקוב אחריה ב״הפניות שלי״')));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(
            textDirection: TextDirection.rtl,
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                  onPressed: () => _open(context, 'feature'),
                  icon: const Icon(Icons.lightbulb_outline, size: 18),
                  label: const Text('בקשה לשיפור')),
              OutlinedButton.icon(
                  onPressed: () => _open(context, 'bug'),
                  icon: const Icon(Icons.bug_report_outlined, size: 18),
                  label: const Text('דיווח על תקלה')),
              if (onMyIssues != null)
                OutlinedButton.icon(
                    onPressed: onMyIssues,
                    icon: const Icon(Icons.pending_actions_outlined, size: 18),
                    label: const Text('הפניות שלי')),
            ]),
      );
}

class _SupportForm extends StatefulWidget {
  final String api, token, appVersion, type;
  final http.Client? client;
  final Future<List<XFile>> Function()? pickImages;
  const _SupportForm(
      {required this.api,
      required this.token,
      required this.appVersion,
      required this.type,
      this.client,
      this.pickImages});
  @override
  State<_SupportForm> createState() => _SupportFormState();
}

class _SupportImage {
  _SupportImage(this.file, this.bytes);
  final XFile file;
  final Uint8List bytes;
  String? uploadedUrl;
}

class _SupportImageUploadFailure implements Exception {
  final String message;
  const _SupportImageUploadFailure(this.message);

  @override
  String toString() => message;
}

String _supportImageMime(_SupportImage image) {
  final bytes = image.bytes;
  bool matches(List<int> signature, {int offset = 0}) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  if (matches(const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return 'image/png';
  }
  if (matches(const [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (matches(const [0x52, 0x49, 0x46, 0x46]) &&
      matches(const [0x57, 0x45, 0x42, 0x50], offset: 8)) {
    return 'image/webp';
  }
  if (matches(const [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
      matches(const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) {
    return 'image/gif';
  }
  final extension = image.file.name.split('.').last.toLowerCase();
  final fromExtension = switch (extension) {
    'png' => 'image/png',
    'jpg' || 'jpeg' || 'jpe' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'heic' => 'image/heic',
    'heif' => 'image/heif',
    'avif' => 'image/avif',
    'bmp' => 'image/bmp',
    'tif' || 'tiff' => 'image/tiff',
    _ => null,
  };
  if (fromExtension != null) return fromExtension;
  try {
    final declared = MediaType.parse((image.file.mimeType ?? '').trim());
    if (declared.type == 'image' && declared.subtype != '*') {
      return declared.mimeType;
    }
  } catch (_) {/* Some clipboard sources expose an empty or invalid MIME. */}
  return 'image/jpeg';
}

class _SupportFormState extends State<_SupportForm> {
  final _text = TextEditingController();
  final _pasteFocus = FocusNode();
  late final ClipboardImagePasteListener _pasteListener;

  @override
  void initState() {
    super.initState();
    _pasteListener = ClipboardImagePasteListener(
      focusNode: _pasteFocus,
      onFiles: (files) => _addImages(
          () async => files.map((f) => f.xFile).toList(),
          imagesOnly: true),
      onImage: (bytes, name, mime) => _addImages(() async => [
            XFile.fromData(bytes,
                name: name, path: kIsWeb ? null : name, mimeType: mime)
          ]),
      onTooManyFiles: (_) {
        if (mounted && !_sending && !_picking) {
          setState(() => _error = 'ניתן לצרף עד 8 תמונות');
        }
      },
    );
  }

  final _form = GlobalKey<FormState>();
  bool _sending = false, _picking = false;
  final _images = <_SupportImage>[];
  int _uploaded = 0;

  Future<void> _pickImages() => _addImages(() =>
      widget.pickImages?.call() ??
      ImagePicker().pickMultiImage(imageQuality: 80));

  Future<void> _addImages(Future<List<XFile>> Function() readFiles,
      {bool imagesOnly = false}) async {
    if (_picking || _sending) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final files = await readFiles();
      final selected = <_SupportImage>[];
      String? warning;
      for (final file in files) {
        if (!mounted) return;
        if (imagesOnly &&
            !(file.mimeType?.startsWith('image/') ?? false) &&
            !RegExp(r'\.(png|jpe?g|webp|gif|heic|heif)$', caseSensitive: false)
                .hasMatch(file.name)) {
          warning = 'אפשר להדביק תמונות בלבד';
          continue;
        }
        if (_images.length + selected.length >= 8) {
          warning = 'ניתן לצרף עד 8 תמונות';
          break;
        }
        if (await file.length() > 10 * 1024 * 1024) {
          warning = 'אפשר לצרף תמונות בגודל עד 10 MB לתמונה';
          continue;
        }
        selected.add(_SupportImage(file, await file.readAsBytes()));
      }
      if (files.length > 8 - _images.length) warning = 'ניתן לצרף עד 8 תמונות';
      if (mounted) {
        setState(() {
          _images.addAll(selected);
          _error = warning;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'לא ניתן לקרוא את התמונות שנבחרו');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<String> _uploadImage(_SupportImage image) async {
    if (image.uploadedUrl != null) return image.uploadedUrl!;
    final api = widget.api, token = widget.token;
    final client = widget.client;
    final mime = _supportImageMime(image);
    try {
      late int status;
      late String body;
      if (kIsWeb && client == null) {
        // Clipboard object URLs are released after the preview is prepared.
        // The draft's retained bytes own this resumable upload independently.
        final result = await uploadPickedWebAttachment(
          file: XFile.fromData(image.bytes,
              name: image.file.name, mimeType: mime),
          url: '$api/upload',
          token: token,
          fields: const {},
        ).timeout(const Duration(seconds: 210));
        if (result == null) {
          throw const _SupportImageUploadFailure(
              'לא ניתן להעלות את התמונה כרגע. נסה שוב');
        }
        status = result.statusCode;
        body = result.body;
      } else {
        final request = http.MultipartRequest('POST', Uri.parse('$api/upload'))
          ..headers['Authorization'] = 'Bearer $token'
          ..files.add(http.MultipartFile.fromBytes('file', image.bytes,
              filename: image.file.name, contentType: MediaType.parse(mime)));
        final response = await (client?.send(request) ?? request.send())
            .timeout(const Duration(seconds: 210));
        status = response.statusCode;
        body = await response.stream
            .bytesToString()
            .timeout(const Duration(seconds: 30));
      }
      Object? data;
      try {
        data = jsonDecode(body);
      } catch (_) {/* An HTTP error may contain an HTML proxy response. */}
      if (status != 200) {
        String? reason;
        if (data is Map) {
          for (final value in [data['reason'], data['error']]) {
            if (value is String && value.trim().isNotEmpty) {
              reason = value.trim();
              break;
            }
          }
        }
        final fallback = switch (status) {
          401 => 'ההתחברות פגה. התחבר מחדש ונסה שוב',
          403 => 'אין הרשאה להעלות את התמונה. נסה להתחבר מחדש',
          413 => 'התמונה גדולה מדי. בחר תמונה קטנה יותר',
          429 => 'יש יותר מדי העלאות כרגע. המתן לפני ניסיון נוסף',
          >= 500 => 'השרת אינו זמין כעת. נסה שוב בעוד כמה דקות',
          _ => 'השרת לא קיבל את התמונה. נסה שוב',
        };
        throw _SupportImageUploadFailure(reason ?? fallback);
      }
      final url = data is Map ? data['url'] : null;
      if (url is! String || url.trim().isEmpty) {
        throw const _SupportImageUploadFailure(
            'לא התקבלה כתובת לתמונה מהשרת. נסה שוב');
      }
      // Support requests can include moderation appeals, so an owned returned
      // URL is retained even when its moderation status is rejected or pending.
      return image.uploadedUrl = url;
    } on _SupportImageUploadFailure {
      rethrow;
    } on TimeoutException {
      throw const _SupportImageUploadFailure(
          'העלאת התמונה לא הסתיימה בזמן. בדוק את החיבור ונסה שוב');
    } catch (_) {
      throw const _SupportImageUploadFailure(
          'החיבור לשרת נקטע או אינו זמין. בדוק את החיבור ונסה שוב');
    }
  }

  String? _error;
  @override
  void dispose() {
    _pasteListener.dispose();
    _pasteFocus.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || _picking || !_form.currentState!.validate()) return;
    setState(() {
      _sending = true;
      _uploaded = 0;
      _error = null;
    });
    try {
      final urls = <String>[];
      for (final image in _images) {
        try {
          urls.add(await _uploadImage(image));
        } catch (error) {
          if (mounted) {
            final reason = error is _SupportImageUploadFailure
                ? error.message
                : 'לא ניתן להעלות את התמונה כרגע. נסה שוב';
            setState(() => _error =
                'העלאת תמונה ${urls.length + 1} נכשלה. התמונות והתיאור נשמרו כאן לניסיון נוסף.\n$reason');
          }
          return;
        }
        if (!mounted) return;
        setState(() => _uploaded = urls.length);
      }
      final post = widget.client?.post ?? http.post;
      final response = await post(Uri.parse('${widget.api}/support-issues'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({
            'issueType': widget.type,
            'description': _text.text.trim(),
            'attachmentUrls': urls,
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
      canPop: !_sending && !_picking,
      child: Focus(
          focusNode: _pasteFocus,
          child: AlertDialog(
            title: Text(
                widget.type == 'feature' ? 'בקשה לשיפור' : 'דיווח על תקלה'),
            content: SingleChildScrollView(
                child: SizedBox(
                    width: 420,
                    child: Form(
                        key: _form,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          TextFormField(
                              controller: _text,
                              contextMenuBuilder: (context, state) =>
                                  buildImagePasteMenu(context, state,
                                      _pasteListener.pasteImage),
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
                              validator: (value) =>
                                  (value?.trim().length ?? 0) < 5
                                      ? 'יש להזין לפחות 5 תווים'
                                      : null),
                          const SizedBox(height: 12),
                          Align(
                              alignment: Alignment.centerRight,
                              child: Text('הוספת תמונות (${_images.length}/8)',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold))),
                          if (kIsWeb)
                            const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                    'אפשר להדביק תמונה או כמה תמונות עם Ctrl+V (ב־Mac: ⌘V)',
                                    textDirection: TextDirection.rtl)),
                          if (!kIsWeb &&
                              defaultTargetPlatform == TargetPlatform.android)
                            TextButton.icon(
                                onPressed: _sending || _picking
                                    ? null
                                    : () => pasteChatImage(
                                        context, _pasteListener.pasteImage),
                                icon: const Icon(Icons.content_paste),
                                label: const Text('הדבקת תמונה')),
                          const SizedBox(height: 8),
                          Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              textDirection: TextDirection.rtl,
                              children: [
                                for (final image in _images)
                                  SizedBox(
                                      width: 88,
                                      height: 88,
                                      child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                child: Image.memory(image.bytes,
                                                    fit: BoxFit.cover,
                                                    cacheWidth: 200,
                                                    errorBuilder: (_, __,
                                                            ___) =>
                                                        const Center(
                                                            child: Icon(Icons
                                                                .image_not_supported_outlined)))),
                                            Positioned(
                                                top: 0,
                                                left: 0,
                                                child: IconButton.filled(
                                                    tooltip:
                                                        'הסרת תמונה ${_images.indexOf(image) + 1}',
                                                    onPressed: _sending ||
                                                            _picking
                                                        ? null
                                                        : () => setState(() =>
                                                            _images
                                                                .remove(image)),
                                                    icon: const Icon(
                                                        Icons.close,
                                                        size: 18))),
                                          ])),
                                if (_images.length < 8)
                                  SizedBox(
                                      width: 88,
                                      height: 88,
                                      child: OutlinedButton(
                                          onPressed: _sending || _picking
                                              ? null
                                              : _pickImages,
                                          style: OutlinedButton.styleFrom(
                                              padding: const EdgeInsets.all(4)),
                                          child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                const Icon(Icons
                                                    .add_photo_alternate_outlined),
                                                Text(
                                                    _picking
                                                        ? 'טוען…'
                                                        : 'הוספת תמונות',
                                                    textAlign:
                                                        TextAlign.center),
                                              ]))),
                              ]),
                          if (_sending && _images.isNotEmpty)
                            Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                    'צירוף תמונות: $_uploaded מתוך ${_images.length}')),
                          if (_error != null)
                            Text(_error!,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error)),
                        ])))),
            actions: [
              TextButton(
                  onPressed: _sending || _picking
                      ? null
                      : () => Navigator.pop(context),
                  child: const Text('ביטול')),
              FilledButton(
                  onPressed: _sending || _picking ? null : _send,
                  child: Text(_sending ? 'שולח…' : 'שליחת הפנייה')),
            ],
          )));
}
