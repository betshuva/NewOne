import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class StorageQuotaView extends StatefulWidget {
  final String api, token;
  final int revision;
  final VoidCallback onCleanup, onDrive;
  final bool alertsOnly;
  final Future<Map<String, dynamic>> Function()? loadQuota;
  const StorageQuotaView({super.key, required this.api, required this.token,
    required this.onCleanup, required this.onDrive, this.revision = 0,
    this.alertsOnly = false, this.loadQuota});
  @override
  State<StorageQuotaView> createState() => _StorageQuotaViewState();
}

class _StorageQuotaViewState extends State<StorageQuotaView> {
  Map<String, dynamic>? _quota;
  Timer? _timer;
  bool _loading = false;
  String? _error;
  int _dismissed = 0, _generation = 0;
  String get _preferenceKey {
    try {
      final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(widget.token.split('.')[1])))) as Map;
      return 'storage-quota-alert-${claims['id']}';
    } catch (_) { return 'storage-quota-alert'; }
  }
  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _load());
  }
  @override
  void didUpdateWidget(covariant StorageQuotaView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token || oldWidget.revision != widget.revision) _load();
  }
  @override
  void dispose() { _generation++; _timer?.cancel(); super.dispose(); }
  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final Map<String, dynamic> data;
      if (widget.loadQuota != null) {
        data = await widget.loadQuota!();
      } else {
        final response = await http.get(Uri.parse('${widget.api}/storage-quota'),
          headers: {'Authorization': 'Bearer ${widget.token}'}).timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) throw Exception();
        data = jsonDecode(response.body) as Map<String, dynamic>;
      }
      final prefs = await SharedPreferences.getInstance();
      if (!mounted || generation != _generation) return;
      var dismissed = prefs.getInt(_preferenceKey) ?? 0;
      if ((data['warningLevel'] as num? ?? 0) == 0 && dismissed != 0) {
        await prefs.remove(_preferenceKey); dismissed = 0;
      }
      if (!mounted || generation != _generation) return;
      setState(() { _quota = data; _dismissed = dismissed; _error = null; });
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _error = 'לא ניתן לבדוק את הנפח כרגע');
    }
  }
  Future<void> _checkDrive() async {
    setState(() => _loading = true);
    try {
      final response = await http.post(Uri.parse('${widget.api}/storage-quota/check-drive'),
        headers: {'Authorization': 'Bearer ${widget.token}'}).timeout(const Duration(seconds: 90));
      if (response.statusCode != 200) {
        final data = jsonDecode(response.body) as Map;
        throw Exception(data['error'] ?? 'בדיקת Drive נכשלה');
      }
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally { if (mounted) setState(() => _loading = false); }
  }
  @override
  Widget build(BuildContext context) {
    final q = _quota;
    final level = (q?['warningLevel'] as num? ?? 0).toInt();
    if (widget.alertsOnly && (q == null || level == 0 || level <= _dismissed)) return const SizedBox.shrink();
    final used = (q?['usedBytes'] as num? ?? 0).toDouble();
    final reserved = (q?['reservedBytes'] as num? ?? 0).toDouble();
    final limit = (q?['limitBytes'] as num? ?? 2000000000).toDouble();
    final pending = (q?['pendingPersonalFiles'] as num? ?? 0).toInt();
    final failed = (q?['failedPersonalFiles'] as num? ?? 0).toInt();
    final connected = q?['driveConnected'] == true;
    final color = level >= 95 ? const Color(0xffa63832) : level > 0 ? const Color(0xff8c5707) : const Color(0xff185882);
    return Directionality(textDirection: TextDirection.rtl, child: Container(
      key: const ValueKey('storage-quota-panel'),
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8), padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: level > 0 ? const Color(0xfffff3df) : const Color(0xffedf5fc),
        borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [Expanded(child: Text(level >= 100 ? 'מכסת האחסון מלאה'
          : level > 0 ? 'מתקרבים למכסת האחסון — $level%'
          : 'האחסון שלך בבתשובה', style: TextStyle(color: color, fontWeight: FontWeight.bold))),
          if (widget.alertsOnly) IconButton(tooltip: 'הבנתי', icon: const Icon(Icons.close), onPressed: () async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setInt(_preferenceKey, level);
            if (mounted) setState(() => _dismissed = level);
          }),
        ]),
        if (q != null) ...[
          Text('${(used / 1e9).toStringAsFixed(2)} מתוך 2 GB', style: TextStyle(color: color)),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: ((used + reserved) / limit).clamp(0, 1), color: color),
          const SizedBox(height: 8),
          if (reserved > 0) Text('${(reserved / 1e6).toStringAsFixed(1)} MB שמורים להעלאות בתהליך'),
          Text(connected
            ? 'Drive אישי מחובר. כל הקבצים מועברים אליו לאחר אימות השמירה.'
            : 'כולל תמונות, סרטונים, הקלטות ומסמכים. אפשר לפנות מקום או לחבר Drive אישי.'),
          if (pending > 0) Text('$pending קבצים ממתינים להשלמת השמירה ב־Drive האישי.'),
          if (failed > 0) Text('שמירת $failed קבצים נכשלה. יש לבדוק את חיבור Drive ואת המקום הפנוי.',
            style: const TextStyle(color: Color(0xffa63832))),
        ],
        if (_error != null) Text(_error!, style: const TextStyle(color: Color(0xffa63832))),
        Wrap(spacing: 8, runSpacing: 4, children: [
          TextButton.icon(key: const ValueKey('storage-cleanup'), onPressed: widget.onCleanup,
            icon: const Icon(Icons.cleaning_services_outlined), label: const Text('פינוי מקום — קבצים ישנים')),
          TextButton.icon(onPressed: _loading ? null : connected ? _checkDrive : widget.onDrive,
            icon: const Icon(Icons.cloud_outlined), label: Text(_loading ? 'בודק…' : connected ? 'בדיקת Drive' : 'חיבור Drive אישי')),
          if (_error != null) TextButton(onPressed: _load, child: const Text('רענון')),
        ]),
      ]),
    ));
  }
}
