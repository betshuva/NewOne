import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Local changes supplement socket delivery, including settings opened over a chat.
final receivingFilterChanges = StreamController<String>.broadcast(sync: true);

Future<http.Response?> saveReceivingFilter({
  required BuildContext context,
  required String api,
  required String token,
  required String path,
  required Map<String, dynamic> body,
}) async {
  Future<http.Response> send(Map<String, dynamic> payload) => http.put(
        Uri.parse('$api$path'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );
  var response = await send(body);
  if (response.statusCode == 409) {
    final decoded = jsonDecode(response.body);
    if (decoded is Map && decoded['code'] == 'EXISTING_MEDIA_CHOICE_REQUIRED') {
      if (!context.mounted) return null;
      final count = decoded['affectedCount'];
      final action = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('מה לעשות עם התמונות הקיימות?'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('נמצאו $count תמונות קיימות מהסוג שבחרת לחסום. '
                      'הבחירה חלה על תמונות ששלחת וגם על תמונות שקיבלת. '
                      'קבלה, העלאה ושליחה של תמונות חדשות מהסוג הזה ייחסמו בכל אפשרות.'),
                  const SizedBox(height: 16),
                  for (final choice in const [
                    (
                      'hide',
                      'להסתיר',
                      'התמונות יוסתרו אצלך וניתן יהיה להחזיר אותן בהמשך.',
                      Icons.visibility_off_outlined
                    ),
                    (
                      'delete',
                      'למחוק',
                      'התמונות יימחקו עבורך בלבד. לא ניתן לבטל את המחיקה.',
                      Icons.delete_outline
                    ),
                    (
                      'keep',
                      'להשאיר',
                      'התמונות הקיימות ששלחת או שקיבלת ימשיכו להופיע אצלך.',
                      Icons.image_outlined
                    ),
                  ])
                    ListTile(
                      key: ValueKey('existing-media-${choice.$1}'),
                      leading: Icon(choice.$4),
                      title: Text(choice.$2),
                      subtitle: Text(choice.$3),
                      onTap: () => Navigator.pop(dialogContext, choice.$1),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('ביטול השינוי'),
              ),
            ],
          ),
        ),
      );
      if (action == null || !context.mounted) return null;
      response = await send({...body, 'existingMediaAction': action});
    }
  }
  if (response.statusCode == 200) receivingFilterChanges.add(token);
  return response;
}

bool filterWidgetIsVisible(BuildContext context) {
  if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) {
    return false;
  }
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return false;
  final bounds = box.localToGlobal(Offset.zero) & box.size;
  final viewport = Offset.zero & MediaQuery.sizeOf(context);
  if (!bounds.overlaps(viewport)) return false;
  final scrollableBox = Scrollable.maybeOf(context)?.context.findRenderObject();
  if (scrollableBox is RenderBox && scrollableBox.hasSize) {
    return bounds.overlaps(
        scrollableBox.localToGlobal(Offset.zero) & scrollableBox.size);
  }
  return true;
}

Future<void> reportFilterDisplay({
  required String api,
  required String token,
  required String messageId,
  required String event,
}) async {
  if (messageId.isEmpty || messageId.startsWith('temp_')) return;
  try {
    await http
        .post(Uri.parse('$api/filter-display-events'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'messageId': messageId,
              'event': event,
              'clientTime': DateTime.now().toUtc().toIso8601String(),
            }))
        .timeout(const Duration(seconds: 8));
  } catch (_) {
    // A display observation never delays access to a conversation.
  }
}

enum _HiddenImageKind { contentFilter, pending, rejected, purged, unavailable }

_HiddenImageKind _hiddenImageKind({
  String? hiddenReason = 'content_filter',
  String? status,
  bool contentPurged = false,
}) {
  if (contentPurged) return _HiddenImageKind.purged;
  final normalizedStatus = status?.trim().toLowerCase();
  if (normalizedStatus == 'pending' || normalizedStatus == 'pending_scan') {
    return _HiddenImageKind.pending;
  }
  if (normalizedStatus == 'rejected' || normalizedStatus == 'rejected_scan') {
    return _HiddenImageKind.rejected;
  }
  if (hiddenReason == 'content_filter' &&
      const [null, '', 'approved', 'sent', 'delivered', 'read']
          .contains(normalizedStatus)) {
    return _HiddenImageKind.contentFilter;
  }
  return _HiddenImageKind.unavailable;
}

/// An explicit null reason represents unknown metadata. The default preserves
/// legacy callers which already know the image is hidden by a content filter.
bool isContentFilterHiddenImage({
  String? hiddenReason = 'content_filter',
  String? status,
  bool contentPurged = false,
}) =>
    _hiddenImageKind(
      hiddenReason: hiddenReason,
      status: status,
      contentPurged: contentPurged,
    ) ==
    _HiddenImageKind.contentFilter;

String hiddenImageMessage({
  String? hiddenReason = 'content_filter',
  String? status,
  String? reason,
  bool contentPurged = false,
}) {
  final kind = _hiddenImageKind(
    hiddenReason: hiddenReason,
    status: status,
    contentPurged: contentPurged,
  );
  return switch (kind) {
    _HiddenImageKind.contentFilter => 'התמונה מוסתרת לפי בחירת הסינון שלך',
    _HiddenImageKind.pending => 'התמונה ממתינה לסריקה ולאישור',
    _HiddenImageKind.rejected =>
      'התמונה נחסמה בבדיקת הבטיחות${reason?.trim().isNotEmpty == true ? '\n${reason!.trim()}' : ''}',
    _HiddenImageKind.purged => 'התמונה נמחקה ואינה זמינה עוד',
    _HiddenImageKind.unavailable => 'התמונה אינה זמינה כעת',
  };
}

final _persistedMessageId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class FilterHiddenImage extends StatefulWidget {
  final String api;
  final String token;
  final String messageId;
  final Future<void> Function() onRestored;
  final String? hiddenReason;
  final String? status;
  final String? reason;
  final bool contentPurged;
  const FilterHiddenImage(
      {super.key,
      required this.api,
      required this.token,
      required this.messageId,
      required this.onRestored,
      this.hiddenReason = 'content_filter',
      this.status,
      this.reason,
      this.contentPurged = false});

  @override
  State<FilterHiddenImage> createState() => _FilterHiddenImageState();
}

class _FilterHiddenImageState extends State<FilterHiddenImage> {
  bool _restoring = false;
  bool _reported = false;
  ScrollPosition? _position;

  String? get _hiddenReason => widget.hiddenReason == 'content_filter' &&
          !_persistedMessageId.hasMatch(widget.messageId)
      ? null
      : widget.hiddenReason;

  bool get _canRestore =>
      _persistedMessageId.hasMatch(widget.messageId) &&
      isContentFilterHiddenImage(
        hiddenReason: _hiddenReason,
        status: widget.status,
        contentPurged: widget.contentPurged,
      );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _position?.removeListener(_observe);
    _position = Scrollable.maybeOf(context)?.position;
    _position?.addListener(_observe);
    WidgetsBinding.instance.addPostFrameCallback((_) => _observe());
  }

  void _observe() {
    if (_reported ||
        !mounted ||
        !_canRestore ||
        !filterWidgetIsVisible(context)) {
      return;
    }
    _reported = true;
    reportFilterDisplay(
        api: widget.api,
        token: widget.token,
        messageId: widget.messageId,
        event: 'hidden');
  }

  @override
  void didUpdateWidget(covariant FilterHiddenImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageId != widget.messageId ||
        oldWidget.token != widget.token ||
        oldWidget.api != widget.api ||
        oldWidget.hiddenReason != widget.hiddenReason ||
        oldWidget.status != widget.status ||
        oldWidget.contentPurged != widget.contentPurged) {
      _reported = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _observe());
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_observe);
    super.dispose();
  }

  Future<void> _restore() async {
    if (_restoring || !_canRestore) return;
    setState(() => _restoring = true);
    try {
      final response = await http.post(
        Uri.parse(
            '${widget.api}/messages/${widget.messageId}/filter-visibility'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({'action': 'restore'}),
      );
      if (response.statusCode != 200) throw Exception();
      receivingFilterChanges.add(widget.token);
      await widget.onRestored();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('לא ניתן להחזיר את התמונה כעת')));
      }
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(maxWidth: 280),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0xFFF0F5F9),
            borderRadius: BorderRadius.circular(10)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(switch (_hiddenImageKind(
            hiddenReason: _hiddenReason,
            status: widget.status,
            contentPurged: widget.contentPurged,
          )) {
            _HiddenImageKind.contentFilter => Icons.visibility_off_outlined,
            _HiddenImageKind.pending => Icons.hourglass_top,
            _HiddenImageKind.rejected => Icons.block,
            _ => Icons.image_not_supported_outlined,
          }),
          const SizedBox(height: 6),
          Text(
              hiddenImageMessage(
                hiddenReason: _hiddenReason,
                status: widget.status,
                reason: widget.reason,
                contentPurged: widget.contentPurged,
              ),
              textAlign: TextAlign.center),
          if (_canRestore)
            TextButton(
                onPressed: _restoring ? null : _restore,
                child: Text(_restoring ? 'מחזיר…' : 'להחזיר את התמונה הזו')),
        ]),
      );
}

/// Observes a hidden placeholder without offering an action in a library tile.
class FilterHiddenObservation extends StatefulWidget {
  final String api;
  final String token;
  final String messageId;
  final Widget child;
  const FilterHiddenObservation(
      {super.key,
      required this.api,
      required this.token,
      required this.messageId,
      required this.child});

  @override
  State<FilterHiddenObservation> createState() =>
      _FilterHiddenObservationState();
}

class _FilterHiddenObservationState extends State<FilterHiddenObservation> {
  ScrollPosition? _position;
  bool _reported = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _position?.removeListener(_observe);
    _position = Scrollable.maybeOf(context)?.position;
    _position?.addListener(_observe);
    WidgetsBinding.instance.addPostFrameCallback((_) => _observe());
  }

  @override
  void didUpdateWidget(covariant FilterHiddenObservation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageId != widget.messageId ||
        oldWidget.token != widget.token) {
      _reported = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _observe());
    }
  }

  void _observe() {
    if (_reported || !mounted || !filterWidgetIsVisible(context)) return;
    _reported = true;
    reportFilterDisplay(
        api: widget.api,
        token: widget.token,
        messageId: widget.messageId,
        event: 'hidden');
  }

  @override
  void dispose() {
    _position?.removeListener(_observe);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
