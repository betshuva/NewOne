import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// Only identifiers travel through this local refresh channel, never numbers.
final phoneSharingChanges = StreamController<String>.broadcast();

String visibleContactPhone(Map<dynamic, dynamic> contact) {
  if (!const {'self', 'known', 'shared'}
      .contains(contact['phone_visibility'])) {
    return '';
  }
  return contact['phone']?.toString().trim() ?? '';
}

String contactSourceLabel(Map<dynamic, dynamic> contact) =>
    const {'phone_import', 'phone_manual'}.contains(contact['contact_source'])
        ? 'מהטלפון שלי'
        : 'חבר בתשובה';

Map<String, dynamic> sanitizedPhoneContact(Map<String, dynamic> contact) => {
      ...contact,
      'phone': visibleContactPhone(contact).isEmpty
          ? null
          : visibleContactPhone(contact),
    };

Future<Map<String, dynamic>> loadPhoneSharing(
    String api, String token, String contactId) async {
  final response = await http.get(
    Uri.parse('$api/contacts/$contactId/phone-sharing'),
    headers: {'Authorization': 'Bearer $token', 'Cache-Control': 'no-store'},
  ).timeout(const Duration(seconds: 12));
  final data = jsonDecode(response.body);
  if (response.statusCode != 200 || data is! Map) {
    throw Exception(data is Map ? data['error'] : 'טעינת שיתוף הטלפון נכשלה');
  }
  return Map<String, dynamic>.from(
      data['phoneSharing'] is Map ? data['phoneSharing'] as Map : data);
}

Future<Map<String, dynamic>> updatePhoneSharing(String api, String token,
    String contactId, Map<String, dynamic> choice) async {
  final response = await http
      .put(
        Uri.parse('$api/contacts/$contactId/phone-sharing'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Cache-Control': 'no-store',
        },
        body: jsonEncode(choice),
      )
      .timeout(const Duration(seconds: 12));
  final data = jsonDecode(response.body);
  if (response.statusCode != 200) {
    throw Exception(data is Map ? data['error'] : 'עדכון שיתוף הטלפון נכשל');
  }
  phoneSharingChanges.add(contactId);
  if (data is Map && data['phoneSharing'] is Map) {
    return Map<String, dynamic>.from(data['phoneSharing'] as Map);
  }
  if (data is Map && data.containsKey('phone_visibility')) {
    return Map<String, dynamic>.from(data);
  }
  return loadPhoneSharing(api, token, contactId);
}

class PhoneSharingController extends ChangeNotifier {
  Map<String, dynamic>? data;
  bool selectedShare = false;

  bool get loaded => data != null;
  bool get canShare => data?['can_share_my_phone'] == true;

  void apply(Map<String, dynamic> value, {bool initialChoice = false}) {
    final firstLoad = !loaded;
    data = sanitizedPhoneContact(value);
    selectedShare = canShare &&
        (value['share_my_phone'] == true || (firstLoad && initialChoice));
    notifyListeners();
  }

  void select(bool value) {
    selectedShare = canShare && value;
    notifyListeners();
  }

  Map<String, dynamic> get confirmationPayload => {
        if (loaded && canShare) 'share_my_phone': selectedShare,
        if (loaded &&
            canShare &&
            !selectedShare &&
            data?['incoming_request'] == true)
          'phone_response': 'decline',
      };

  String confirmationLabel({String saveLabel = 'שמור סינון'}) => !canShare
      ? saveLabel
      : selectedShare
          ? 'אשר סינון ושתף טלפון'
          : 'אשר סינון ללא שיתוף טלפון';
}

class PhoneSharingPanel extends StatefulWidget {
  final String api;
  final String token;
  final String contactId;
  final String contactName;
  final PhoneSharingController controller;
  final bool initialChoice;
  final bool compact;
  final VoidCallback? onChanged;

  const PhoneSharingPanel({
    super.key,
    required this.api,
    required this.token,
    required this.contactId,
    required this.contactName,
    required this.controller,
    this.initialChoice = false,
    this.compact = false,
    this.onChanged,
  });

  @override
  State<PhoneSharingPanel> createState() => _PhoneSharingPanelState();
}

class _PhoneSharingPanelState extends State<PhoneSharingPanel> {
  bool _busy = false;
  String? _error;
  late final StreamSubscription<String> _changes;

  @override
  void initState() {
    super.initState();
    _load();
    _changes = phoneSharingChanges.stream.listen((id) {
      if (id == widget.contactId && !_busy) _load();
    });
  }

  @override
  void dispose() {
    _changes.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.controller.data != null) {
      // A refresh may follow revocation. Clear the previously visible value
      // before the request, so a network failure cannot leave it on screen.
      setState(() => widget.controller.data = {
            ...widget.controller.data!,
            'phone': null,
            'phone_visibility': 'hidden',
          });
    }
    try {
      final data =
          await loadPhoneSharing(widget.api, widget.token, widget.contactId);
      if (!mounted) return;
      setState(() {
        _error = null;
        widget.controller.apply(data, initialChoice: widget.initialChoice);
      });
      widget.onChanged?.call();
    } catch (_) {
      if (mounted) setState(() => _error = 'לא ניתן לטעון כעת את שיתוף הטלפון');
    }
  }

  Future<void> _update(Map<String, dynamic> choice) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await updatePhoneSharing(
          widget.api, widget.token, widget.contactId, choice);
      if (!mounted) return;
      widget.controller.apply(data);
      widget.onChanged?.call();
    } catch (error) {
      if (mounted) {
        setState(
            () => _error = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final data = controller.data;
    if (data == null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: _error == null
            ? const LinearProgressIndicator()
            : TextButton(onPressed: _load, child: Text('$_error — נסה שוב')),
      );
    }
    final phone = visibleContactPhone(data);
    final pending = data['request_state'] == 'pending';
    final name = widget.contactName.trim().isEmpty
        ? 'איש הקשר'
        : widget.contactName.trim();
    final panel = Card(
      margin: widget.compact ? const EdgeInsets.symmetric(vertical: 4) : null,
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: 12, vertical: widget.compact ? 4 : 12),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!widget.compact) ...[
            Text(contactSourceLabel(data),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
                phone.isNotEmpty
                    ? phone
                    : data['phone_visibility'] == 'unavailable'
                        ? 'מספר טלפון אינו זמין'
                        : 'הטלפון לא שותף',
                textDirection:
                    phone.isNotEmpty ? TextDirection.ltr : TextDirection.rtl),
          ],
          if (controller.canShare)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              visualDensity:
                  widget.compact ? const VisualDensity(vertical: -2) : null,
              value: controller.selectedShare,
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(() => controller.select(value == true));
                      widget.onChanged?.call();
                    },
              title: Text('אני מסכים לשתף את מספר הטלפון שלי עם $name'),
              subtitle: Text(data['incoming_request'] == true
                  ? 'האישור ישתף את הטלפון. ביטול הסימון ידחה את הבקשה בלחיצה על האישור'
                  : 'השיתוף יבוצע רק לאחר לחיצה על כפתור האישור'),
            ),
          if (data['share_unavailable_reason'] == 'missing_phone')
            const Text(
                'להוספת מספר טלפון יש לעדכן את הפרופיל. ניתן לאשר את הסינון ללא שיתוף טלפון.'),
          if (phone.isEmpty &&
              (data['can_request_phone'] == true || pending) &&
              (!widget.initialChoice || pending))
            OutlinedButton.icon(
              onPressed: _busy || pending
                  ? null
                  : () => _update({'request_phone': true}),
              icon: const Icon(Icons.phone_outlined),
              label: Text(pending
                  ? 'הבקשה למספר טלפון ממתינה לאישור'
                  : 'בקש מספר טלפון'),
            ),
          if (data['incoming_request'] == true) ...[
            Text('בקשה לקבלת מספר הטלפון שלך מאת $name'),
            Wrap(spacing: 8, children: [
              FilledButton(
                  onPressed: _busy || !controller.canShare
                      ? null
                      : () => _update({'phone_response': 'approve'}),
                  child: const Text('אשר ושתף את הטלפון שלי')),
              TextButton(
                  onPressed: _busy
                      ? null
                      : () => _update({'phone_response': 'decline'}),
                  child: const Text('דחה בקשת טלפון')),
            ]),
          ],
          if (data['share_my_phone'] == true)
            TextButton(
                onPressed:
                    _busy ? null : () => _update({'share_my_phone': false}),
                child: const Text('בטל שיתוף של הטלפון שלי')),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red)),
          if (_busy) const LinearProgressIndicator(),
        ]),
      ),
    );
    return widget.compact
        ? Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: panel,
            ),
          )
        : panel;
  }
}
