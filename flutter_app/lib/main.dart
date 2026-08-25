import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_auth/smart_auth.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:video_player/video_player.dart';
import 'file_download.dart';
import 'hebrew_date.dart';
import 'media_cache.dart';
import 'native_video_player.dart';
import 'voice_call.dart';
import 'web_push.dart';
import 'web_capture_picker.dart';
import 'clipboard_image_paste.dart';
import 'web_otp.dart';

const _appInviteUrl = 'https://betshuva.com/betshuva-app/invite-v2.html';
const _sharedContactPrefix = 'betshuva://contact/';

String _sharedContactText(Map<String, String> contact) =>
    '$_sharedContactPrefix${base64Url.encode(utf8.encode(jsonEncode(contact)))}';

Map<String, dynamic>? _sharedContactFromText(String text) {
  if (!text.startsWith(_sharedContactPrefix)) return null;
  try {
    final encoded = text.substring(_sharedContactPrefix.length).trim();
    final value =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))));
    return value is Map<String, dynamic> ? value : null;
  } catch (_) {
    return null;
  }
}

Future<Map<String, String>?> _manualSharedContact(BuildContext context) async {
  final name = TextEditingController();
  final phone = TextEditingController();
  final email = TextEditingController();
  return showDialog<Map<String, String>>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('שיתוף איש קשר'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'שם')),
        TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'טלפון')),
        TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'אימייל')),
      ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('ביטול')),
        ElevatedButton(
          onPressed: () {
            if (name.text.trim().isEmpty ||
                (phone.text.trim().isEmpty && email.text.trim().isEmpty))
              return;
            Navigator.pop(dialogContext, {
              'name': name.text.trim(),
              'phone': phone.text.trim(),
              'email': email.text.trim(),
            });
          },
          child: const Text('שתף'),
        ),
      ],
    ),
  );
}

Future<Map<String, String>?> _pickPhoneContact(BuildContext context) async {
  if (kIsWeb) return _manualSharedContact(context);
  final granted = await FlutterContacts.requestPermission(readonly: true);
  if (!granted) return null;
  final contacts = await FlutterContacts.getContacts(withProperties: true);
  if (!context.mounted) return null;
  final selected = await showModalBottomSheet<Contact>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: ListView.builder(
        itemCount: contacts.length,
        itemBuilder: (_, index) => ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person_outline)),
          title: Text(contacts[index].displayName),
          subtitle: Text(contacts[index].phones.isNotEmpty
              ? contacts[index].phones.first.number
              : contacts[index].emails.isNotEmpty
                  ? contacts[index].emails.first.address
                  : ''),
          onTap: () => Navigator.pop(sheetContext, contacts[index]),
        ),
      ),
    ),
  );
  if (selected == null) return null;
  return {
    'name': selected.displayName,
    'phone': selected.phones.isNotEmpty ? selected.phones.first.number : '',
    'email': selected.emails.isNotEmpty ? selected.emails.first.address : '',
  };
}

Future<Map<String, String>?> _pickGroupSharedContact(
    BuildContext context, List<Map<String, dynamic>> members) async {
  final source = await showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(
          leading: const Icon(Icons.contact_phone_outlined),
          title: const Text('איש קשר מהטלפון'),
          onTap: () => Navigator.pop(sheetContext, 'phone')),
      ListTile(
          leading: const Icon(Icons.groups_outlined),
          title: const Text('חבר מהקבוצה'),
          onTap: () => Navigator.pop(sheetContext, 'group')),
    ])),
  );
  if (source == null || !context.mounted) return null;
  if (source == 'phone') return _pickPhoneContact(context);
  final member = await showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    builder: (sheetContext) => SafeArea(
        child: ListView.builder(
      itemCount: members.length,
      itemBuilder: (_, index) => ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person_outline)),
        title: Text(members[index]['name']?.toString() ?? 'חבר בקבוצה'),
        subtitle: Text(members[index]['phone']?.toString() ??
            members[index]['email']?.toString() ??
            ''),
        onTap: () => Navigator.pop(sheetContext, members[index]),
      ),
    )),
  );
  if (member == null) return null;
  return {
    'name': member['name']?.toString() ?? 'חבר בקבוצה',
    'phone': member['phone']?.toString() ?? '',
    'email': member['email']?.toString() ?? '',
  };
}

String _normalizeIsraeliMobile(String value) {
  var digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (digits.startsWith('972')) digits = '0${digits.substring(3)}';
  return digits;
}

bool _isValidIsraeliMobile(String value) =>
    RegExp(r'^05\d{8}$').hasMatch(_normalizeIsraeliMobile(value));

String _whatsAppPhoneNumber(String rawPhone) {
  var digits = rawPhone.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('00')) digits = digits.substring(2);
  if (digits.startsWith('0')) digits = '972${digits.substring(1)}';
  return digits;
}

Uri _whatsAppUri(String rawPhone, String message) {
  final phone = _whatsAppPhoneNumber(rawPhone);
  return Uri.parse(
    'https://wa.me/$phone?text=${Uri.encodeComponent(message)}',
  );
}

Future<bool> _openWhatsApp(String phone, String message) {
  return launchUrl(
    _whatsAppUri(phone, message),
    mode: LaunchMode.externalApplication,
  );
}

Uri _deviceSmsUri(String phone, String message) => Uri(
      scheme: 'sms',
      path: phone,
      queryParameters: {'body': message},
    );

Future<String?> _chooseInviteDelivery(BuildContext context,
    {required bool hasPhone, required bool hasEmail}) {
  return showModalBottomSheet<String>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('איך לשלוח את ההזמנה?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ),
          if (hasEmail)
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: const Text('אימייל'),
              onTap: () => Navigator.pop(sheetContext, 'email'),
            ),
          if (hasPhone)
            ListTile(
              leading: const Icon(Icons.chat_outlined),
              title: const Text('WhatsApp'),
              onTap: () => Navigator.pop(sheetContext, 'whatsapp'),
            ),
          if (hasPhone)
            ListTile(
              leading: const Icon(Icons.phone_android_outlined),
              title: const Text('הודעה מהמכשיר שלי'),
              subtitle: const Text('פתיחת אפליקציית ההודעות במכשיר'),
              onTap: () => Navigator.pop(sheetContext, 'device_sms'),
            ),
          if (hasPhone)
            ListTile(
              leading: const Icon(Icons.sms_outlined),
              title: const Text('SMS ממערכת בתשובה'),
              subtitle: const Text('המערכת תשלח את ההודעה ישירות'),
              onTap: () => Navigator.pop(sheetContext, 'system_sms'),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

Future<void> _setMessageImageAsProfile(
  BuildContext context,
  String token,
  Map<String, dynamic> message,
  Map<String, dynamic>? me,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('תמונת פרופיל'),
      content: const Text('להגדיר את התמונה הזו כתמונת הפרופיל שלך?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('ביטול'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('הגדר כתמונת פרופיל'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    final response = await http.put(
      Uri.parse('$kApi/profile/photo-from-message'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'messageId': message['id']}),
    );
    if (!context.mounted) return;
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      me?['profile_pic_url'] = data['profile_pic_url'];
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('תמונת הפרופיל עודכנה')),
      );
    } else {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(data['error']?.toString() ?? 'העדכון נכשל')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('שגיאת תקשורת בעדכון התמונה')),
      );
    }
  }
}

MediaType _mimeFromFileName(String fileName) {
  switch (fileName.split('.').last.toLowerCase()) {
    case 'jpg':
    case 'jpeg':
      return MediaType('image', 'jpeg');
    case 'png':
      return MediaType('image', 'png');
    case 'gif':
      return MediaType('image', 'gif');
    case 'webp':
      return MediaType('image', 'webp');
    case 'pdf':
      return MediaType('application', 'pdf');
    case 'docx':
      return MediaType('application',
          'vnd.openxmlformats-officedocument.wordprocessingml.document');
    case 'mp3':
      return MediaType('audio', 'mpeg');
    case 'aac':
      return MediaType('audio', 'aac');
    case 'm4a':
      return MediaType('audio', 'mp4');
    case 'webm':
      return MediaType('audio', 'webm');
    case 'ogg':
      return MediaType('audio', 'ogg');
    case 'wav':
      return MediaType('audio', 'wav');
    default:
      return MediaType('application', 'octet-stream');
  }
}

Future<void> _copyMessageText(
    BuildContext context, Map<String, dynamic> message) async {
  final text = message['text'] as String? ?? '';
  if (text.isEmpty) return;
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(
        content: Text('ההודעה הועתקה'),
        duration: Duration(seconds: 1),
      ),
    );
}

Future<void> _downloadChatFile(
    BuildContext context, String fileUrl, String? originalFileName) async {
  final uri = Uri.parse(_absoluteMediaUrl(fileUrl));
  var opened = false;
  try {
    final fileName = (originalFileName ?? '').trim().isNotEmpty
        ? originalFileName!.trim()
        : Uri.decodeComponent(uri.pathSegments.last);
    opened = await triggerFileDownload(uri.toString(), fileName);
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('לא ניתן היה לפתוח את הקובץ')),
    );
  }
}

Future<void> _showReportDialog({
  required BuildContext context,
  required String token,
  required String targetType,
  required String targetId,
  required String targetLabel,
}) async {
  if (targetId.isEmpty || targetId.startsWith('temp_')) return;
  const reasons = <String, String>{
    'spam': 'ספאם או פרסום מטעה',
    'harassment': 'הטרדה או בריונות',
    'inappropriate': 'תוכן פוגעני או לא הולם',
    'fraud': 'התחזות, הונאה או תרמית',
    'illegal': 'פעילות או תוכן בלתי חוקיים',
    'other': 'סיבה אחרת',
  };
  var selectedReason = 'inappropriate';
  final detailsController = TextEditingController();
  final submit = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (_, setDialogState) => AlertDialog(
        title: Text('דיווח על $targetLabel'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              value: selectedReason,
              decoration: const InputDecoration(
                labelText: 'סיבת הדיווח',
                border: OutlineInputBorder(),
              ),
              items: reasons.entries
                  .map((entry) => DropdownMenuItem(
                      value: entry.key, child: Text(entry.value)))
                  .toList(),
              onChanged: (value) {
                if (value != null) setDialogState(() => selectedReason = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: detailsController,
              maxLength: 1000,
              maxLines: 4,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(
                labelText: 'פרטים נוספים (לא חובה)',
                border: OutlineInputBorder(),
              ),
            ),
            const Text(
              'הדיווח יועבר למנהלי בתשובה לבדיקה. המשתמש שעליו דווח לא יקבל את פרטיך.',
              style: TextStyle(fontSize: 12, color: kSubtext),
              textDirection: TextDirection.rtl,
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('ביטול')),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.flag_outlined, color: Colors.white),
            label: const Text('שליחת דיווח',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    ),
  );
  final details = detailsController.text.trim();
  detailsController.dispose();
  if (submit != true || !context.mounted) return;
  try {
    final response = await http.post(
      Uri.parse('$kApi/reports'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'targetType': targetType,
        'targetId': targetId,
        'reason': selectedReason,
        if (details.isNotEmpty) 'details': details,
      }),
    );
    if (!context.mounted) return;
    if (response.statusCode == 201) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('הדיווח התקבל ויועבר לבדיקה'),
        backgroundColor: kPrimary,
      ));
    } else {
      var message = 'לא ניתן היה לשלוח את הדיווח';
      try {
        message = (jsonDecode(response.body)['error'] as String?) ?? message;
      } catch (_) {}
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('שגיאת תקשורת בשליחת הדיווח')),
      );
    }
  }
}

bool _hasImageExtension(String? value) {
  if (value == null || value.isEmpty) return false;
  final v = value.toLowerCase();
  return v.endsWith('.jpg') ||
      v.endsWith('.jpeg') ||
      v.endsWith('.png') ||
      v.endsWith('.gif') ||
      v.endsWith('.webp');
}

bool _hasVideoExtension(String? value) {
  if (value == null || value.isEmpty) return false;
  final v = value.toLowerCase();
  return v.endsWith('.mp4') || v.endsWith('.webm') || v.endsWith('.mov');
}

String? _normalizeIncomingFileType(String? fileType,
    {String? fileUrl, String? fileName}) {
  // Extension check takes priority — DB may store 'text' even for image messages
  if (_hasImageExtension(fileUrl) || _hasImageExtension(fileName))
    return 'image';
  if (_hasVideoExtension(fileUrl) || _hasVideoExtension(fileName))
    return 'video';
  final t = (fileType ?? '').trim().toLowerCase();
  if (t.isEmpty) return null;
  if (t == 'image' || t.startsWith('image/')) return 'image';
  return t;
}

// ── Local notifications setup ─────────────────────────────────────
final _localNotif = FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage msg) async {
  await Firebase.initializeApp();
}

Future<void> _initLocalNotifications() async {
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const ios = DarwinInitializationSettings();
  await _localNotif.initialize(
    const InitializationSettings(android: android, iOS: ios),
  );
  const channel = AndroidNotificationChannel(
    'betshuva_messages',
    'הודעות ושיחות',
    description: 'התראות על הודעות, קבוצות ושיחות נכנסות',
    importance: Importance.high,
    playSound: true,
  );
  await _localNotif
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
}

void _showLocalNotification(RemoteMessage msg) {
  final n = msg.notification;
  if (n == null) return;
  _localNotif.show(
    msg.hashCode,
    n.title,
    n.body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'betshuva_messages',
        'הודעות',
        importance: Importance.high,
        priority: Priority.high,
        sound: RawResourceAndroidNotificationSound('default'),
      ),
      iOS: DarwinNotificationDetails(sound: 'default'),
    ),
  );
}

// ── Color Palette — Betshuva Brand ───────────────────────────────
const kPrimary = Color(0xFF1B6CA8); // Betshuva Blue
const kPrimaryMid = Color(0xFF3A8FCC); // Blue Light
const kAccent = Color(0xFF3A8FCC); // Blue Light
const kHeader = Color(0xFF0D4F82); // App bar / header
const kBg = Color(0xFFFFFFFF);
const kCard = Color(0xFFFFFFFF);
const kBorder = Color(0xFFD4E9F7); // divider
const kSubtext = Color(0xFF8AAFC9); // text-muted
const kTextDark = Color(0xFF0D2137); // text-primary
const kReadTick = Color(0xFF229ED9); // WhatsApp-style read double-tick
const kOutgoing = Color(0xFFD8EAFE); // outgoing bubble — soft blue
const kGroupOutgoing = Color(0xFFD8EAFE); // group outgoing bubble
const kChatBg = Color(0xFFEDF5FD); // ice-blue conversation background
const kIncoming = Color(0xFFFFFFFF); // incoming bubble
const kFilterBg = Color(0xFFE8F4FD); // filter banner background

const kServer = 'https://betshuva.com/betshuva-app';
const kApi = '$kServer/api';
final String? kPendingInviteId = Uri.base.queryParameters['invite'];
// Socket.IO treats any path in the connection URL as a *namespace*, not a URL
// prefix — so it must be given the bare origin plus an explicit `path` option
// (see kSocketPath below), or it'll try to handshake at "/socket.io/" on the
// domain root instead of through our nginx sub-path proxy.
final kServerUri = Uri.parse(kServer);
final kSocketOrigin = kServerUri.origin;
final kSocketPath = '${kServerUri.path}/socket.io/';
const kVersion = '1.2.96';
const kApkUrl = 'https://betshuva.com/betshuva-app/betshuva-1.2.96.apk';
const kScanBotId = '00000000-0000-4000-8000-000000000001';
const _shareChannel = MethodChannel('com.betshuva.app/share');

const _maxBatchImages = 20;
const _maxConcurrentImageUploads = 2;
var _uploadMessageSequence = 0;

String _newUploadMessageId(String prefix) =>
    '${prefix}${DateTime.now().microsecondsSinceEpoch}_${_uploadMessageSequence++}';

bool _looksLikeSticker(String text) {
  final value = text.trim();
  return value.isNotEmpty &&
      value.runes.length <= 5 &&
      !RegExp(r'[A-Za-z0-9א-ת]').hasMatch(value);
}

enum _FileUploadOutcome { approved, rejected, pending, scanBot, failed }

class _FileUploadResult {
  _FileUploadOutcome outcome;
  final Map<String, dynamic> data;
  String? error;

  _FileUploadResult(this.outcome,
      {this.data = const <String, dynamic>{}, this.error});
}

Future<_FileUploadResult> _uploadFileRequest({
  required dynamic file,
  required String fileName,
  required String token,
  required Map<String, String> fields,
}) async {
  try {
    final bytes = file is XFile
        ? await file.readAsBytes()
        : (file as PlatformFile).bytes ?? await File(file.path!).readAsBytes();
    var contentType = _mimeFromFileName(fileName);
    if (file is XFile &&
        file.mimeType != null &&
        file.mimeType!.contains('/')) {
      contentType = MediaType.parse(file.mimeType!.split(';').first);
    }
    final request = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
      ..headers['Authorization'] = 'Bearer $token'
      ..fields.addAll(fields)
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: fileName, contentType: contentType));
    final streamed = await request.send().timeout(const Duration(seconds: 60));
    final body = await streamed.stream.bytesToString();
    Map<String, dynamic> data = const <String, dynamic>{};
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) data = decoded;
    } catch (_) {}

    if (streamed.statusCode != 200) {
      return _FileUploadResult(
        _FileUploadOutcome.failed,
        data: data,
        error: data['error']?.toString() ?? 'שגיאה בהעלאה',
      );
    }
    if (data['status'] == 'rejected') {
      return _FileUploadResult(_FileUploadOutcome.rejected, data: data);
    }
    if (data['status'] == 'pending') {
      return _FileUploadResult(_FileUploadOutcome.pending, data: data);
    }
    if (data['handledByScanBot'] == true) {
      return _FileUploadResult(_FileUploadOutcome.scanBot, data: data);
    }
    if ((data['url'] as String? ?? '').isEmpty) {
      return _FileUploadResult(_FileUploadOutcome.failed,
          error: 'השרת לא החזיר כתובת לקובץ');
    }
    return _FileUploadResult(_FileUploadOutcome.approved, data: data);
  } catch (error) {
    return _FileUploadResult(_FileUploadOutcome.failed,
        error: 'שגיאת העלאה: $error');
  }
}

Future<List<_FileUploadResult>> _runImageUploadQueue(
  List<XFile> files,
  Future<_FileUploadResult> Function(XFile file) upload,
  ValueNotifier<int> completed, {
  Future<void> Function(int index, XFile file, _FileUploadResult result)?
      onResult,
}) async {
  final results = List<_FileUploadResult?>.filled(files.length, null);
  var nextIndex = 0;

  Future<void> worker() async {
    while (true) {
      final index = nextIndex;
      if (index >= files.length) return;
      nextIndex++;
      final result = await upload(files[index]);
      results[index] = result;
      if (onResult != null) {
        try {
          await onResult(index, files[index], result);
        } catch (error) {
          result.outcome = _FileUploadOutcome.failed;
          result.error = 'ההעלאה הסתיימה אך המסירה נכשלה: $error';
        }
      }
      completed.value++;
    }
  }

  final workerCount = math.min(_maxConcurrentImageUploads, files.length);
  await Future.wait(List.generate(workerCount, (_) => worker()));
  return results.cast<_FileUploadResult>();
}

Future<void> _showImageBatchProgress(
    BuildContext context, ValueNotifier<int> completed, int total) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Row(children: [
          Icon(Icons.security, color: kPrimary),
          SizedBox(width: 8),
          Text('סריקת תמונות'),
        ]),
        content: ValueListenableBuilder<int>(
          valueListenable: completed,
          builder: (_, count, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: total == 0 ? 0 : count / total,
                color: kPrimary,
              ),
              const SizedBox(height: 16),
              Text('נסרקו $count מתוך $total תמונות',
                  textDirection: TextDirection.rtl),
              const SizedBox(height: 6),
              const Text('כל תמונה נבדקת ונשלחת בנפרד',
                  style: TextStyle(fontSize: 12, color: kSubtext),
                  textDirection: TextDirection.rtl),
            ],
          ),
        ),
      ),
    ),
  );
}

void _showImageBatchSummary(
    BuildContext context, List<_FileUploadResult> results) {
  final approved = results
      .where((result) =>
          result.outcome == _FileUploadOutcome.approved ||
          result.outcome == _FileUploadOutcome.scanBot)
      .length;
  final rejected = results
      .where((result) => result.outcome == _FileUploadOutcome.rejected)
      .length;
  final pending = results
      .where((result) => result.outcome == _FileUploadOutcome.pending)
      .length;
  final failed = results
      .where((result) => result.outcome == _FileUploadOutcome.failed)
      .length;
  final parts = <String>[
    if (approved > 0) '$approved אושרו',
    if (rejected > 0) '$rejected נחסמו',
    if (pending > 0) '$pending ממתינות לסריקה',
    if (failed > 0) '$failed נכשלו',
  ];
  final hasProblem = rejected > 0 || pending > 0 || failed > 0;
  String? firstError;
  for (final result in results) {
    if (result.outcome == _FileUploadOutcome.failed && result.error != null) {
      firstError = result.error;
      break;
    }
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(
          'העלאת התמונות הסתיימה: ${parts.join(' · ')}'
          '${firstError == null ? '' : '\n$firstError'}',
          textDirection: TextDirection.rtl),
      backgroundColor: hasProblem ? Colors.orange.shade800 : kPrimary,
      duration: const Duration(seconds: 5),
    ));
}

String _absoluteMediaUrl(String url) =>
    Uri.parse(url).hasScheme ? url : Uri.parse(kServer).resolve(url).toString();

final Map<String, Future<Uint8List?>> _activeMediaLoads = {};

Future<Uint8List?> _loadPersistentMedia(String url) {
  final absoluteUrl = _absoluteMediaUrl(url);
  final existing = _activeMediaLoads[absoluteUrl];
  if (existing != null) return existing;
  final future = () async {
    final cached = await readMediaCache(absoluteUrl);
    if (cached != null && cached.isNotEmpty) return cached;
    final response = await http
        .get(Uri.parse(absoluteUrl))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final bytes = response.bodyBytes;
    if (bytes.isEmpty) return null;
    await writeMediaCache(absoluteUrl, bytes);
    return bytes;
  }();
  _activeMediaLoads[absoluteUrl] = future;
  void removeActiveLoad() {
    if (identical(_activeMediaLoads[absoluteUrl], future)) {
      _activeMediaLoads.remove(absoluteUrl);
    }
  }

  future.then((_) => removeActiveLoad(), onError: (_) => removeActiveLoad());
  return future;
}

class _PersistentMediaImage extends StatefulWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final WidgetBuilder? loadingBuilder;
  final WidgetBuilder? errorBuilder;

  const _PersistentMediaImage({
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.loadingBuilder,
    this.errorBuilder,
  });

  @override
  State<_PersistentMediaImage> createState() => _PersistentMediaImageState();
}

class _PersistentMediaImageState extends State<_PersistentMediaImage> {
  late Future<Uint8List?> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _loadPersistentMedia(widget.url);
  }

  @override
  void didUpdateWidget(covariant _PersistentMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _bytes = _loadPersistentMedia(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return Image.memory(
            bytes,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) =>
                widget.errorBuilder?.call(context) ?? const SizedBox.shrink(),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.loadingBuilder?.call(context) ??
              SizedBox(width: widget.width, height: widget.height);
        }
        return widget.errorBuilder?.call(context) ?? const SizedBox.shrink();
      },
    );
  }
}

Future<void> _persistRecentImageUrls(
    Iterable<Map<String, dynamic>> records) async {
  final urls = <String>{};
  for (final record in records.toList().reversed) {
    final fileUrl = record['fileUrl'] as String? ??
        record['file_url'] as String? ??
        record['image_url'] as String?;
    final fileType = _normalizeIncomingFileType(
      record['fileType'] as String? ?? record['type'] as String?,
      fileUrl: fileUrl,
      fileName: record['fileName'] as String? ?? record['file_name'] as String?,
    );
    if (fileUrl == null ||
        (fileType != 'image' && record['image_url'] == null)) {
      continue;
    }
    urls.add(fileUrl);
    if (urls.length >= 20) break;
  }
  for (final url in urls) {
    try {
      await _loadPersistentMedia(url);
    } catch (_) {}
  }
}

Future<void> _forwardChatMessage(BuildContext context, String token,
        IO.Socket? socket, Map<String, dynamic> message) =>
    _forwardChatMessages(context, token, socket, [message]);

Future<void> _forwardChatMessages(BuildContext context, String token,
    IO.Socket? socket, List<Map<String, dynamic>> messages) async {
  if (messages.isEmpty) return;
  if (messages.any((message) {
    final status = message['status'] as String?;
    return status == 'pending_scan' || status == 'rejected_scan';
  })) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('לא ניתן להעביר תמונה שלא אושרה בסריקה')));
    return;
  }
  try {
    final responses = await Future.wait([
      http.get(Uri.parse('$kApi/users'),
          headers: {'Authorization': 'Bearer $token'}),
      http.get(Uri.parse('$kApi/groups'),
          headers: {'Authorization': 'Bearer $token'}),
    ]);
    if (!context.mounted) return;
    final users = responses[0].statusCode == 200
        ? (jsonDecode(responses[0].body) as List).cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];
    final groups = responses[1].statusCode == 200
        ? (jsonDecode(responses[1].body) as List).cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];
    final target = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .72,
          child: Column(children: [
            const Padding(
              padding: EdgeInsets.all(18),
              child: Text('העבר אל',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: ListView(children: [
                if (users.isNotEmpty) const _SectionHeader(title: 'משתמשים'),
                ...users.map((user) => ListTile(
                      leading: UserAvatar(
                          picUrl: user['profile_pic_url'] as String?,
                          name: user['name'] as String? ?? ''),
                      title: Text(user['name'] as String? ?? 'משתמש'),
                      onTap: () => Navigator.pop(
                          sheetContext, {'kind': 'user', 'id': user['id']}),
                    )),
                if (groups.isNotEmpty) const _SectionHeader(title: 'קבוצות'),
                ...groups.map((group) => ListTile(
                      leading: UserAvatar(
                          picUrl: group['profile_pic_url'] as String?,
                          name: group['name'] as String? ?? ''),
                      title: Text(group['name'] as String? ?? 'קבוצה'),
                      onTap: () => Navigator.pop(
                          sheetContext, {'kind': 'group', 'id': group['id']}),
                    )),
              ]),
            ),
          ]),
        ),
      ),
    );
    if (target == null || !context.mounted) return;
    var sentCount = 0;
    for (final message in messages) {
      var fileUrl = message['fileUrl'] as String?;
      var fileName = message['fileName'] as String?;
      var fileType = message['fileType'] as String?;
      final localPath = message['localPath'] as String?;
      if (localPath != null || fileUrl != null) {
        final request = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
          ..headers['Authorization'] = 'Bearer $token'
          ..fields[target['kind'] == 'group' ? 'groupId' : 'toUserId'] =
              target['id'].toString();
        if (localPath != null) {
          request.files.add(await http.MultipartFile.fromPath('file', localPath,
              filename: fileName,
              contentType: _mimeFromFileName(fileName ?? localPath)));
        } else {
          final source = await http
              .get(Uri.parse(_absoluteMediaUrl(fileUrl!)))
              .timeout(const Duration(seconds: 30));
          if (source.statusCode != 200) {
            throw Exception('Could not download forwarded file');
          }
          final forwardedName = fileName ??
              Uri.parse(_absoluteMediaUrl(fileUrl)).pathSegments.last;
          request.files.add(http.MultipartFile.fromBytes(
              'file', source.bodyBytes,
              filename: forwardedName,
              contentType: _mimeFromFileName(forwardedName)));
        }
        final upload =
            await request.send().timeout(const Duration(seconds: 60));
        final uploadBody = await upload.stream.bytesToString();
        if (upload.statusCode != 200) {
          var uploadError = 'העלאת התמונה נכשלה';
          try {
            uploadError =
                (jsonDecode(uploadBody) as Map)['error']?.toString() ??
                    uploadError;
          } catch (_) {}
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(uploadError)));
          }
          return;
        }
        final uploaded = jsonDecode(uploadBody) as Map<String, dynamic>;
        if (uploaded['status'] == 'rejected') {
          final reason = uploaded['reason']?.toString() ??
              'התמונה נחסמה לפי הגדרות הסינון';
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(reason)));
          }
          return;
        }
        if (uploaded['status'] == 'pending') {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('התמונה נשלחה לסריקה ותועבר לאחר אישור')));
          }
          return;
        }
        fileUrl = uploaded['url'] as String?;
        fileName = uploaded['fileName'] as String? ?? fileName;
        fileType = uploaded['fileType'] as String? ?? 'image';
      }
      final payload = <String, dynamic>{
        'text': fileUrl == null ? (message['text'] as String? ?? '') : null,
        if (fileUrl != null) 'fileUrl': fileUrl,
        if (fileUrl != null) 'fileName': fileName,
        if (fileUrl != null) 'fileType': fileType,
      };
      var sent = false;
      if (target['kind'] == 'user') {
        final response = await http.post(Uri.parse('$kApi/messages'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json'
            },
            body: jsonEncode({...payload, 'toUserId': target['id']}));
        sent = response.statusCode == 200;
      } else {
        final response = await http.post(
          Uri.parse('$kApi/groups/${target['id']}/messages'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(payload),
        );
        sent = response.statusCode == 200;
      }
      if (sent) sentCount++;
    }
    if (context.mounted) {
      final allSent = sentCount == messages.length;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(allSent
            ? (messages.length == 1
                ? 'ההודעה הועברה'
                : '${messages.length} התמונות הועברו')
            : 'הועברו $sentCount מתוך ${messages.length} פריטים'),
      ));
    }
  } catch (error) {
    debugPrint('Forward message failed: $error');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('שגיאת תקשורת בהעברת ההודעה')));
    }
  }
}

// Google Web Client ID — set in Firebase Console → Authentication → Google → Web SDK config
const kGoogleWebClientId =
    '862738339788-0o8jv308efqdhb0q21eo9ut74oqcff80.apps.googleusercontent.com';

bool get kPhoneClient =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  try {
    if (kIsWeb) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'AIzaSyBCw4OzUPjquuw_kB1bFXqzOjZ-zPKrAP8',
          appId: '1:862738339788:web:36671c37704a2520f4af69',
          messagingSenderId: '862738339788',
          projectId: 'betshuva-c74a3',
          authDomain: 'betshuva-c74a3.firebaseapp.com',
          storageBucket: 'betshuva-c74a3.firebasestorage.app',
        ),
      );
    } else {
      await Firebase.initializeApp();
    }
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
    await _initLocalNotifications();
    FirebaseMessaging.onMessage.listen(_showLocalNotification);
  } catch (_) {}
  runApp(const BetshuvApp());
}

class _IsraelFlagPainter extends CustomPainter {
  const _IsraelFlagPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..color = const Color(0xFFD5E2EC)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final blue = Paint()
      ..color = const Color(0xFF1B6CA8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;

    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2)),
      Paint()..color = Colors.white,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2)),
      border,
    );
    canvas.drawLine(Offset(1, size.height * .25),
        Offset(size.width - 1, size.height * .25), blue);
    canvas.drawLine(Offset(1, size.height * .75),
        Offset(size.width - 1, size.height * .75), blue);

    Path triangle(double startAngle) {
      final path = Path();
      final center = Offset(size.width / 2, size.height / 2);
      final radius = size.height * .28;
      for (var i = 0; i < 3; i++) {
        final angle = startAngle + (i * 2 * math.pi / 3);
        final point =
            center + Offset(math.cos(angle), math.sin(angle)) * radius;
        i == 0
            ? path.moveTo(point.dx, point.dy)
            : path.lineTo(point.dx, point.dy);
      }
      return path..close();
    }

    canvas.drawPath(triangle(-math.pi / 2), blue);
    canvas.drawPath(triangle(math.pi / 2), blue);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

Widget _israelFlag() => const SizedBox(
      width: 30,
      height: 20,
      child: CustomPaint(painter: _IsraelFlagPainter()),
    );

Widget _magenDavid(
        {double size = 32, Color color = kPrimary, Color bg = Colors.white}) =>
    ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.20),
      child: Image.asset(
        'icon_source.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );

Widget _androidDownloadLink() => TextButton.icon(
      onPressed: () =>
          launchUrl(Uri.parse(kApkUrl), mode: LaunchMode.externalApplication),
      icon: const Icon(Icons.android, size: 20),
      label: const Text('הורדת betshuva-$kVersion.apk  •  גרסה $kVersion'),
      style: TextButton.styleFrom(foregroundColor: kPrimary),
    );

// ── App Root ──────────────────────────────────────────────────────
class BetshuvApp extends StatelessWidget {
  const BetshuvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'בתשובה',
      debugShowCheckedModeBanner: false,
      locale: const Locale('he', 'IL'),
      builder: (ctx, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
      theme: ThemeData(
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.light(
          primary: kPrimary,
          secondary: kAccent,
          surface: kCard,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kHeader,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: kCard,
          border: OutlineInputBorder(
            borderSide: const BorderSide(color: kBorder),
            borderRadius: BorderRadius.circular(10),
          ),
          enabledBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: kBorder, width: 1.5),
            borderRadius: BorderRadius.circular(10),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: kPrimaryMid, width: 2),
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: kPrimary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
          ),
        ),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}

// ── Splash Screen ─────────────────────────────────────────────────
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _ctrl.forward();
    http.get(Uri.parse('$kApi/version')).ignore(); // wake up server
    Future.delayed(const Duration(seconds: 2), _navigate);
  }

  Future<void> _navigate() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (!mounted) return;
    final verifiedEmail = Uri.base.queryParameters['verifiedEmail'];
    if (token == null && verifiedEmail?.isNotEmpty == true) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => AuthScreen(initialEmail: verifiedEmail),
        ),
      );
      return;
    }
    if (token != null) {
      try {
        final response = await http.get(
          Uri.parse('$kApi/registration-status'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 10));
        if (!mounted) return;
        if (response.statusCode == 200) {
          final status = jsonDecode(response.body) as Map<String, dynamic>;
          if (status['registrationIncomplete'] == true) {
            await prefs.remove('token');
            if (!mounted) return;
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => const AuthScreen(initialRegistration: true),
              ),
            );
            return;
          }
          if (status['phoneMissing'] == true ||
              status['verificationRequired'] == true) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => GooglePhoneSetupScreen(
                  token: token,
                  requireVerification: status['verificationRequired'] == true,
                ),
              ),
            );
            return;
          }
        } else if (response.statusCode == 401) {
          await prefs.remove('token');
        }
      } catch (_) {
        // Preserve offline startup when the registration check is unavailable.
      }
    }
    final activeToken = prefs.getString('token');
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => activeToken != null
            ? MainShell(token: activeToken)
            : const AuthScreen(),
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPrimary,
      body: Center(
        child: FadeTransition(
          opacity: _fade,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _magenDavid(
                  size: 96, color: Colors.white, bg: Colors.transparent),
              const SizedBox(height: 24),
              const Text(
                'בתשובה',
                style: TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Betshuva',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.white.withOpacity(0.7),
                  letterSpacing: 3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'מסר יהודי נקי',
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.white.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 60),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Phone Auth Screen (OTP via SMS) ──────────────────────────────
Map<String, bool> _newAccountFilter() => {
      'text': true,
      'video': false,
      'nonHumanImages': false,
      'men': false,
      'women': false,
      'children': false,
    };

class _RegistrationFilterSelector extends StatelessWidget {
  final Map<String, bool> filter;
  final bool confirmed;
  final ValueChanged<Map<String, bool>> onChanged;
  final ValueChanged<bool> onConfirmed;

  const _RegistrationFilterSelector({
    required this.filter,
    required this.confirmed,
    required this.onChanged,
    required this.onConfirmed,
  });

  static const _items = <String, (String, IconData)>{
    'text': ('טקסט', Icons.chat_bubble_outline),
    'nonHumanImages': ('טבע וחיות', Icons.landscape_outlined),
    'men': ('גברים', Icons.man),
    'women': ('נשים', Icons.woman),
    'children': ('ילדים', Icons.child_care),
    'video': ('וידאו', Icons.videocam_outlined),
  };

  @override
  Widget build(BuildContext context) {
    final selectedCount = filter.values.where((value) => value).length;
    final safeDefault = filter['text'] == true &&
        _items.keys
            .where((key) => key != 'text')
            .every((key) => filter[key] != true);
    return Container(
      margin: const EdgeInsets.only(top: 18),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: confirmed ? kPrimaryMid : const Color(0xFFC8DDEA),
            width: confirmed ? 1.8 : 1.2),
        boxShadow: const [
          BoxShadow(
              color: Color(0x120D5D91), blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: kPrimary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.shield_outlined, color: kPrimary),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('מה תרצה לקבל?',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  Text('אפשר לשנות זאת אחר כך בהגדרות',
                      style: TextStyle(color: kSubtext, fontSize: 12)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F3FA),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('$selectedCount נבחרו',
                  style: const TextStyle(
                      color: kPrimary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 14),
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onChanged(_newAccountFilter()),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: safeDefault
                    ? kPrimary.withValues(alpha: 0.09)
                    : const Color(0xFFF5F8FA),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: safeDefault ? kPrimaryMid : kBorder),
              ),
              child: Row(children: [
                Icon(
                    safeDefault
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked,
                    color: safeDefault ? kPrimary : kSubtext,
                    size: 22),
                const SizedBox(width: 9),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('טקסט בלבד — ברירת מחדל בטוחה',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700)),
                      Text('תמונות, חיות ווידאו חסומים',
                          style: TextStyle(color: kSubtext, fontSize: 11)),
                    ],
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          const Text('או התאמה אישית:',
              style: TextStyle(color: kSubtext, fontSize: 12)),
          const SizedBox(height: 7),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: _items.entries.map((entry) {
              final selected = filter[entry.key] == true;
              return FilterChip(
                selected: selected,
                showCheckmark: true,
                avatar: Icon(entry.value.$2,
                    size: 18, color: selected ? kPrimary : kSubtext),
                label: Text(entry.value.$1),
                labelStyle: TextStyle(
                    color: selected ? kPrimary : kTextDark,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
                selectedColor: const Color(0xFFE1F1FC),
                backgroundColor: const Color(0xFFF5F8FA),
                side: BorderSide(color: selected ? kPrimaryMid : kBorder),
                onSelected: (value) => onChanged({
                  ...filter,
                  entry.key: value,
                }),
              );
            }).toList(),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: confirmed ? null : () => onConfirmed(true),
              icon: Icon(confirmed
                  ? Icons.check_circle_rounded
                  : Icons.verified_user_outlined),
              label:
                  Text(confirmed ? 'בחירת הסינון אושרה' : 'אישור בחירת הסינון'),
              style: OutlinedButton.styleFrom(
                foregroundColor: confirmed ? Colors.white : kPrimary,
                backgroundColor: confirmed ? kPrimary : Colors.white,
                disabledForegroundColor: Colors.white,
                disabledBackgroundColor: kPrimary,
                side: const BorderSide(color: kPrimary),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RegistrationProgress extends StatelessWidget {
  final int current;
  const _RegistrationProgress({required this.current});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Row(
          children: [
            _step(1, 'פרטים וסינון'),
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.symmetric(horizontal: 8),
                color: current >= 2 ? kPrimaryMid : kBorder,
              ),
            ),
            _step(2, 'אימות'),
          ],
        ),
      );

  Widget _step(int number, String label) {
    final active = current >= number;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 25,
          height: 25,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? kPrimary : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: active ? kPrimary : kBorder),
          ),
          child: Text('$number',
              style: TextStyle(
                  color: active ? Colors.white : kSubtext,
                  fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: active ? kPrimary : kSubtext,
                fontSize: 11,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500)),
      ],
    );
  }
}

class PhoneAuthScreen extends StatefulWidget {
  const PhoneAuthScreen({super.key});
  @override
  State<PhoneAuthScreen> createState() => _PhoneAuthScreenState();
}

class _PhoneAuthScreenState extends State<PhoneAuthScreen> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  bool _otpSent = false;
  bool _loading = false;
  bool _acceptedTerms = false;
  bool _ageConfirmed = false;
  bool _filterConfirmed = false;
  Map<String, bool> _registrationFilter = _newAccountFilter();
  String? _gender;
  DateTime? _birthDate;
  String? _error;
  final _googleSignIn = GoogleSignIn(
    clientId: kIsWeb ? kGoogleWebClientId : null,
    serverClientId: kIsWeb ? null : kGoogleWebClientId,
  );

  bool get _supportsAutomaticSms =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<String?> _startAutomaticSmsReading() async {
    if (!_supportsAutomaticSms) return null;
    final signatureResult = await SmartAuth.instance.getAppSignature();
    if (!signatureResult.hasData) return null;
    unawaited(_readAndVerifySmsCode());
    return signatureResult.requireData;
  }

  Future<void> _readAndVerifySmsCode() async {
    final result = await SmartAuth.instance.getSmsWithRetrieverApi();
    if (!mounted || !result.hasData) return;
    final code = result.requireData.code;
    if (code == null || !RegExp(r'^\d{6}$').hasMatch(code)) return;
    _otpCtrl.text = code;
    setState(() => _otpSent = true);
    await _verifyOtp();
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _googleSignIn.signOut();
      final account = kIsWeb
          ? await _googleSignIn.signInSilently()
          : await _googleSignIn.signIn();
      if (account == null) {
        setState(() => _loading = false);
        return;
      }
      final idToken = (await account.authentication).idToken;
      if (idToken == null) throw Exception('לא התקבל טוקן מגוגל');
      final res = await http
          .post(
            Uri.parse('$kApi/auth/google'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'idToken': idToken,
              'acceptedTerms': _acceptedTerms,
              'ageConfirmed': _ageConfirmed,
              'gender': _gender,
              'birthDate':
                  _birthDate == null ? null : _formatBirthDate(_birthDate!),
              'contentFilter': _registrationFilter,
              'contentFilterConfirmed': _filterConfirmed,
              if (kPendingInviteId != null) 'inviteId': kPendingInviteId,
            }),
          )
          .timeout(const Duration(seconds: 30));
      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        setState(() {
          _error = data['error'] ?? 'שגיאה';
          _loading = false;
        });
        return;
      }
      final token = data['token'] as String;
      final user = data['user'] as Map<String, dynamic>?;
      final hasPhone = user != null &&
          (user['phone'] as String?) != null &&
          (user['phone'] as String).isNotEmpty;
      if (!mounted) return;
      if (!hasPhone) {
        Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (_) => GooglePhoneSetupScreen(
                      token: token,
                      requireVerification: false,
                    )));
      } else {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', token);
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => MainShell(token: token)));
      }
    } catch (e) {
      debugPrint('Google sign-in failed: $e');
      setState(() {
        _error = 'כניסה עם Google נכשלה: $e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    if (_supportsAutomaticSms) {
      unawaited(SmartAuth.instance.removeSmsRetrieverApiListener());
    }
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final phone = _normalizeIsraeliMobile(_phoneCtrl.text);
    if (!_isValidIsraeliMobile(phone)) {
      setState(() => _error = 'נא להזין מספר טלפון תקין');
      return;
    }
    if (!_acceptedTerms || !_ageConfirmed) {
      setState(() =>
          _error = 'יש לאשר את תנאי השימוש, מדיניות הפרטיות וגיל 13 ומעלה');
      return;
    }
    if (_birthDate == null) {
      setState(() => _error = 'יש לבחור תאריך לידה');
      return;
    }
    if (!_filterConfirmed) {
      setState(() => _error = 'יש לבחור ולאשר את הגדרות הסינון');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final appSignature = await _startAutomaticSmsReading();
      final res = await http
          .post(
            Uri.parse('$kApi/send-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'phone': phone,
              'name': _nameCtrl.text.trim(),
              'acceptedTerms': true,
              'ageConfirmed': true,
              'gender': _gender,
              'birthDate': _formatBirthDate(_birthDate!),
              'contentFilter': _registrationFilter,
              'contentFilterConfirmed': _filterConfirmed,
              if (appSignature != null) 'appSignature': appSignature,
            }),
          )
          .timeout(const Duration(seconds: 30));
      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        setState(() {
          _error = data['error'] ?? 'שגיאה בשליחה';
          _loading = false;
        });
        return;
      }
      setState(() {
        _otpSent = true;
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _error = 'שגיאת חיבור. נסה שוב.';
        _loading = false;
      });
    }
  }

  Future<void> _verifyOtp() async {
    final code = _otpCtrl.text.trim();
    if (code.length < 6) {
      setState(() => _error = 'נא להזין קוד בן 6 ספרות');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final phone = _normalizeIsraeliMobile(_phoneCtrl.text);
      final res = await http
          .post(
            Uri.parse('$kApi/verify-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'phone': phone, 'code': code}),
          )
          .timeout(const Duration(seconds: 30));
      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        setState(() {
          _error = data['error'] ?? 'קוד שגוי';
          _loading = false;
        });
        return;
      }
      final token = data['token'] as String;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', token);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => MainShell(token: token)),
      );
    } catch (_) {
      setState(() {
        _error = 'שגיאת חיבור. נסה שוב.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kIsWeb ? const Color(0xFFF2F7FB) : kBg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              decoration: BoxDecoration(
                color: kBg,
                borderRadius: BorderRadius.circular(24),
                boxShadow: kIsWeb
                    ? const [
                        BoxShadow(
                          color: Color(0x1A0D4F82),
                          blurRadius: 28,
                          offset: Offset(0, 10),
                        ),
                      ]
                    : null,
              ),
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 40),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Image.asset(
                        'icon_source.png',
                        width: 88,
                        height: 88,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('בתשובה',
                        style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.bold,
                            color: kPrimary)),
                    const SizedBox(height: 8),
                    Text(
                      _otpSent
                          ? 'הזן את הקוד שנשלח ב-SMS'
                          : 'הרשמה / כניסה עם טלפון',
                      style: const TextStyle(fontSize: 15, color: kSubtext),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 22),
                    _RegistrationProgress(current: _otpSent ? 2 : 1),
                    if (!_otpSent) ...[
                      TextField(
                        controller: _nameCtrl,
                        textDirection: TextDirection.rtl,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'שם מלא',
                          helperText: 'חובה בהרשמה חדשה בלבד',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _BirthDateField(
                        value: _birthDate,
                        onChanged: (value) =>
                            setState(() => _birthDate = value),
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<String>(
                        value: _gender,
                        decoration: const InputDecoration(
                          labelText: 'מגדר (חובה בהרשמה חדשה)',
                          prefixIcon: Icon(Icons.wc_outlined),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'male', child: Text('זכר')),
                          DropdownMenuItem(
                              value: 'female', child: Text('נקבה')),
                        ],
                        onChanged: (value) => setState(() => _gender = value),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        textDirection: TextDirection.ltr,
                        decoration: const InputDecoration(
                          labelText: 'מספר טלפון',
                          hintText: '05X-XXX-XXXX',
                          prefixIcon: Icon(Icons.phone_android),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const _BetaNotice(),
                      _RegistrationFilterSelector(
                        filter: _registrationFilter,
                        confirmed: _filterConfirmed,
                        onChanged: (value) => setState(() {
                          _registrationFilter = value;
                          _filterConfirmed = false;
                        }),
                        onConfirmed: (value) =>
                            setState(() => _filterConfirmed = value),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _ageConfirmed,
                        onChanged: (value) =>
                            setState(() => _ageConfirmed = value == true),
                        title: const Text('אני בן/בת 13 ומעלה',
                            style: TextStyle(fontSize: 13)),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _acceptedTerms,
                        onChanged: (value) =>
                            setState(() => _acceptedTerms = value == true),
                        title: const Text(
                            'קראתי ואני מסכים/ה לתנאי השימוש ולמדיניות הפרטיות',
                            style: TextStyle(fontSize: 13)),
                      ),
                    ] else ...[
                      const _SmsCodeWaitingAnimation(),
                      TextField(
                        controller: _otpCtrl,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        textAlign: TextAlign.center,
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                            fontSize: 32,
                            letterSpacing: 12,
                            fontWeight: FontWeight.bold),
                        decoration: const InputDecoration(
                            labelText: 'קוד אימות', counterText: ''),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8)),
                        child: Text(_error!,
                            style: const TextStyle(
                                color: Colors.red, fontSize: 13)),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _loading
                            ? null
                            : (_otpSent ? _verifyOtp : _sendOtp),
                        child: _loading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : Text(
                                _otpSent ? 'אמת קוד' : 'שלח קוד SMS',
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.bold),
                              ),
                      ),
                    ),
                    if (_otpSent) ...[
                      const SizedBox(height: 14),
                      TextButton(
                        onPressed: () => setState(() {
                          _otpSent = false;
                          _error = null;
                          _otpCtrl.clear();
                        }),
                        child: const Text('שנה מספר טלפון',
                            style: TextStyle(color: kSubtext)),
                      ),
                    ] else ...[
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _loading ? null : _signInWithGoogle,
                          icon: Image.network(
                            'https://developers.google.com/static/identity/images/g-logo.png',
                            width: 18,
                            height: 18,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox(width: 18, height: 18),
                          ),
                          label: const Text('המשך עם Google',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: kTextDark)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: kBorder, width: 1.5),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _androidDownloadLink(),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Auth Screen (Login / Register) ───────────────────────────────
class _SmsCodeWaitingAnimation extends StatefulWidget {
  const _SmsCodeWaitingAnimation();

  @override
  State<_SmsCodeWaitingAnimation> createState() =>
      _SmsCodeWaitingAnimationState();
}

class _SmsCodeWaitingAnimationState extends State<_SmsCodeWaitingAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F8FE),
        border: Border.all(color: const Color(0xFFB9DCF4)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: [
        Row(children: [
          SizedBox(
            width: 66,
            height: 66,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                final value = Curves.easeInOut.transform(_controller.value);
                return Stack(alignment: Alignment.center, children: [
                  Container(
                    width: 52 + (value * 12),
                    height: 52 + (value * 12),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kPrimary.withValues(alpha: .08 + value * .08),
                    ),
                  ),
                  Transform.scale(scale: .92 + value * .08, child: child),
                  PositionedDirectional(
                    end: value * 5,
                    bottom: 2 + value * 5,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: kPrimary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.sms_rounded,
                          color: Colors.white, size: 14),
                    ),
                  ),
                ]);
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(13),
                child: Image.asset('icon_source.png', width: 44, height: 44),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ממתינים לקוד ה־SMS…',
                    style: TextStyle(
                        color: kPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w800)),
                SizedBox(height: 4),
                Text(
                    'המסך פעיל. הקוד עשוי להגיע בתוך מספר שניות—יש להזין אותו מיד כשיתקבל.',
                    style: TextStyle(
                        color: kSubtext, fontSize: 12.5, height: 1.4)),
              ],
            ),
          ),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: const LinearProgressIndicator(
            minHeight: 4,
            color: kPrimary,
            backgroundColor: Color(0xFFD8EBF8),
          ),
        ),
      ]),
    );
  }
}

class AuthScreen extends StatefulWidget {
  final String? initialEmail;
  final bool initialRegistration;
  const AuthScreen(
      {super.key, this.initialEmail, this.initialRegistration = false});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLogin = true;
  bool _loading = false;
  bool _choosingVerification = false;
  bool _verificationRequired = false;
  bool _acceptedTerms = false;
  bool _ageConfirmed = false;
  bool _filterConfirmed = true;
  int _registrationStep = 0;
  String _registrationMethod = 'email';
  Map<String, bool> _registrationFilter = _newAccountFilter();
  String? _gender;
  DateTime? _birthDate;
  String _verificationMethod = 'email';
  bool _registrationCodeSent = false;
  bool _identityVerified = false;
  bool _showVerificationSuccess = false;
  String? _verificationProof;
  String? _googleRegistrationIdToken;
  String? _error;

  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _registrationCodeCtrl = TextEditingController();

  final _googleSignIn = GoogleSignIn(
    clientId: kIsWeb ? kGoogleWebClientId : null,
    serverClientId: kIsWeb ? null : kGoogleWebClientId,
  );

  bool get _supportsRegistrationSmsRetriever =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<String?> _startRegistrationSmsReading() async {
    if (!_supportsRegistrationSmsRetriever) return null;
    final signature = await SmartAuth.instance.getAppSignature();
    if (!signature.hasData) return null;
    unawaited(_readRegistrationSmsCode());
    return signature.requireData;
  }

  Future<void> _readRegistrationSmsCode() async {
    final result = await SmartAuth.instance.getSmsWithRetrieverApi();
    if (!mounted || !result.hasData) return;
    final code = result.requireData.code;
    if (code == null || !RegExp(r'^\d{6}$').hasMatch(code)) return;
    _registrationCodeCtrl.text = code;
    setState(() => _registrationCodeSent = true);
    await _verifyRegistrationCode();
  }

  @override
  void initState() {
    super.initState();
    _isLogin = !widget.initialRegistration;
    _emailCtrl.text = widget.initialEmail ?? '';
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      String? idToken = _googleRegistrationIdToken;
      if (idToken == null) {
        await _googleSignIn.signOut();
        final account = kIsWeb
            ? await _googleSignIn.signInSilently()
            : await _googleSignIn.signIn();
        if (account == null) {
          setState(() => _loading = false);
          return;
        }
        idToken = (await account.authentication).idToken;
      }
      if (idToken == null) throw Exception('לא התקבל טוקן מגוגל');

      final res = await http
          .post(
            Uri.parse('$kApi/auth/google'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'idToken': idToken,
              'acceptedTerms': _acceptedTerms,
              'ageConfirmed': _ageConfirmed,
              'gender': _gender,
              'birthDate':
                  _birthDate == null ? null : _formatBirthDate(_birthDate!),
              'contentFilter': _registrationFilter,
              'contentFilterConfirmed': _filterConfirmed,
              if (kPendingInviteId != null) 'inviteId': kPendingInviteId,
            }),
          )
          .timeout(const Duration(seconds: 30));
      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        setState(() {
          _error = data['error'] ?? 'שגיאה';
          _loading = false;
        });
        return;
      }
      final token = data['token'] as String;
      final user = data['user'] as Map<String, dynamic>?;
      final hasPhone = user != null &&
          (user['phone'] as String?) != null &&
          (user['phone'] as String).isNotEmpty;
      if (!mounted) return;
      if (!hasPhone) {
        Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (_) => GooglePhoneSetupScreen(
                      token: token,
                      requireVerification: false,
                    )));
      } else {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', token);
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => MainShell(token: token)));
      }
    } catch (e) {
      debugPrint('Google sign-in failed: $e');
      setState(() {
        _error = 'כניסה עם Google נכשלה: $e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    if (_supportsRegistrationSmsRetriever) {
      unawaited(SmartAuth.instance.removeSmsRetrieverApiListener());
    }
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _passCtrl.dispose();
    _registrationCodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text
        .replaceAll(
            RegExp(r'[\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]'), '')
        .trim()
        .toLowerCase();
    final password = _passCtrl.text;
    final name = _nameCtrl.text.trim();
    final phone = _normalizeIsraeliMobile(_phoneCtrl.text);

    if (_isLogin) {
      if (email.isEmpty || !email.contains('@')) {
        setState(() => _error = 'נא להזין כתובת אימייל תקינה');
        return;
      }
      if (password.length < 6) {
        setState(() => _error = 'הסיסמה חייבת להיות לפחות 6 תווים');
        return;
      }
    } else {
      if (!_acceptedTerms || !_ageConfirmed) {
        setState(() =>
            _error = 'יש לאשר את תנאי השימוש, מדיניות הפרטיות וגיל 13 ומעלה');
        return;
      }
      if (name.isEmpty) {
        setState(() => _error = 'נא להזין שם מלא');
        return;
      }
      if (_gender == null) {
        setState(() => _error = 'יש לבחור מגדר');
        return;
      }
      if (_birthDate == null) {
        setState(() => _error = 'יש לבחור תאריך לידה');
        return;
      }
      if (!_filterConfirmed) {
        setState(() => _error = 'יש לבחור ולאשר את הגדרות הסינון');
        return;
      }
      if (email.isEmpty || !email.contains('@')) {
        setState(() => _error = 'נא להזין כתובת אימייל תקינה');
        return;
      }
      if (!_isValidIsraeliMobile(phone)) {
        setState(() => _error = 'נא להזין מספר טלפון תקין');
        return;
      }
      if (password.length < 6) {
        setState(() => _error = 'הסיסמה חייבת להיות לפחות 6 תווים');
        return;
      }
    }

    if (!_isLogin && !_choosingVerification) {
      setState(() {
        _choosingVerification = true;
        _error = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_isLogin) {
        final res = await http
            .post(
              Uri.parse('$kApi/login'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'email': email, 'password': password}),
            )
            .timeout(const Duration(seconds: 30));
        final data = jsonDecode(res.body);
        if (res.statusCode != 200) {
          if (data['code'] == 'PHONE_REQUIRED' && data['token'] != null) {
            if (!mounted) return;
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (_) => GooglePhoneSetupScreen(
                  token: data['token'] as String,
                  requireVerification: false,
                ),
              ),
            );
            return;
          }
          setState(() {
            _error = data['error'] ?? 'שגיאה';
            _verificationRequired = data['code'] == 'VERIFICATION_REQUIRED';
            _loading = false;
          });
          return;
        }
        final token = data['token'] as String;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', token);
        if (!mounted) return;
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => MainShell(token: token)));
      } else {
        final res = await http
            .post(
              Uri.parse('$kApi/register'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'name': name,
                'email': email,
                'phone': phone,
                'password': password,
                'clientType': 'desktop',
                'verificationMethod': _verificationMethod,
                'acceptedTerms': true,
                'ageConfirmed': true,
                'gender': _gender,
                'birthDate': _formatBirthDate(_birthDate!),
                'contentFilter': _registrationFilter,
                'contentFilterConfirmed': _filterConfirmed,
                'verificationProof': _verificationProof,
                if (kPendingInviteId != null) 'inviteId': kPendingInviteId,
              }),
            )
            .timeout(const Duration(seconds: 30));
        final data = jsonDecode(res.body);
        if (res.statusCode != 200) {
          setState(() {
            _error = data['error'] ?? 'שגיאה';
            _loading = false;
          });
          return;
        }
        if (!mounted) return;
        final token = data['token'] as String?;
        if (token == null) throw Exception('לא התקבל טוקן התחברות');
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', token);
        if (!mounted) return;
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => MainShell(token: token)));
      }
    } catch (_) {
      setState(() {
        _error = 'שגיאת חיבור. נסה שוב.';
        _loading = false;
      });
    }
  }

  Future<void> _resendVerification(String method) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final email = _emailCtrl.text.trim().toLowerCase();
    try {
      final response = await http
          .post(
            Uri.parse('$kApi/resend-verification'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email,
              'password': _passCtrl.text,
              'method': method,
            }),
          )
          .timeout(const Duration(seconds: 30));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() {
          _error = data['error'] as String? ?? 'שליחת האימות נכשלה';
          _loading = false;
        });
        return;
      }
      if (method == 'phone') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => VerifyScreen(
              phone: data['phone'] as String,
              email: email,
              method: 'phone',
            ),
          ),
        );
      } else {
        setState(() {
          _verificationRequired = false;
          _loading = false;
          _error = 'קישור אימות חדש נשלח ל-$email';
        });
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _error = 'שגיאת חיבור. נסה שוב.';
          _loading = false;
        });
    }
  }

  Future<void> _selectRegistrationMethod(String method) async {
    setState(() {
      _registrationMethod = method;
      _verificationMethod = method == 'phone' ? 'phone' : 'email';
      _identityVerified = false;
      _verificationProof = null;
      _registrationCodeSent = false;
      _showVerificationSuccess = false;
      _registrationCodeCtrl.clear();
      _error = null;
      if (method != 'google') _registrationStep = 1;
    });
    if (method != 'google') return;
    setState(() => _loading = true);
    try {
      await _googleSignIn.signOut();
      final account = kIsWeb
          ? await _googleSignIn.signInSilently()
          : await _googleSignIn.signIn();
      if (account == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final auth = await account.authentication;
      if (auth.idToken == null) throw Exception('לא התקבל טוקן מגוגל');
      final response = await http
          .post(
            Uri.parse('$kApi/registration/verify-google'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'idToken': auth.idToken}),
          )
          .timeout(const Duration(seconds: 30));
      final data = _registrationResponseData(response);
      if (response.statusCode != 200)
        throw Exception(data['error'] ?? 'אימות Google נכשל');
      if (!mounted) return;
      setState(() {
        _googleRegistrationIdToken = auth.idToken;
        _identityVerified = true;
        _nameCtrl.text = (data['name'] as String?) ?? '';
        _emailCtrl.text = (data['email'] as String?) ?? '';
        _loading = false;
      });
      await _showSuccessfulVerification();
    } catch (e) {
      if (mounted)
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
    }
  }

  Future<void> _sendRegistrationCode() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    final phone = _normalizeIsraeliMobile(_phoneCtrl.text);
    if (_registrationMethod == 'email' &&
        (email.isEmpty || !email.contains('@'))) {
      _registrationError('נא להזין כתובת אימייל תקינה');
      return;
    }
    if (_registrationMethod == 'phone' && !_isValidIsraeliMobile(phone)) {
      _registrationError('נא להזין מספר טלפון תקין');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final webOtpFuture = _registrationMethod == 'phone' && kIsWeb
        ? readWebOtp()
        : Future<String?>.value(null);
    try {
      final appSignature = _registrationMethod == 'phone'
          ? await _startRegistrationSmsReading()
          : null;
      final response = await http
          .post(
            Uri.parse('$kApi/registration/send-code'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'method': _registrationMethod,
              'email': email,
              'phone': phone,
              if (appSignature != null) 'appSignature': appSignature,
            }),
          )
          .timeout(const Duration(seconds: 30));
      final data = _registrationResponseData(response);
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (response.statusCode == 200)
          _registrationCodeSent = true;
        else
          _error = data['error'] as String? ?? 'שליחת הקוד נכשלה';
      });
      if (response.statusCode == 200 &&
          _registrationMethod == 'phone' &&
          kIsWeb) {
        final code = await webOtpFuture;
        if (code != null && mounted) {
          _registrationCodeCtrl.text = code;
          await _verifyRegistrationCode();
        }
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = 'שגיאת חיבור. נסה שוב.';
        });
    }
  }

  Future<void> _verifyRegistrationCode() async {
    if (_registrationCodeCtrl.text.trim().length != 6) {
      _registrationError('נא להזין קוד בן 6 ספרות');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await http
          .post(
            Uri.parse('$kApi/registration/verify-code'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'method': _registrationMethod,
              'email': _emailCtrl.text.trim().toLowerCase(),
              'phone': _normalizeIsraeliMobile(_phoneCtrl.text),
              'code': _registrationCodeCtrl.text.trim(),
            }),
          )
          .timeout(const Duration(seconds: 30));
      final data = _registrationResponseData(response);
      if (!mounted) return;
      if (response.statusCode != 200) {
        setState(() {
          _loading = false;
          _error = data['error'] as String? ?? 'הקוד שגוי';
        });
        return;
      }
      setState(() {
        _verificationProof = data['proof'] as String;
        _identityVerified = true;
        _loading = false;
      });
      await _showSuccessfulVerification();
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = 'שגיאת חיבור. נסה שוב.';
        });
    }
  }

  void _registrationError(String message) {
    setState(() => _error = message);
  }

  Future<void> _showSuccessfulVerification() async {
    if (!mounted) return;
    setState(() {
      _showVerificationSuccess = true;
      _error = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    if (!mounted) return;
    setState(() {
      _showVerificationSuccess = false;
      _registrationStep = 2;
    });
  }

  Map<String, dynamic> _registrationResponseData(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {'error': 'שירות האימות אינו זמין כרגע. נסה שוב בעוד רגע.'};
  }

  void _nextRegistrationStep() {
    if (_registrationStep == 2) {
      if (_nameCtrl.text.trim().isEmpty) {
        _registrationError('נא להזין שם מלא');
        return;
      }
      if (_birthDate == null) {
        _registrationError('יש לבחור תאריך לידה');
        return;
      }
      if (_gender == null) {
        _registrationError('יש לבחור מגדר');
        return;
      }
      if (_registrationMethod != 'google') {
        final email = _emailCtrl.text.trim();
        final phone = _normalizeIsraeliMobile(_phoneCtrl.text);
        if (email.isEmpty || !email.contains('@')) {
          _registrationError('נא להזין כתובת אימייל תקינה');
          return;
        }
        if (!_isValidIsraeliMobile(phone)) {
          _registrationError('נא להזין מספר טלפון תקין');
          return;
        }
      }
    }
    setState(() {
      _error = null;
      _registrationStep = (_registrationStep + 1).clamp(0, 4);
    });
  }

  Future<void> _finishRegistration() async {
    if (_registrationMethod != 'google' && _passCtrl.text.length < 6) {
      _registrationError('הסיסמה חייבת להיות לפחות 6 תווים');
      return;
    }
    if (!_ageConfirmed || !_acceptedTerms) {
      _registrationError(
          'יש לאשר גיל 13 ומעלה ואת תנאי השימוש ומדיניות הפרטיות');
      return;
    }
    if (_registrationMethod == 'google') {
      await _signInWithGoogle();
      return;
    }
    setState(() {
      _choosingVerification = true;
      _error = null;
    });
    await _submit();
  }

  Widget _registrationMethodCard({
    required String method,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final selected = _registrationMethod == method;
    return InkWell(
      onTap: _loading ? null : () => _selectRegistrationMethod(method),
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE7F3FC) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: selected ? kPrimary : kBorder, width: selected ? 2 : 1.2),
        ),
        child: Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: selected ? kPrimary : const Color(0xFFF0F5F8),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: selected ? Colors.white : kPrimary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(color: kSubtext, fontSize: 12)),
              ],
            ),
          ),
          Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? kPrimary : kSubtext),
        ]),
      ),
    );
  }

  Widget _registrationStepContent() {
    switch (_registrationStep) {
      case 0:
        return Column(children: [
          const Text('איך תרצה להירשם?',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('בחר דרך אחת. ניתן להשלים את התהליך בתוך דקות.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kSubtext, fontSize: 12.5)),
          const SizedBox(height: 20),
          _registrationMethodCard(
              method: 'google',
              icon: Icons.g_mobiledata_rounded,
              title: 'הרשמה באמצעות Google',
              subtitle: 'מהיר ומאובטח — ללא יצירת סיסמה נוספת'),
          const SizedBox(height: 12),
          _registrationMethodCard(
              method: 'email',
              icon: Icons.alternate_email_rounded,
              title: 'הרשמה באימייל',
              subtitle: 'יצירת חשבון עם אימייל, טלפון וסיסמה'),
          const SizedBox(height: 12),
          _registrationMethodCard(
              method: 'phone',
              icon: Icons.sms_outlined,
              title: 'הרשמה עם SMS',
              subtitle: 'קוד אימות מיידי למספר הטלפון'),
        ]);
      case 1:
        if (_showVerificationSuccess) {
          return Column(children: [
            const SizedBox(height: 28),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.55, end: 1),
              duration: const Duration(milliseconds: 450),
              curve: Curves.elasticOut,
              builder: (context, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5F3FC),
                  shape: BoxShape.circle,
                  border: Border.all(color: kPrimary, width: 3),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x331B75B3),
                        blurRadius: 18,
                        offset: Offset(0, 7)),
                  ],
                ),
                child:
                    const Icon(Icons.check_rounded, color: kPrimary, size: 58),
              ),
            ),
            const SizedBox(height: 22),
            const Text('האימות הצליח!',
                style: TextStyle(
                    color: kPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            const Text('הפרטים אומתו בהצלחה\nממשיכים להשלמת ההרשמה',
                textAlign: TextAlign.center,
                style: TextStyle(color: kSubtext, fontSize: 14, height: 1.5)),
            const SizedBox(height: 22),
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ]);
        }
        if (_registrationMethod == 'google') {
          return const Column(children: [
            Icon(Icons.verified_user_rounded, size: 62, color: kPrimary),
            SizedBox(height: 14),
            Text('אימות משתמש עם Google',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            SizedBox(height: 10),
            Text(
              'בסיום ההרשמה ייפתח חלון Google לאימות זהותך.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kSubtext, fontSize: 14, height: 1.5),
            ),
          ]);
        }
        return Column(children: [
          const Text('אימות משתמש',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
              _registrationMethod == 'phone'
                  ? 'הזן מספר טלפון בלבד וקבל קוד ב־SMS'
                  : 'הזן כתובת אימייל בלבד וקבל קוד אימות',
              textAlign: TextAlign.center,
              style: const TextStyle(color: kSubtext, fontSize: 12.5)),
          const SizedBox(height: 14),
          if (_registrationMethod == 'phone')
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                  labelText: 'מספר טלפון',
                  hintText: '05X-XXX-XXXX',
                  prefixIcon: Icon(Icons.phone_android)),
            )
          else
            TextField(
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                  labelText: 'כתובת אימייל',
                  prefixIcon: Icon(Icons.email_outlined)),
            ),
          const SizedBox(height: 12),
          if (_registrationCodeSent) ...[
            if (_registrationMethod == 'phone')
              const _SmsCodeWaitingAnimation(),
            TextField(
              controller: _registrationCodeCtrl,
              keyboardType: TextInputType.number,
              maxLength: 6,
              autofillHints: const [AutofillHints.oneTimeCode],
              textAlign: TextAlign.center,
              textDirection: TextDirection.ltr,
              onChanged: (value) {
                final code = value.replaceAll(RegExp(r'\D'), '');
                if (code != value) {
                  _registrationCodeCtrl.value = TextEditingValue(
                    text: code,
                    selection: TextSelection.collapsed(offset: code.length),
                  );
                }
                if (code.length == 6 && !_loading) {
                  unawaited(_verifyRegistrationCode());
                }
              },
              decoration: const InputDecoration(
                  labelText: 'קוד אימות',
                  counterText: '',
                  prefixIcon: Icon(Icons.password_rounded)),
            ),
            TextButton(
              onPressed: _loading ? null : _sendRegistrationCode,
              child: const Text('שלח קוד חדש'),
            ),
          ] else
            Text(
              _registrationMethod == 'phone'
                  ? 'קוד האימות יישלח ב־SMS'
                  : 'קוד האימות יישלח לאימייל',
              style: const TextStyle(color: kSubtext, fontSize: 12.5),
            ),
        ]);
      case 2:
        return Column(children: [
          const Text('השלמת פרטים',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            textDirection: TextDirection.rtl,
            decoration: const InputDecoration(
                labelText: 'שם מלא', prefixIcon: Icon(Icons.person_outline)),
          ),
          const SizedBox(height: 12),
          _BirthDateField(
              value: _birthDate,
              onChanged: (value) => setState(() => _birthDate = value)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _gender,
            decoration: const InputDecoration(
                labelText: 'מגדר', prefixIcon: Icon(Icons.wc_outlined)),
            items: const [
              DropdownMenuItem(value: 'male', child: Text('זכר')),
              DropdownMenuItem(value: 'female', child: Text('נקבה')),
            ],
            onChanged: (value) => setState(() => _gender = value),
          ),
          if (_registrationMethod != 'google') ...[
            const SizedBox(height: 12),
            if (_registrationMethod == 'email')
              TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                    labelText: 'מספר טלפון',
                    hintText: '05X-XXX-XXXX',
                    prefixIcon: Icon(Icons.phone_android)),
              )
            else
              TextField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                    labelText: 'כתובת אימייל',
                    prefixIcon: Icon(Icons.email_outlined)),
              ),
          ],
        ]);
      case 3:
        const filterItems = <String, (String, IconData)>{
          'text': ('טקסט', Icons.chat_bubble_outline),
          'nonHumanImages': ('תמונות נוף או חפצים', Icons.landscape_outlined),
          'men': ('גברים', Icons.man),
          'women': ('נשים', Icons.woman),
          'children': ('ילדים', Icons.child_care),
          'video': ('וידאו', Icons.videocam_outlined),
        };
        return Column(children: [
          const Text('בחירת סינון',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('בחר אילו סוגי תוכן תרצה לקבל',
              style: TextStyle(color: kSubtext, fontSize: 12.5)),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: filterItems.entries.map((entry) {
              final selected = _registrationFilter[entry.key] == true;
              return InkWell(
                onTap: () => setState(() {
                  _registrationFilter = {
                    ..._registrationFilter,
                    entry.key: !selected
                  };
                  _filterConfirmed = true;
                }),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsetsDirectional.only(end: 10),
                  decoration: BoxDecoration(
                    color: selected ? const Color(0xFFE7F3FC) : Colors.white,
                    border: Border.all(color: selected ? kPrimary : kBorder),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Checkbox(
                      value: selected,
                      onChanged: (value) => setState(() {
                        _registrationFilter = {
                          ..._registrationFilter,
                          entry.key: value == true
                        };
                        _filterConfirmed = true;
                      }),
                    ),
                    Icon(entry.value.$2, size: 18, color: kPrimary),
                    const SizedBox(width: 5),
                    Text(entry.value.$1),
                  ]),
                ),
              );
            }).toList(),
          ),
        ]);
      default:
        return Column(children: [
          const Text('אישור וסיום',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          if (_registrationMethod != 'google') ...[
            TextField(
              controller: _passCtrl,
              obscureText: true,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                  labelText: 'יצירת סיסמה — לפחות 6 תווים',
                  prefixIcon: Icon(Icons.lock_outline)),
            ),
            const SizedBox(height: 8),
          ],
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _ageConfirmed,
            onChanged: (value) => setState(() => _ageConfirmed = value == true),
            title: const Text('אני בן/בת 13 ומעלה'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _acceptedTerms,
            onChanged: (value) =>
                setState(() => _acceptedTerms = value == true),
            title: const Text(
                'קראתי ואני מסכים/ה לתנאי השימוש ולמדיניות הפרטיות',
                style: TextStyle(fontSize: 13)),
          ),
          if (_registrationMethod == 'google') ...[
            const SizedBox(height: 10),
            const Text('הזהות אומתה באמצעות Google',
                textAlign: TextAlign.center,
                style: TextStyle(color: kSubtext, fontSize: 12.5)),
          ] else ...[
            const SizedBox(height: 10),
            Text(
                _registrationMethod == 'phone'
                    ? 'מספר הטלפון אומת בהצלחה באמצעות SMS'
                    : 'כתובת האימייל אומתה בהצלחה',
                textAlign: TextAlign.center,
                style: const TextStyle(color: kSubtext, fontSize: 12.5)),
          ],
        ]);
    }
  }

  Widget _buildRegistrationWizard() {
    return Scaffold(
      backgroundColor: kIsWeb ? const Color(0xFFF2F7FB) : kBg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Container(
              height: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 14),
              decoration: BoxDecoration(
                color: kBg,
                borderRadius: BorderRadius.circular(24),
                boxShadow: kIsWeb
                    ? const [
                        BoxShadow(color: Color(0x1A0D4F82), blurRadius: 24)
                      ]
                    : null,
              ),
              child: Column(children: [
                Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child:
                        Image.asset('icon_source.png', width: 46, height: 46),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('בתשובה',
                            style: TextStyle(
                                color: kPrimary,
                                fontSize: 22,
                                fontWeight: FontWeight.w800)),
                        Text('הרשמה שלב אחר שלב',
                            style: TextStyle(color: kSubtext, fontSize: 12)),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _isLogin = true;
                      _error = null;
                    }),
                    child: const Text('כניסה'),
                  ),
                ]),
                const SizedBox(height: 10),
                Row(
                  children: List.generate(
                      5,
                      (index) => Expanded(
                            child: Container(
                              height: 5,
                              margin: EdgeInsets.only(left: index == 4 ? 0 : 5),
                              decoration: BoxDecoration(
                                color: index <= _registrationStep
                                    ? kPrimary
                                    : kBorder,
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                          )),
                ),
                const SizedBox(height: 6),
                Text('שלב ${_registrationStep + 1} מתוך 5',
                    style: const TextStyle(color: kSubtext, fontSize: 11)),
                const SizedBox(height: 12),
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: SingleChildScrollView(
                        key: ValueKey(_registrationStep),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.only(bottom: 16),
                        child: SizedBox(
                          width: double.infinity,
                          child: _registrationStepContent(),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(9)),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 12)),
                  ),
                Row(children: [
                  if (_registrationStep > 0)
                    OutlinedButton(
                      onPressed: _loading || _showVerificationSuccess
                          ? null
                          : () => setState(() {
                                _registrationStep--;
                                _error = null;
                              }),
                      child: const Text('חזרה'),
                    ),
                  if (_registrationStep > 0) const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _loading
                          ? null
                          : (_registrationStep == 1 && !_identityVerified
                              ? (_registrationCodeSent
                                  ? _verifyRegistrationCode
                                  : _sendRegistrationCode)
                              : (_registrationStep == 4
                                  ? _finishRegistration
                                  : _nextRegistrationStep)),
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(_registrationStep == 1 && !_identityVerified
                              ? (_registrationCodeSent
                                  ? 'אמת קוד והמשך'
                                  : 'שלח קוד אימות')
                              : (_registrationStep == 4
                                  ? (_registrationMethod == 'google'
                                      ? 'סיום הרשמה'
                                      : 'יצירת חשבון')
                                  : 'המשך')),
                    ),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLogin) return _buildRegistrationWizard();
    return Scaffold(
      backgroundColor: kIsWeb ? const Color(0xFFF2F7FB) : kBg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              decoration: BoxDecoration(
                color: kBg,
                borderRadius: BorderRadius.circular(24),
                boxShadow: kIsWeb
                    ? const [
                        BoxShadow(
                          color: Color(0x1A0D4F82),
                          blurRadius: 28,
                          offset: Offset(0, 10),
                        ),
                      ]
                    : null,
              ),
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 40),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: Image.asset(
                        'icon_source.png',
                        width: 88,
                        height: 88,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('בתשובה',
                        style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.bold,
                            color: kPrimary)),
                    const SizedBox(height: 4),
                    _israelFlag(),
                    const SizedBox(height: 6),
                    Text(_isLogin ? 'כניסה לחשבון' : 'יצירת חשבון חדש',
                        style: const TextStyle(fontSize: 15, color: kSubtext)),
                    const SizedBox(height: 32),
                    // Toggle
                    Container(
                      decoration: BoxDecoration(
                          color: kBorder,
                          borderRadius: BorderRadius.circular(10)),
                      child: Row(children: [
                        _TabBtn(
                            label: 'כניסה',
                            active: _isLogin,
                            onTap: () => setState(() {
                                  _isLogin = true;
                                  _choosingVerification = false;
                                  _error = null;
                                })),
                        _TabBtn(
                            label: 'הרשמה',
                            active: !_isLogin,
                            onTap: () => setState(() {
                                  _isLogin = false;
                                  _choosingVerification = false;
                                  _error = null;
                                })),
                      ]),
                    ),
                    const SizedBox(height: 24),
                    if (!_isLogin)
                      _RegistrationProgress(
                          current: _choosingVerification ? 2 : 1),
                    if (!_isLogin) ...[
                      TextField(
                        controller: _nameCtrl,
                        textDirection: TextDirection.rtl,
                        decoration: const InputDecoration(
                            labelText: 'שם מלא',
                            prefixIcon: Icon(Icons.person_outline)),
                      ),
                      const SizedBox(height: 14),
                      _BirthDateField(
                        value: _birthDate,
                        onChanged: (value) =>
                            setState(() => _birthDate = value),
                      ),
                      const SizedBox(height: 14),
                      DropdownButtonFormField<String>(
                        value: _gender,
                        decoration: const InputDecoration(
                          labelText: 'מגדר',
                          prefixIcon: Icon(Icons.wc_outlined),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'male', child: Text('זכר')),
                          DropdownMenuItem(
                              value: 'female', child: Text('נקבה')),
                        ],
                        onChanged: (value) => setState(() => _gender = value),
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (!_isLogin) ...[
                      TextField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        textDirection: TextDirection.ltr,
                        decoration: const InputDecoration(
                          labelText: 'מספר טלפון',
                          hintText: '05X-XXX-XXXX',
                          prefixIcon: Icon(Icons.phone_android),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                          labelText: 'כתובת אימייל',
                          prefixIcon: Icon(Icons.email_outlined)),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _passCtrl,
                      obscureText: true,
                      textDirection: TextDirection.ltr,
                      decoration: const InputDecoration(
                          labelText: 'סיסמה',
                          prefixIcon: Icon(Icons.lock_outline)),
                    ),
                    if (!_isLogin && _choosingVerification) ...[
                      const SizedBox(height: 18),
                      const Align(
                        alignment: Alignment.centerRight,
                        child: Text('הפרטים תקינים — איך תרצה לאמת?',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        decoration: BoxDecoration(
                            color: kBorder,
                            borderRadius: BorderRadius.circular(10)),
                        child: Row(children: [
                          _TabBtn(
                            label: 'באימייל',
                            active: _verificationMethod == 'email',
                            onTap: () =>
                                setState(() => _verificationMethod = 'email'),
                          ),
                          _TabBtn(
                            label: 'בטלפון',
                            active: _verificationMethod == 'phone',
                            onTap: () =>
                                setState(() => _verificationMethod = 'phone'),
                          ),
                        ]),
                      ),
                    ],
                    if (!_isLogin) ...[
                      _RegistrationFilterSelector(
                        filter: _registrationFilter,
                        confirmed: _filterConfirmed,
                        onChanged: (value) => setState(() {
                          _registrationFilter = value;
                          _filterConfirmed = false;
                        }),
                        onConfirmed: (value) =>
                            setState(() => _filterConfirmed = value),
                      ),
                      const _BetaNotice(),
                      const SizedBox(height: 6),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _ageConfirmed,
                        onChanged: (value) =>
                            setState(() => _ageConfirmed = value == true),
                        title: const Text('אני בן/בת 13 ומעלה',
                            style: TextStyle(fontSize: 13)),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _acceptedTerms,
                        onChanged: (value) =>
                            setState(() => _acceptedTerms = value == true),
                        title: Wrap(children: [
                          const Text('קראתי ואני מסכים/ה ל',
                              style: TextStyle(fontSize: 13)),
                          InkWell(
                            onTap: () => launchUrl(Uri.parse('$kServer/terms'),
                                mode: LaunchMode.externalApplication),
                            child: const Text('תנאי השימוש',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: kPrimary,
                                    decoration: TextDecoration.underline)),
                          ),
                          const Text(' ול', style: TextStyle(fontSize: 13)),
                          InkWell(
                            onTap: () => launchUrl(
                                Uri.parse('$kServer/privacy'),
                                mode: LaunchMode.externalApplication),
                            child: const Text('מדיניות הפרטיות',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: kPrimary,
                                    decoration: TextDecoration.underline)),
                          ),
                        ]),
                      ),
                    ],
                    if (_isLogin) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const ForgotPasswordScreen()),
                          ),
                          child: const Text('שכחתי סיסמה',
                              style: TextStyle(color: kSubtext, fontSize: 13)),
                        ),
                      ),
                    ] else
                      const SizedBox(height: 12),
                    if (_error != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                            color: Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8)),
                        child: Text(_error!,
                            style: const TextStyle(
                                color: Colors.red, fontSize: 13)),
                      ),
                    if (_isLogin && _verificationRequired) ...[
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _loading
                                ? null
                                : () => _resendVerification('email'),
                            icon: const Icon(Icons.email_outlined),
                            label: const Text('שלח שוב למייל'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _loading
                                ? null
                                : () => _resendVerification('phone'),
                            icon: const Icon(Icons.sms_outlined),
                            label: const Text('אמת בטלפון'),
                          ),
                        ),
                      ]),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _loading ? null : _submit,
                        child: _loading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : Text(
                                _isLogin
                                    ? 'כניסה'
                                    : _choosingVerification
                                        ? 'יצירת חשבון ושליחת אימות'
                                        : 'המשך לשלב האימות',
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(children: [
                      const Expanded(child: Divider(color: kBorder)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text('או',
                            style: TextStyle(color: kSubtext, fontSize: 13)),
                      ),
                      const Expanded(child: Divider(color: kBorder)),
                    ]),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _loading ? null : _signInWithGoogle,
                        icon: Image.network(
                          'https://developers.google.com/static/identity/images/g-logo.png',
                          width: 18,
                          height: 18,
                          errorBuilder: (_, __, ___) =>
                              const SizedBox(width: 18, height: 18),
                        ),
                        label: const Text('המשך עם Google',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: kTextDark)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: kBorder, width: 1.5),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _androidDownloadLink(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Phone Setup Screen (after Google Sign-In) ────────────────────
class GooglePhoneSetupScreen extends StatefulWidget {
  final String token;
  final bool requireVerification;
  const GooglePhoneSetupScreen(
      {super.key, required this.token, this.requireVerification = true});
  @override
  State<GooglePhoneSetupScreen> createState() => _GooglePhoneSetupScreenState();
}

class _GooglePhoneSetupScreenState extends State<GooglePhoneSetupScreen> {
  final _phoneCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  bool _sentOtp = false;
  bool _loading = false;
  String? _error;

  bool get _supportsAutomaticSms =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<String?> _startAutomaticSmsReading() async {
    if (!_supportsAutomaticSms) return null;
    final signatureResult = await SmartAuth.instance.getAppSignature();
    if (!signatureResult.hasData) return null;
    unawaited(_readAndVerifySmsCode());
    return signatureResult.requireData;
  }

  Future<void> _readAndVerifySmsCode() async {
    final result = await SmartAuth.instance.getSmsWithRetrieverApi();
    if (!mounted || !result.hasData) return;
    final code = result.requireData.code;
    if (code == null || !RegExp(r'^\d{6}$').hasMatch(code)) return;
    _otpCtrl.text = code;
    setState(() => _sentOtp = true);
    await _verify();
  }

  @override
  void dispose() {
    if (_supportsAutomaticSms) {
      unawaited(SmartAuth.instance.removeSmsRetrieverApiListener());
    }
    _phoneCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final phone = _normalizeIsraeliMobile(_phoneCtrl.text);
    if (!_isValidIsraeliMobile(phone)) {
      setState(() => _error = 'נא להזין מספר טלפון תקין');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    if (!widget.requireVerification) {
      try {
        final res = await http
            .post(
              Uri.parse('$kApi/link-phone'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${widget.token}',
              },
              body: jsonEncode({'phone': phone}),
            )
            .timeout(const Duration(seconds: 20));
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        if (!mounted) return;
        if (res.statusCode == 200) {
          final token = data['token'] as String? ?? widget.token;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('token', token);
          if (!mounted) return;
          Navigator.pushReplacement(context,
              MaterialPageRoute(builder: (_) => MainShell(token: token)));
        } else {
          setState(() {
            _error = data['error'] as String? ?? 'שמירת המספר נכשלה';
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted)
          setState(() {
            _error = 'שגיאת חיבור';
            _loading = false;
          });
      }
      return;
    }
    try {
      final appSignature = await _startAutomaticSmsReading();
      final res = await http
          .post(
            Uri.parse('$kApi/send-otp'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${widget.token}',
            },
            body: jsonEncode({
              'phone': phone,
              if (appSignature != null) 'appSignature': appSignature,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        setState(() {
          _sentOtp = true;
          _loading = false;
        });
      } else {
        final d = jsonDecode(res.body);
        setState(() {
          _error = d['error'] ?? 'שגיאה';
          _loading = false;
        });
      }
    } catch (_) {
      setState(() {
        _error = 'שגיאת חיבור';
        _loading = false;
      });
    }
  }

  Future<void> _verify() async {
    final phone = _normalizeIsraeliMobile(_phoneCtrl.text);
    final code = _otpCtrl.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'נא להזין קוד בן 6 ספרות');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await http
          .post(
            Uri.parse('$kApi/link-phone'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${widget.token}'
            },
            body: jsonEncode({'phone': phone, 'code': code}),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final token = data['token'] as String? ?? widget.token;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', token);
        if (!mounted) return;
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => MainShell(token: token)));
      } else {
        final d = jsonDecode(res.body);
        setState(() {
          _error = d['error'] ?? 'שגיאה';
          _loading = false;
        });
      }
    } catch (_) {
      setState(() {
        _error = 'שגיאת חיבור';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kIsWeb ? const Color(0xFFF2F7FB) : kBg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              decoration: BoxDecoration(
                color: kBg,
                borderRadius: BorderRadius.circular(24),
                boxShadow: kIsWeb
                    ? const [
                        BoxShadow(
                            color: Color(0x1A0D4F82),
                            blurRadius: 28,
                            offset: Offset(0, 10))
                      ]
                    : null,
              ),
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 48),
                      Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                            color: kPrimary,
                            borderRadius: BorderRadius.circular(20)),
                        child: const Icon(Icons.phone_android,
                            size: 44, color: Colors.white),
                      ),
                      const SizedBox(height: 20),
                      Text(
                          widget.requireVerification
                              ? 'הוסף ואמת מספר טלפון'
                              : 'הוסף מספר טלפון',
                          style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: kPrimary)),
                      const SizedBox(height: 8),
                      const Text(
                          'אפליקציית בתשובה משתמשת במספר הטלפון\nכדי לחבר אותך עם אנשי הקשר שלך',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 14, color: kSubtext, height: 1.5)),
                      const SizedBox(height: 36),
                      if (!_sentOtp) ...[
                        TextField(
                          controller: _phoneCtrl,
                          keyboardType: TextInputType.phone,
                          textDirection: TextDirection.ltr,
                          decoration: const InputDecoration(
                              labelText: 'מספר טלפון',
                              hintText: '05X-XXX-XXXX',
                              prefixIcon: Icon(Icons.phone_android)),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _loading ? null : _sendOtp,
                            child: _loading
                                ? const SizedBox(
                                    height: 22,
                                    width: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : Text(
                                    widget.requireVerification
                                        ? 'שלח קוד אימות'
                                        : 'שמור והיכנס',
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ] else ...[
                        const _SmsCodeWaitingAnimation(),
                        Text('נשלח קוד SMS ל-${_phoneCtrl.text}',
                            style:
                                const TextStyle(color: kSubtext, fontSize: 13)),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _otpCtrl,
                          autofillHints: const [AutofillHints.oneTimeCode],
                          keyboardType: TextInputType.number,
                          textDirection: TextDirection.ltr,
                          maxLength: 6,
                          decoration: const InputDecoration(
                              labelText: 'קוד אימות',
                              hintText: '123456',
                              prefixIcon: Icon(Icons.sms_outlined)),
                        ),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _loading ? null : _verify,
                            child: _loading
                                ? const SizedBox(
                                    height: 22,
                                    width: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : const Text('אמת וכנס',
                                    style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold)),
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            _sentOtp = false;
                            _otpCtrl.clear();
                          }),
                          child: const Text('חזור לשינוי מספר',
                              style: TextStyle(color: kSubtext, fontSize: 13)),
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(8)),
                          child: Text(_error!,
                              style: const TextStyle(
                                  color: Colors.red, fontSize: 13)),
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: () async {
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.setString('token', widget.token);
                          if (!mounted) return;
                          Navigator.of(context).pushAndRemoveUntil(
                            MaterialPageRoute(
                                builder: (_) => MainShell(token: widget.token)),
                            (route) => false,
                          );
                        },
                        child: const Text('דלג על שלב זה',
                            style: TextStyle(color: kSubtext, fontSize: 13)),
                      ),
                    ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Avatar helpers ────────────────────────────────────────────────

const kAvatarCollections = {
  'פרחים': [
    '🌸',
    '🌺',
    '🌻',
    '🌹',
    '🌼',
    '🌷',
    '💐',
    '🪷',
    '🏵️',
    '🪻',
    '🌱',
    '🌿'
  ],
  'חיות': [
    '🦋',
    '🐝',
    '🦚',
    '🦜',
    '🐬',
    '🦁',
    '🐘',
    '🦒',
    '🐧',
    '🦅',
    '🐠',
    '🦌',
    '🦉',
    '🐢',
    '🐦',
    '🐈'
  ],
  'עצים': [
    '🌲',
    '🌳',
    '🌴',
    '🌵',
    '🎋',
    '🍀',
    '🌿',
    '🍁',
    '🍃',
    '🌾',
    '🎄',
    '🪨',
    '⛰️',
    '🏔️',
    '🪺',
    '🌏'
  ],
};

// Returns true if stored value is an emoji avatar
bool _isEmojiAvatar(String? url) => url != null && url.startsWith('emoji:');
String _emojiFromAvatar(String url) => url.substring(6);

class UserAvatar extends StatelessWidget {
  final String? picUrl;
  final String name;
  final double radius;
  const UserAvatar(
      {super.key, this.picUrl, required this.name, this.radius = 22});

  void _showExpandedImage(BuildContext context) {
    if (picUrl == null || _isEmojiAvatar(picUrl)) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: Stack(
          alignment: Alignment.topRight,
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(dialogContext),
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(
                    _absoluteMediaUrl(picUrl!),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox(
                      width: 280,
                      height: 280,
                      child: Center(
                        child: Icon(Icons.broken_image_outlined,
                            color: Colors.white, size: 56),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'סגור',
              onPressed: () => Navigator.pop(dialogContext),
              icon: const Icon(Icons.close, color: Colors.white, size: 30),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isEmojiAvatar(picUrl)) {
      final emoji = _emojiFromAvatar(picUrl!);
      return CircleAvatar(
        radius: radius,
        backgroundColor: kBorder,
        child: Text(emoji, style: TextStyle(fontSize: radius * 0.9)),
      );
    }
    return GestureDetector(
      onDoubleTap: picUrl != null ? () => _showExpandedImage(context) : null,
      child: CircleAvatar(
        radius: radius,
        backgroundColor: kPrimary,
        backgroundImage:
            picUrl != null ? NetworkImage(_absoluteMediaUrl(picUrl!)) : null,
        child: picUrl == null
            ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: radius * 0.9,
                    fontWeight: FontWeight.bold))
            : null,
      ),
    );
  }
}

class AvatarPickerSheet extends StatefulWidget {
  const AvatarPickerSheet({super.key});
  @override
  State<AvatarPickerSheet> createState() => _AvatarPickerSheetState();
}

class _AvatarPickerSheetState extends State<AvatarPickerSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: kAvatarCollections.length, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categories = kAvatarCollections.keys.toList();
    return Container(
      height: MediaQuery.of(context).size.height * 0.55,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: kBorder, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          const Text('בחר אווטאר',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.bold, color: kTextDark)),
          const SizedBox(height: 8),
          TabBar(
            controller: _tab,
            labelColor: kPrimary,
            unselectedLabelColor: kSubtext,
            indicatorColor: kPrimary,
            tabs: categories.map((c) => Tab(text: c)).toList(),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: categories.map((cat) {
                final emojis = kAvatarCollections[cat]!;
                return GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12),
                  itemCount: emojis.length,
                  itemBuilder: (ctx, i) {
                    return GestureDetector(
                      onTap: () => Navigator.pop(context, 'emoji:${emojis[i]}'),
                      child: Container(
                        decoration: BoxDecoration(
                          color: kFilterBg,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: kBorder, width: 1.5),
                        ),
                        child: Center(
                          child: Text(emojis[i],
                              style: const TextStyle(fontSize: 36)),
                        ),
                      ),
                    );
                  },
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Full-screen image preview ─────────────────────────────────────
class ImagePreviewScreen extends StatefulWidget {
  final String url;
  final String? filename;
  final List<String>? urls;
  final List<String?>? filenames;
  final List<String?>? dates;
  final List<Map<String, dynamic>>? messages;
  final void Function(Map<String, dynamic>)? onMessageOptions;
  final int initialIndex;
  const ImagePreviewScreen({
    super.key,
    required this.url,
    this.filename,
    this.urls,
    this.filenames,
    this.dates,
    this.messages,
    this.onMessageOptions,
    this.initialIndex = 0,
  });
  @override
  State<ImagePreviewScreen> createState() => _ImagePreviewScreenState();
}

class _ImagePreviewScreenState extends State<ImagePreviewScreen> {
  final _transform = TransformationController();
  late final List<String> _urls;
  late final List<String?> _filenames;
  late final List<String?> _dates;
  late final PageController _pageController;
  late int _currentIndex;
  bool _showBars = true;

  @override
  void initState() {
    super.initState();
    _urls =
        widget.urls?.where((url) => url.isNotEmpty).toList() ?? [widget.url];
    if (_urls.isEmpty) _urls.add(widget.url);
    _filenames = List<String?>.generate(
      _urls.length,
      (index) => index < (widget.filenames?.length ?? 0)
          ? widget.filenames![index]
          : index == 0
              ? widget.filename
              : null,
    );
    _dates = List<String?>.generate(
      _urls.length,
      (index) =>
          index < (widget.dates?.length ?? 0) ? widget.dates![index] : null,
    );
    _currentIndex = widget.initialIndex.clamp(0, _urls.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _transform.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _goToPage(int index) {
    if (index < 0 || index >= _urls.length) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showBars = !_showBars),
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: _urls.length,
              onPageChanged: (index) {
                _transform.value = Matrix4.identity();
                setState(() => _currentIndex = index);
              },
              itemBuilder: (_, index) => InteractiveViewer(
                transformationController:
                    index == _currentIndex ? _transform : null,
                minScale: 0.5,
                maxScale: 5.0,
                child: Center(
                  child: _PersistentMediaImage(
                    url: _urls[index],
                    fit: BoxFit.contain,
                    loadingBuilder: (_) => const Center(
                        child: CircularProgressIndicator(color: Colors.white)),
                    errorBuilder: (_) => const Icon(Icons.broken_image,
                        color: Colors.white54, size: 64),
                  ),
                ),
              ),
            ),
            if (_showBars && _urls.length > 1) ...[
              Positioned(
                left: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton.filled(
                    tooltip: 'התמונה הבאה',
                    onPressed: _currentIndex < _urls.length - 1
                        ? () => _goToPage(_currentIndex + 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                ),
              ),
              Positioned(
                right: 12,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton.filled(
                    tooltip: 'התמונה הקודמת',
                    onPressed: _currentIndex > 0
                        ? () => _goToPage(_currentIndex - 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ),
              ),
              Positioned(
                bottom: 28,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      '${_currentIndex + 1} / ${_urls.length}',
                      textDirection: TextDirection.ltr,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
            if (_showBars) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black87, Colors.transparent]),
                  ),
                  child: SafeArea(
                    child: Row(children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if ((_filenames[_currentIndex] ?? '').isNotEmpty)
                              Text(
                                _filenames[_currentIndex]!,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14),
                                overflow: TextOverflow.ellipsis,
                              ),
                            if ((_dates[_currentIndex] ?? '').isNotEmpty)
                              Text(
                                _dates[_currentIndex]!,
                                textDirection: TextDirection.ltr,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.download, color: Colors.white),
                        onPressed: () => _downloadChatFile(
                          context,
                          _urls[_currentIndex],
                          _filenames[_currentIndex],
                        ),
                        tooltip: 'הורדת תמונה',
                      ),
                      if (widget.onMessageOptions != null &&
                          _currentIndex < (widget.messages?.length ?? 0))
                        IconButton(
                          icon:
                              const Icon(Icons.more_vert, color: Colors.white),
                          onPressed: () => widget.onMessageOptions!(
                              widget.messages![_currentIndex]),
                          tooltip: 'אפשרויות תמונה',
                        ),
                      IconButton(
                        icon:
                            const Icon(Icons.zoom_out_map, color: Colors.white),
                        onPressed: () => _transform.value = Matrix4.identity(),
                        tooltip: 'אפס זום',
                      ),
                    ]),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _formatBirthDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

class _BirthDateField extends StatelessWidget {
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;

  const _BirthDateField({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () async {
          final now = DateTime.now();
          final latestEligibleDate =
              DateTime(now.year - 13, now.month, now.day);
          final selected = await showDatePicker(
            context: context,
            initialDate: value ?? DateTime(now.year - 18, now.month, now.day),
            firstDate: DateTime(now.year - 120),
            lastDate: latestEligibleDate,
            helpText: 'בחירת תאריך לידה',
          );
          if (selected != null) onChanged(selected);
        },
        child: InputDecorator(
          decoration: const InputDecoration(
            labelText: 'תאריך לידה',
            helperText: 'נדרש גיל 13+. בגיל 13–17 מופעלות הגנות נוער.',
            prefixIcon: Icon(Icons.cake_outlined),
          ),
          child: Text(
            value == null
                ? 'יש לבחור תאריך'
                : '${value!.day.toString().padLeft(2, '0')}/${value!.month.toString().padLeft(2, '0')}/${value!.year}',
            textDirection: TextDirection.ltr,
          ),
        ),
      );
}

class _BetaNotice extends StatelessWidget {
  const _BetaNotice();

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF5FD),
          border: Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'BETSHUVA מופעלת על ידי יניב אליהו בגרסת בטא פתוחה וללא תשלום. '
          'השירות נמצא בבדיקה ועלולות להתרחש תקלות, הפסקות זמניות, שינויים '
          'או אובדן מידע. אין לשמור בשירות מידע שהעותק היחיד שלו נמצא '
          'באפליקציה. השימוש כפוף לתנאי השימוש ולמדיניות הפרטיות. '
          'לפניות: support@betshuva.com',
          textDirection: TextDirection.rtl,
          style: TextStyle(fontSize: 12, height: 1.45, color: kTextDark),
        ),
      );
}

class _TabBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabBtn(
      {required this.label, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: active ? kPrimary : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: active ? Colors.white : kSubtext,
                fontWeight: active ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ),
      );
}

// ── Verify Screen (SMS + Email after registration) ────────────────
class VerifyScreen extends StatefulWidget {
  final String phone;
  final String email;
  final String method;
  const VerifyScreen(
      {super.key,
      required this.phone,
      required this.email,
      this.method = 'phone'});
  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  final _codeCtrl = TextEditingController();
  bool _loading = false;

  bool _waitingEmail = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _waitingEmail = widget.method == 'email';
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _verifyPhone() async {
    final code = _codeCtrl.text.trim();
    if (code.length < 6) {
      setState(() => _error = 'נא להזין קוד בן 6 ספרות');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await http
          .post(
            Uri.parse('$kApi/verify-phone'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'phone': widget.phone, 'code': code}),
          )
          .timeout(const Duration(seconds: 30));
      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        setState(() {
          _error = data['error'] ?? 'קוד שגוי';
          _loading = false;
        });
        return;
      }
      if (data['token'] != null) {
        if (!mounted) return;
        Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (_) => AuthScreen(initialEmail: widget.email)));
      } else {
        setState(() {
          _waitingEmail = true;
          _loading = false;
        });
      }
    } catch (_) {
      setState(() {
        _error = 'שגיאת חיבור. נסה שוב.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('אימות חשבון')),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: _waitingEmail
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.mark_email_read_outlined,
                      size: 80, color: kAccent),
                  const SizedBox(height: 24),
                  Text(
                      widget.method == 'email'
                          ? 'אימות באימייל'
                          : 'הטלפון אומת ✅',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: kPrimary),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(
                    'נשלח קישור אימות ל-${widget.email}\nלחץ על הקישור במייל להשלמת ההרשמה.',
                    style: const TextStyle(
                        color: kSubtext, fontSize: 14, height: 1.6),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const AuthScreen())),
                      child: const Text('חזור לכניסה'),
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: kAccent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kAccent.withOpacity(0.3)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.info_outline, color: kPrimary, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'שלחנו קוד SMS ל-${widget.phone}',
                          style: const TextStyle(
                              fontSize: 13, color: kPrimary, height: 1.4),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 28),
                  const _SmsCodeWaitingAnimation(),
                  const Text('אימות טלפון',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: kPrimary)),
                  const SizedBox(height: 4),
                  const Text('הזן את קוד ה-SMS שקיבלת',
                      style: TextStyle(color: kSubtext, fontSize: 13)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _codeCtrl,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                        fontSize: 32,
                        letterSpacing: 12,
                        fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                        labelText: 'קוד אימות', counterText: ''),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8)),
                      child: Text(_error!,
                          style:
                              const TextStyle(color: Colors.red, fontSize: 13)),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _verifyPhone,
                      child: _loading
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('אמת טלפון',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ── Forgot Password Screen ────────────────────────────────────────
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailCtrl = TextEditingController();
  bool _loading = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'נא להזין כתובת אימייל תקינה');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await http.post(
        Uri.parse('$kApi/forgot-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );
      setState(() {
        _sent = true;
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _error = 'שגיאת חיבור. נסה שוב.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('שכחתי סיסמה'),
        leading: BackButton(
            color: Colors.white, onPressed: () => Navigator.pop(context)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: _sent
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.mark_email_read_outlined,
                      size: 72, color: kAccent),
                  const SizedBox(height: 20),
                  const Text('נשלח מייל לאיפוס הסיסמה',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: kPrimary),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(
                    'בדוק את תיבת הדואר שלך ב-${_emailCtrl.text.trim()} ולחץ על הקישור לאיפוס.',
                    style: const TextStyle(color: kSubtext, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('חזור לכניסה'),
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 20),
                  const Text(
                    'הזן את כתובת האימייל שלך ונשלח לך קישור לאיפוס הסיסמה.',
                    style: TextStyle(color: kSubtext, fontSize: 15),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    textDirection: TextDirection.ltr,
                    decoration: const InputDecoration(
                        labelText: 'כתובת אימייל',
                        prefixIcon: Icon(Icons.email_outlined)),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 13)),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _send,
                      child: _loading
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('שלח קישור לאיפוס',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ── Mandatory age completion for legacy beta accounts ────────────
class MainShell extends StatefulWidget {
  final String token;
  const MainShell({super.key, required this.token});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  late Future<bool> _birthDateReady;

  @override
  void initState() {
    super.initState();
    _birthDateReady = _checkBirthDate();
  }

  Future<bool> _checkBirthDate() async {
    try {
      final response = await http.get(
        Uri.parse('$kApi/registration-status'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return false;
      final status = jsonDecode(response.body) as Map<String, dynamic>;
      return status['birthDateMissing'] != true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _birthDateReady,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.data != true) {
            return _CompleteBirthDateScreen(
              token: widget.token,
              onCompleted: () => setState(() {
                _birthDateReady = Future.value(true);
              }),
            );
          }
          return _MainShellContent(token: widget.token);
        },
      );
}

class _CompleteBirthDateScreen extends StatefulWidget {
  final String token;
  final VoidCallback onCompleted;

  const _CompleteBirthDateScreen({
    required this.token,
    required this.onCompleted,
  });

  @override
  State<_CompleteBirthDateScreen> createState() =>
      _CompleteBirthDateScreenState();
}

class _CompleteBirthDateScreenState extends State<_CompleteBirthDateScreen> {
  DateTime? _birthDate;
  bool _loading = false;
  String? _error;

  Future<void> _save() async {
    if (_birthDate == null) {
      setState(() => _error = 'יש לבחור תאריך לידה');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await http
          .put(
            Uri.parse('$kApi/profile/birth-date'),
            headers: {
              'Authorization': 'Bearer ${widget.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'birthDate': _formatBirthDate(_birthDate!)}),
          )
          .timeout(const Duration(seconds: 20));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (!mounted) return;
      if (response.statusCode == 200) {
        widget.onCompleted();
      } else {
        setState(() {
          _error = data['error'] as String? ?? 'שמירת תאריך הלידה נכשלה';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'שגיאת חיבור. נסה שוב.';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: kBg,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(children: [
                  const Icon(Icons.shield_outlined, size: 72, color: kPrimary),
                  const SizedBox(height: 20),
                  const Text('השלמת הגנת גיל',
                      style:
                          TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  const Text(
                    'כדי להמשיך יש להזין תאריך לידה אמיתי. לא ניתן לשנות אותו באפליקציה לאחר השמירה. בגיל 13–17 יופעל אוטומטית חשבון נוער מוגן.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  _BirthDateField(
                    value: _birthDate,
                    onChanged: (value) => setState(() => _birthDate = value),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _save,
                      child: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('שמירה והמשך'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('לסיוע: support@betshuva.com',
                      style: TextStyle(color: kSubtext)),
                ]),
              ),
            ),
          ),
        ),
      );
}

// ── Main Shell (Bottom Nav) ───────────────────────────────────────
class _MainShellContent extends StatefulWidget {
  final String token;
  const _MainShellContent({required this.token});
  @override
  State<_MainShellContent> createState() => _MainShellContentState();
}

class _MainShellContentState extends State<_MainShellContent> {
  int _idx = 0;
  Map<String, dynamic>? _desktopRecipient;
  Map<String, dynamic>? _desktopGroup;
  bool _openGroupMembersOnSelect = false;
  IO.Socket? _socket;
  VoiceCallCoordinator? _voiceCalls;
  Map<String, dynamic>? _me;
  List<Map<String, dynamic>> _users = [];
  String? _adminPerm;
  late final _AppLifecycleObserver _lifecycleObserver;
  Timer? _usersRefreshTimer;
  Map<String, int> _unreadCounts = {}; // userId → count of unread incoming msgs
  Map<String, int> _groupUnreadCounts = {}; // groupId → unread count
  final Map<String, String> _groupTypingNames = {};
  final Map<String, Timer> _groupTypingTimers = {};
  final Set<String> _typingUserIds = {};
  final Map<String, Timer> _userTypingTimers = {};
  final List<Map<String, dynamic>> _messageRequests = [];
  bool _showingMessageRequest = false;

  List<Map<String, dynamic>> _withoutScanBot(List<Map<String, dynamic>> users) {
    final sorted =
        users.where((user) => user['id']?.toString() != kScanBotId).toList();
    sorted.sort((a, b) {
      final aTime = DateTime.tryParse(a['last_message_at']?.toString() ?? '');
      final bTime = DateTime.tryParse(b['last_message_at']?.toString() ?? '');
      if (aTime != null || bTime != null) {
        return (bTime ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(aTime ?? DateTime.fromMillisecondsSinceEpoch(0));
      }
      return (a['name']?.toString() ?? '')
          .compareTo(b['name']?.toString() ?? '');
    });
    return sorted;
  }

  @override
  void initState() {
    super.initState();
    _lifecycleObserver = _AppLifecycleObserver(onResume: _handleAppResume);
    _decodeMe();
    _loadMyProfile();
    _connectSocket();
    _loadUsers();
    _loadUnreadCounts();
    _loadGroupUnreadCounts();
    _registerFcmToken();
    _loadAdminPerm();
    _loadMessageRequests();
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    // Reconcile badges periodically in case a browser tab missed a socket event.
    _usersRefreshTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _refreshConversationState(),
    );
    _initNotificationOpenHandlers();
    _initAndroidSharing();
  }

  Future<void> _initAndroidSharing() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'sharedContent' && call.arguments is Map) {
        _handleSharedContent(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
    try {
      final initial = await _shareChannel
          .invokeMapMethod<String, dynamic>('getInitialShare');
      if (initial != null) _handleSharedContent(initial);
    } catch (_) {}
  }

  void _handleSharedContent(Map<String, dynamic> shared) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final text = shared['text'] as String?;
      final path = shared['path'] as String?;
      if ((text == null || text.trim().isEmpty) && path == null) return;
      _forwardChatMessage(context, widget.token, _socket, {
        if (text != null) 'text': text,
        if (path != null) 'localPath': path,
        if (path != null) 'fileName': shared['name'] ?? 'shared_image.jpg',
        if (path != null) 'fileType': 'image',
      });
    });
  }

  // Firebase is optional on web. Accessing FirebaseMessaging.instance when
  // Firebase initialization failed throws synchronously during initState and
  // leaves Flutter rendering a blank screen, so keep all notification setup
  // behind a guarded async boundary.
  Future<void> _initNotificationOpenHandlers() async {
    try {
      if (Firebase.apps.isEmpty) return;
      final initialMessage =
          await FirebaseMessaging.instance.getInitialMessage();
      _handleNotificationOpen(initialMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationOpen);
    } catch (error) {
      debugPrint('Push notification initialization skipped: $error');
    }
  }

  @override
  void dispose() {
    _shareChannel.setMethodCallHandler(null);
    _usersRefreshTimer?.cancel();
    for (final timer in _groupTypingTimers.values) {
      timer.cancel();
    }
    for (final timer in _userTypingTimers.values) {
      timer.cancel();
    }
    WidgetsBinding.instance.removeObserver(_lifecycleObserver);
    _voiceCalls?.dispose();
    _socket?.disconnect();
    super.dispose();
  }

  Future<void> _loadAdminPerm() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/admin/db'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body);
        setState(() => _adminPerm = data['permission'] as String?);
      }
    } catch (_) {}
  }

  Future<void> _loadMessageRequests() async {
    try {
      final response = await http.get(Uri.parse('$kApi/message-requests'),
          headers: {'Authorization': 'Bearer ${widget.token}'});
      if (response.statusCode != 200 || !mounted) return;
      _messageRequests
        ..clear()
        ..addAll(
            (jsonDecode(response.body) as List).cast<Map<String, dynamic>>());
      _showNextMessageRequest();
    } catch (_) {}
  }

  Future<void> _showNextMessageRequest() async {
    if (!mounted || _showingMessageRequest || _messageRequests.isEmpty) return;
    _showingMessageRequest = true;
    final request = _messageRequests.first;
    final senderName =
        request['sender_name'] ?? request['senderName'] ?? 'משתמש';
    final preview = request['body'] ??
        request['text'] ??
        request['file_name'] ??
        request['fileName'] ??
        'קובץ';
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('בקשת הודעה'),
        content: Text(
            '$senderName רוצה לשלוח לך הודעה:\n“$preview”\n\nלהוסיף אותו כחבר?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('דחה')),
          ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('אשר והוסף כחבר')),
        ],
      ),
    );
    try {
      final id = request['id'];
      if (accepted == true) {
        await http.post(Uri.parse('$kApi/message-requests/$id/accept'),
            headers: {'Authorization': 'Bearer ${widget.token}'});
        await _refreshConversationState();
      } else {
        await http.delete(Uri.parse('$kApi/message-requests/$id'),
            headers: {'Authorization': 'Bearer ${widget.token}'});
      }
    } catch (_) {}
    if (accepted == true) {
      final senderId = request['sender_id'] ?? request['senderId'];
      _messageRequests.removeWhere(
          (item) => (item['sender_id'] ?? item['senderId']) == senderId);
    } else {
      _messageRequests.removeAt(0);
    }
    _showingMessageRequest = false;
    _showNextMessageRequest();
  }

  Future<void> _registerFcmToken() async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      final token =
          kIsWeb ? await getBetshuvaWebPushToken() : await messaging.getToken();
      if (token == null) return;
      await http.post(
        Uri.parse('$kApi/fcm-token'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'token': token,
          'deviceId': kIsWeb ? 'web:$token' : 'android:$token',
        }),
      );
      // Refresh token when it changes
      messaging.onTokenRefresh.listen((newToken) {
        http.post(
          Uri.parse('$kApi/fcm-token'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'token': newToken,
            'deviceId': kIsWeb ? 'web:$newToken' : 'android:$newToken',
          }),
        );
      });
    } catch (_) {}
  }

  void _decodeMe() {
    final parts = widget.token.split('.');
    if (parts.length == 3) {
      final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      setState(() => _me = payload as Map<String, dynamic>);
    }
  }

  Future<void> _loadMyProfile() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/profile'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        final profile = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _me = {...?_me, ...profile});
      }
    } catch (_) {}
  }

  Future<void> _loadUnreadCounts() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/messages/unread'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _unreadCounts = data.map((k, v) => MapEntry(
            k, v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0)));
      }
    } catch (_) {}
  }

  Future<void> _loadGroupUnreadCounts() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/groups/unread'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _groupUnreadCounts = data.map((k, v) => MapEntry(
            k, v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0)));
      }
    } catch (_) {}
  }

  Future<void> _refreshConversationState() async {
    await Future.wait([
      _loadUsers(),
      _loadUnreadCounts(),
      _loadGroupUnreadCounts(),
    ]);
  }

  void _handleAppResume() {
    final socket = _socket;
    if (socket != null && !socket.connected) socket.connect();
    _refreshConversationState();
  }

  void _openGroup(Map<String, dynamic> group, bool openMembers) {
    final groupId = group['id'] as String;
    setState(() {
      _desktopRecipient = null;
      _desktopGroup = group;
      _openGroupMembersOnSelect = openMembers;
      _groupUnreadCounts.remove(groupId);
    });
  }

  Future<void> _openMarketplaceConversation(
      Map<String, dynamic> recipient) async {
    await _loadUsers();
    if (!mounted) return;
    final recipientId = recipient['id']?.toString();
    final refreshed = _users.where(
      (user) => user['id']?.toString() == recipientId,
    );
    setState(() {
      _idx = 0;
      _desktopRecipient = refreshed.isNotEmpty
          ? refreshed.first
          : Map<String, dynamic>.from(recipient);
      _desktopGroup = null;
      _openGroupMembersOnSelect = false;
    });
    if (MediaQuery.sizeOf(context).width < 900) {
      final selectedRecipient = _desktopRecipient!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatScreen(
            token: widget.token,
            me: _me,
            recipient: selectedRecipient,
            socket: _socket,
            onVoiceCall: () => _voiceCalls?.startCall(
              selectedRecipient['id'] as String,
              selectedRecipient['name']?.toString() ?? 'משתמש',
            ),
          ),
        ));
      });
    }
  }

  void _handleNotificationOpen(RemoteMessage? msg) {
    if (msg == null || !mounted) return;
    final fromUserId = msg.data['fromUserId'] as String?;
    final type = msg.data['type'] as String?;
    if (type == 'chat' && fromUserId != null) {
      final user = _users.firstWhere(
        (u) => u['id'] == fromUserId,
        orElse: () => {
          'id': fromUserId,
          'name': msg.notification?.title ?? 'משתמש',
        },
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _unreadCounts.remove(fromUserId));
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatScreen(
            token: widget.token,
            me: _me,
            recipient: user,
            socket: _socket,
            onVoiceCall: () => _voiceCalls?.startCall(
              user['id'] as String,
              user['name']?.toString() ?? 'משתמש',
            ),
          ),
        ));
      });
    }
  }

  Future<void> _loadUsers() async {
    // Load from cache first for instant offline display
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('cache_users');
      if (cached != null && _users.isEmpty) {
        setState(() => _users = _withoutScanBot(
            (jsonDecode(cached) as List).cast<Map<String, dynamic>>()));
      }
    } catch (_) {}
    // Then fetch from server and update cache
    try {
      final res = await http.get(
        Uri.parse('$kApi/users'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        if (mounted) {
          setState(() =>
              _users = _withoutScanBot(data.cast<Map<String, dynamic>>()));
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('cache_users', res.body);
      } else if (res.statusCode == 403) {
        _requirePhoneSetup();
      } else if (res.statusCode == 401) {
        // משתמש לא קיים ב-DB — ghost session → יציאה אוטומטית
        _forceLogout();
      }
    } catch (_) {}
  }

  void _connectSocket() {
    _socket = IO.io(
      kSocketOrigin,
      IO.OptionBuilder().setPath(kSocketPath).setTransports(
          ['websocket']).setAuth({'token': widget.token}).build(),
    );
    _voiceCalls = VoiceCallCoordinator(
      socket: _socket!,
      contextProvider: () => mounted ? context : null,
      token: widget.token,
      apiBase: kApi,
    );
    // רענן רשימת משתמשים כשהסוקט מתחבר מחדש
    _socket!.on('connect', (_) {
      _loadUsers();
      _loadUnreadCounts();
      _loadGroupUnreadCounts();
    });

    // טיפול בשגיאת חיבור — משתמש לא קיים ב-DB → יציאה אוטומטית
    _socket!.on('connect_error', (err) {
      final msg = err?.toString() ?? '';
      if (msg.contains('verification_required') ||
          msg.contains('phone_required')) {
        _requirePhoneSetup(
            requireVerification: msg.contains('verification_required'));
      } else if (msg.contains('registration_incomplete') ||
          msg.contains('user_not_found')) {
        _forceLogout(showRegistration: true);
      } else if (msg.contains('unauthorized')) {
        _forceLogout();
      }
    });

    // אדמין מחק את המשתמש בזמן שהוא מחובר
    _socket!.on('force_logout', (data) {
      final reason = data is Map ? data['reason']?.toString() ?? '' : '';
      _forceLogout(showRegistration: reason.contains('נמחק'));
    });
    _socket!.on('message:request', (data) {
      if (!mounted || data is! Map) return;
      final request = Map<String, dynamic>.from(data);
      if (!_messageRequests.any((item) => item['id'] == request['id'])) {
        _messageRequests.add(request);
      }
      _showNextMessageRequest();
    });

    // הודעה חדשה בזמן שהאפליקציה פתוחה — עדכן badge
    _socket!.on('chat:message', (data) {
      if (!mounted) return;
      final fromId = data['fromUserId'] as String?;
      final myId = _me?['id'] as String?;
      if (fromId == null || fromId == myId) return;
      setState(() => _unreadCounts[fromId] = (_unreadCounts[fromId] ?? 0) + 1);
      _loadUsers();
    });
    _socket!.on('chat:typing', (data) {
      if (!mounted) return;
      final userId = data['fromUserId'] as String?;
      if (userId == null || userId == _me?['id']) return;
      _userTypingTimers[userId]?.cancel();
      setState(() => _typingUserIds.add(userId));
      _userTypingTimers[userId] = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _typingUserIds.remove(userId));
      });
    });
    _socket!.on('group:message', (data) {
      if (!mounted) return;
      final groupId = data['groupId'] as String?;
      final fromId = data['fromUserId'] as String?;
      if (groupId == null || fromId == _me?['id']) return;
      if (_desktopGroup?['id'] == groupId) return;
      setState(() =>
          _groupUnreadCounts[groupId] = (_groupUnreadCounts[groupId] ?? 0) + 1);
    });
    _socket!.on('group:typing', (data) {
      if (!mounted) return;
      final groupId = data['groupId'] as String?;
      final userId = data['fromUserId'] as String?;
      final name = data['fromName'] as String?;
      if (groupId == null || name == null || userId == _me?['id']) return;
      _groupTypingTimers[groupId]?.cancel();
      setState(() => _groupTypingNames[groupId] = name);
      _groupTypingTimers[groupId] = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _groupTypingNames.remove(groupId));
      });
    });
  }

  Future<void> _logout() async {
    await _leaveAccount(showRegistration: false);
  }

  Future<void> _logoutAfterAccountDeletion() async {
    await _leaveAccount(showRegistration: true);
  }

  Future<void> _leaveAccount({required bool showRegistration}) async {
    _socket?.disconnect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
          builder: (_) => AuthScreen(initialRegistration: showRegistration)),
      (_) => false,
    );
  }

  void _forceLogout({bool showRegistration = false}) {
    _socket?.disconnect();
    SharedPreferences.getInstance().then((prefs) => prefs.remove('token'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(showRegistration
            ? 'החשבון נמחק — ניתן להירשם מחדש'
            : 'הפגישה פגה — נא להתחבר מחדש'),
        backgroundColor: showRegistration ? Colors.blue : Colors.orange,
        duration: const Duration(seconds: 3),
      ),
    );
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
          builder: (_) => AuthScreen(initialRegistration: showRegistration)),
      (route) => false,
    );
  }

  void _requirePhoneSetup({bool requireVerification = false}) {
    _socket?.disconnect();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => GooglePhoneSetupScreen(
          token: widget.token,
          requireVerification: requireVerification,
        ),
      ),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalUnreadMessages = _unreadCounts.values
        .where((count) => count > 0)
        .fold<int>(0, (total, count) => total + count);
    final totalUnreadGroups = _groupUnreadCounts.values
        .where((count) => count > 0)
        .fold<int>(0, (total, count) => total + count);

    Widget navigationIcon(IconData icon, int unreadCount) => Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(icon),
            if (unreadCount > 0)
              Positioned.directional(
                textDirection: Directionality.of(context),
                top: -9,
                end: -13,
                child: Semantics(
                  label: '$unreadCount הודעות שלא נקראו',
                  child: Container(
                    constraints:
                        const BoxConstraints(minWidth: 20, minHeight: 20),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: kPrimaryMid,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Text(
                      unreadCount > 99 ? '99+' : '$unreadCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        height: 1,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );

    final conversations = ConversationsScreen(
      users: _users,
      token: widget.token,
      me: _me,
      socket: _socket,
      unreadCounts: _unreadCounts,
      groupUnreadCounts: _groupUnreadCounts,
      groupTypingNames: _groupTypingNames,
      typingUserIds: _typingUserIds,
      onLogout: _logout,
      onSettings: () => setState(() => _idx = 3),
      onContactsChanged: _loadUsers,
      onVoiceCall: (user) {
        _voiceCalls?.startCall(
          user['id'] as String,
          user['name']?.toString() ?? 'משתמש',
        );
      },
      selectedUserId: _desktopRecipient?['id'] as String?,
      onUserSelected: (user) {
        final userId = user['id'] as String;
        if (_unreadCounts.containsKey(userId)) {
          setState(() => _unreadCounts.remove(userId));
        }
        setState(() {
          _desktopRecipient = user;
          _desktopGroup = null;
          _openGroupMembersOnSelect = false;
        });
      },
      selectedGroupId: _desktopGroup?['id'] as String?,
      onGroupSelected: _openGroup,
      onChatOpened: (userId) {
        if (_unreadCounts.containsKey(userId)) {
          setState(() => _unreadCounts.remove(userId));
        }
      },
    );
    final groups = GroupsScreen(
      token: widget.token,
      me: _me,
      socket: _socket,
      groupTypingNames: _groupTypingNames,
      selectedGroupId: _desktopGroup?['id'] as String?,
      onGroupSelected: _openGroup,
    );
    final screens = [
      conversations,
      groups,
      ListingsScreen(
        token: widget.token,
        me: _me,
        socket: _socket,
        onConversationStarted: _openMarketplaceConversation,
      ),
      SettingsScreen(
          me: _me,
          token: widget.token,
          onBack: () => setState(() => _idx = 0),
          onLogout: _logout,
          onAccountDeleted: _logoutAfterAccountDeletion,
          onProfileChanged: _loadMyProfile,
          adminPerm: _adminPerm),
    ];

    final isDesktop = MediaQuery.sizeOf(context).width >= 900;
    final body = isDesktop && (_idx == 0 || _idx == 1)
        ? Row(
            children: [
              SizedBox(width: 410, child: _idx == 0 ? conversations : groups),
              const VerticalDivider(
                  width: 1, thickness: 1, color: Color(0xFFD9DEE1)),
              Expanded(
                child: _idx == 0
                    ? (_desktopGroup != null
                        ? GroupChatScreen(
                            key: ValueKey(
                                'chat-tab:${_desktopGroup!['id']}:$_openGroupMembersOnSelect'),
                            group: _desktopGroup!,
                            me: _me,
                            token: widget.token,
                            socket: _socket,
                            embedded: true,
                            openAddMembersOnStart: _openGroupMembersOnSelect,
                            onMembersChanged: (count) => setState(() {
                              _desktopGroup?['member_count'] = count;
                            }),
                            onClose: () => setState(() {
                              _desktopGroup = null;
                              _openGroupMembersOnSelect = false;
                            }),
                          )
                        : _desktopRecipient == null
                            ? const _DesktopChatWelcome()
                            : ChatScreen(
                                key: ValueKey(_desktopRecipient!['id']),
                                token: widget.token,
                                me: _me,
                                recipient: _desktopRecipient!,
                                socket: _socket,
                                onVoiceCall: () => _voiceCalls?.startCall(
                                  _desktopRecipient!['id'] as String,
                                  _desktopRecipient!['name']?.toString() ??
                                      'משתמש',
                                ),
                                embedded: true,
                                onClose: () =>
                                    setState(() => _desktopRecipient = null),
                              ))
                    : (_desktopGroup == null
                        ? const _DesktopGroupWelcome()
                        : GroupChatScreen(
                            key: ValueKey(
                                '${_desktopGroup!['id']}:$_openGroupMembersOnSelect'),
                            group: _desktopGroup!,
                            me: _me,
                            token: widget.token,
                            socket: _socket,
                            embedded: true,
                            openAddMembersOnStart: _openGroupMembersOnSelect,
                            onMembersChanged: (count) => setState(() {
                              _desktopGroup?['member_count'] = count;
                            }),
                            onClose: () => setState(() {
                              _desktopGroup = null;
                              _openGroupMembersOnSelect = false;
                            }),
                          )),
              ),
            ],
          )
        : screens[_idx];

    final navigationBar = BottomNavigationBar(
      currentIndex: _idx,
      onTap: (i) => setState(() => _idx = i),
      selectedItemColor: kPrimary,
      unselectedItemColor: kSubtext,
      backgroundColor: Colors.white,
      elevation: 8,
      type: BottomNavigationBarType.fixed,
      items: [
        BottomNavigationBarItem(
          icon: navigationIcon(Icons.chat_bubble_outline, totalUnreadMessages),
          activeIcon: navigationIcon(Icons.chat_bubble, totalUnreadMessages),
          label: 'שיחות',
        ),
        BottomNavigationBarItem(
          icon: navigationIcon(Icons.group_outlined, totalUnreadGroups),
          activeIcon: navigationIcon(Icons.group, totalUnreadGroups),
          label: 'קבוצות',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.storefront_outlined),
          activeIcon: Icon(Icons.storefront),
          label: 'מודעות',
        ),
      ],
    );

    return Scaffold(
      body: body,
      bottomNavigationBar: _idx == 3
          ? null
          : isDesktop
              ? Align(
                  alignment: Alignment.centerRight,
                  heightFactor: 1,
                  child: SizedBox(width: 410, child: navigationBar),
                )
              : navigationBar,
    );
  }
}

class _DesktopChatWelcome extends StatelessWidget {
  const _DesktopChatWelcome();

  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFFF0F2F5),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.chat_bubble_outline_rounded,
                  size: 84, color: Color(0xFF9EADBA)),
              SizedBox(height: 22),
              Text('בתשובה Web',
                  style: TextStyle(fontSize: 30, color: Color(0xFF41525D))),
              SizedBox(height: 10),
              Text('בחר שיחה מהרשימה כדי להתחיל',
                  style: TextStyle(fontSize: 14, color: Color(0xFF667781))),
            ],
          ),
        ),
      );
}

class _DesktopGroupWelcome extends StatelessWidget {
  const _DesktopGroupWelcome();

  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFFF0F2F5),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.groups_outlined, size: 84, color: Color(0xFF9EADBA)),
              SizedBox(height: 22),
              Text('קבוצות בתשובה',
                  style: TextStyle(fontSize: 30, color: Color(0xFF41525D))),
              SizedBox(height: 10),
              Text('בחר קבוצה מהרשימה כדי לפתוח אותה',
                  style: TextStyle(fontSize: 14, color: Color(0xFF667781))),
            ],
          ),
        ),
      );
}

// ── Listings Screen ───────────────────────────────────────────────
class _BrandAppBarTitle extends StatelessWidget {
  final Map<String, dynamic>? me;

  const _BrandAppBarTitle({required this.me});

  @override
  Widget build(BuildContext context) {
    final name = me?['name'] as String? ?? '';
    final picUrl = me?['profile_pic_url'] as String?;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'בסיעתא דשמיא  •  ${fullHebrewDate(DateTime.now())}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            if (picUrl != null)
              UserAvatar(radius: 17, picUrl: picUrl, name: name)
            else
              _magenDavid(size: 34),
            const SizedBox(width: 9),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('בתשובה',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            height: 1.05,
                            fontWeight: FontWeight.w700)),
                    SizedBox(width: 7),
                    Text('תוכן יהודי נקי',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            height: 1.05,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
                if (name.isNotEmpty)
                  Text(name,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 11, height: 1.1)),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

const _kCategories = [
  'הכל',
  'רכב',
  'רהיטים',
  'אלקטרוניקה',
  'בגדים',
  'ספרים',
  'כלי בית',
  'צעצועים',
  'אחר'
];

const _kIsraeliLocations = [
  'כל הארץ',
  'אזור המרכז',
  'אזור ירושלים',
  'אזור הצפון',
  'אזור הדרום',
  'אזור השרון',
  'ירושלים',
  'תל אביב-יפו',
  'חיפה',
  'ראשון לציון',
  'פתח תקווה',
  'אשדוד',
  'נתניה',
  'באר שבע',
  'בני ברק',
  'חולון',
  'רמת גן',
  'אשקלון',
  'רחובות',
  'בית שמש',
  'כפר סבא',
  'הרצליה',
  'חדרה',
  'מודיעין',
  'לוד',
  'רמלה',
  'רעננה',
  'גבעתיים',
  'הוד השרון',
  'קריית גת',
  'נהריה',
  'עכו',
  'טבריה',
  'צפת',
  'עפולה',
  'נצרת',
  'כרמיאל',
  'קריית שמונה',
  'אילת',
  'יבנה',
  'נס ציונה',
  'אריאל',
  'מעלה אדומים',
  'קריית ארבע',
];

String _listingPublishedAt(dynamic value, {bool compact = false}) {
  final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  if (parsed == null) return '';
  final day = parsed.day.toString().padLeft(2, '0');
  final month = parsed.month.toString().padLeft(2, '0');
  if (compact) return '$day/$month/${parsed.year.toString().substring(2)}';
  final hour = parsed.hour.toString().padLeft(2, '0');
  final minute = parsed.minute.toString().padLeft(2, '0');
  return 'פורסם ב־$day/$month/${parsed.year} בשעה $hour:$minute';
}

class _LocationAutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  const _LocationAutocompleteField({
    required this.controller,
    this.label = 'עיר או אזור',
    this.hint,
  });

  @override
  State<_LocationAutocompleteField> createState() =>
      _LocationAutocompleteFieldState();
}

class _LocationAutocompleteFieldState
    extends State<_LocationAutocompleteField> {
  final _focusNode = FocusNode();
  Timer? _searchDebounce;
  List<String> _governmentLocations = const [];

  void _searchGovernmentLocations(String value) {
    _searchDebounce?.cancel();
    final query = value.trim();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () async {
      try {
        final uri = Uri.parse('$kApi/localities')
            .replace(queryParameters: {if (query.isNotEmpty) 'q': query});
        final response = await http.get(uri);
        if (!mounted || response.statusCode != 200) return;
        final rows =
            (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
        setState(() => _governmentLocations = rows
            .map((row) => row['city']?.toString() ?? '')
            .where((city) => city.isNotEmpty)
            .toList());
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawAutocomplete<String>(
        textEditingController: widget.controller,
        focusNode: _focusNode,
        displayStringForOption: (option) => option,
        optionsBuilder: (value) {
          final query = value.text.trim();
          final combined = <String>{
            ..._governmentLocations,
            ..._kIsraeliLocations
                .where((location) => query.isEmpty || location.contains(query)),
          };
          return combined.take(30);
        },
        onSelected: (option) => widget.controller.text = option,
        fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
            TextField(
          controller: controller,
          focusNode: focusNode,
          textDirection: TextDirection.rtl,
          onChanged: _searchGovernmentLocations,
          onSubmitted: (_) => onSubmitted(),
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            prefixIcon: const Icon(Icons.location_city_outlined),
            border: const OutlineInputBorder(),
          ),
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topRight,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260, maxWidth: 420),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (_, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      option.startsWith('אזור') || option == 'כל הארץ'
                          ? Icons.map_outlined
                          : Icons.location_on_outlined,
                      color: kPrimary,
                    ),
                    title: Text(option, textDirection: TextDirection.rtl),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        ),
      );
}

class _StreetAutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final TextEditingController cityController;
  const _StreetAutocompleteField({
    required this.controller,
    required this.cityController,
  });

  @override
  State<_StreetAutocompleteField> createState() =>
      _StreetAutocompleteFieldState();
}

class _StreetAutocompleteFieldState extends State<_StreetAutocompleteField> {
  final _focusNode = FocusNode();
  Timer? _debounce;
  List<String> _streets = const [];

  void _search(String value) {
    _debounce?.cancel();
    final city = widget.cityController.text.trim();
    if (city.isEmpty) {
      setState(() => _streets = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 220), () async {
      try {
        final response = await http.get(Uri.parse('$kApi/streets').replace(
          queryParameters: {
            'city': city,
            if (value.trim().isNotEmpty) 'q': value.trim()
          },
        ));
        if (!mounted || response.statusCode != 200) return;
        final rows =
            (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
        setState(() => _streets = rows
            .map((row) => row['street']?.toString() ?? '')
            .where((street) => street.isNotEmpty)
            .toList());
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawAutocomplete<String>(
        textEditingController: widget.controller,
        focusNode: _focusNode,
        optionsBuilder: (_) => _streets,
        onSelected: (street) => widget.controller.text = street,
        fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
            TextField(
          controller: controller,
          focusNode: focusNode,
          textDirection: TextDirection.rtl,
          onChanged: _search,
          decoration: const InputDecoration(hintText: 'הקלד שם רחוב'),
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topRight,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260, maxWidth: 420),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (_, index) {
                  final street = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.add_road, color: kPrimary),
                    title: Text(street, textDirection: TextDirection.rtl),
                    onTap: () => onSelected(street),
                  );
                },
              ),
            ),
          ),
        ),
      );
}

class ListingsScreen extends StatefulWidget {
  final String token;
  final Map<String, dynamic>? me;
  final IO.Socket? socket;
  final Future<void> Function(Map<String, dynamic> recipient)?
      onConversationStarted;
  const ListingsScreen(
      {super.key,
      required this.token,
      required this.me,
      required this.socket,
      this.onConversationStarted});
  @override
  State<ListingsScreen> createState() => _ListingsScreenState();
}

class _ListingsScreenState extends State<ListingsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _typeFilter = 'all'; // all / free / sale
  String _catFilter = 'הכל';
  String _cityFilter = '';
  String _queryFilter = '';
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  double? _minPrice;
  double? _maxPrice;
  String _sortFilter = 'newest';
  double _radius = 0; // 0 = no radius filter
  Map<String, dynamic>? _selectedItem;
  bool _showPostForm = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _queryFilter = value.trim();
      _load();
    });
  }

  void _setQuickType(String type) {
    if (_typeFilter == type) return;
    setState(() => _typeFilter = type);
    _load();
  }

  void _clearAllFilters() {
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    setState(() {
      _typeFilter = 'all';
      _catFilter = 'הכל';
      _cityFilter = '';
      _queryFilter = '';
      _minPrice = null;
      _maxPrice = null;
      _sortFilter = 'newest';
      _radius = 0;
    });
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final params = <String, String>{'page': '1'};
      if (_typeFilter != 'all') params['type'] = _typeFilter;
      if (_catFilter != 'הכל') params['category'] = _catFilter;
      if (_cityFilter.isNotEmpty) params['city'] = _cityFilter;
      if (_queryFilter.isNotEmpty) params['q'] = _queryFilter;
      if (_minPrice != null) params['minPrice'] = _minPrice.toString();
      if (_maxPrice != null) params['maxPrice'] = _maxPrice.toString();
      if (_sortFilter != 'newest') params['sort'] = _sortFilter;
      if (_radius > 0) params['radius'] = _radius.toStringAsFixed(0);
      final uri = Uri.parse('$kApi/listings').replace(queryParameters: params);
      final res = await http
          .get(uri, headers: {'Authorization': 'Bearer ${widget.token}'});
      if (!mounted) return;
      final data = jsonDecode(res.body);
      final items = List<Map<String, dynamic>>.from(data);
      _persistRecentImageUrls(items).ignore();
      setState(() {
        _items = items;
        if (_selectedItem != null) {
          final selectedId = _selectedItem!['id'];
          final refreshed = items.where((item) => item['id'] == selectedId);
          _selectedItem = refreshed.isEmpty ? null : refreshed.first;
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openPost() async {
    if (MediaQuery.sizeOf(context).width >= 900) {
      setState(() {
        _selectedItem = null;
        _showPostForm = true;
      });
      return;
    }
    final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => PostListingScreen(token: widget.token, me: widget.me),
        ));
    if (ok == true) {
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('המודעה פורסמה בהצלחה')),
        );
      }
    }
  }

  Future<void> _openDetail(Map<String, dynamic> item) async {
    if (MediaQuery.sizeOf(context).width >= 900) {
      setState(() {
        _selectedItem = item;
        _showPostForm = false;
      });
      return;
    }
    final updated = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => ListingDetailScreen(
              item: item,
              token: widget.token,
              me: widget.me,
              socket: widget.socket,
              onConversationStarted: widget.onConversationStarted),
        ));
    if (updated == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final listPane = Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: kPrimary,
        toolbarHeight: 72,
        title: _BrandAppBarTitle(me: widget.me),
        actions: [
          IconButton(
            icon: const Icon(Icons.format_list_bulleted, color: Colors.white),
            tooltip: 'המודעות שלי',
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MyListingsScreen(token: widget.token),
                )),
          ),
          TextButton.icon(
            onPressed: _openPost,
            icon: const Icon(Icons.add_business_outlined,
                color: Colors.white, size: 20),
            label: const Text('פרסום מתקדם',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(112),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Column(children: [
              TextField(
                controller: _searchCtrl,
                onChanged: _onSearchChanged,
                textDirection: TextDirection.rtl,
                decoration: InputDecoration(
                  hintText: 'חיפוש במודעות... ',
                  prefixIcon: const Icon(Icons.search, size: 21),
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'נקה חיפוש',
                          icon: const Icon(Icons.close, size: 19),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _queryFilter = '');
                            _load();
                          },
                        ),
                  filled: true,
                  fillColor: Colors.white,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Row(children: [
                _quickFilterChip('all', 'הכול'),
                const SizedBox(width: 5),
                _quickFilterChip('free', 'למסירה'),
                const SizedBox(width: 5),
                _quickFilterChip('sale', 'למכירה'),
                const Spacer(),
                TextButton.icon(
                  onPressed: _showFilterSheet,
                  icon: Icon(Icons.tune,
                      size: 18,
                      color: _hasAdvancedFilters
                          ? const Color(0xFFFFD180)
                          : Colors.white),
                  label: Text(
                    _hasAdvancedFilters ? 'סינון פעיל' : 'סינון',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
      body: Column(children: [
        // ── List ────────────────────────────────────────────────────
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.storefront_outlined,
                          size: 64, color: kSubtext),
                      const SizedBox(height: 12),
                      Text(
                          _hasAdvancedFilters
                              ? 'לא נמצאו מודעות לפי הסינון'
                              : 'אין מודעות כרגע',
                          style: TextStyle(color: kSubtext, fontSize: 16)),
                      const SizedBox(height: 8),
                      if (_hasAdvancedFilters)
                        ElevatedButton.icon(
                          onPressed: _clearAllFilters,
                          icon: const Icon(Icons.filter_alt_off_outlined),
                          label: const Text('נקה את כל המסננים'),
                        )
                      else
                        TextButton(
                            onPressed: _openPost,
                            child: const Text('פרסם ראשון!')),
                    ]))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _items.length,
                        itemBuilder: (_, i) => _ListingCard(
                            item: _items[i],
                            selected: _selectedItem?['id'] == _items[i]['id'],
                            onTap: () => _openDetail(_items[i])),
                      ),
                    ),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openPost,
        backgroundColor: kPrimary,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('פרסום מתקדם', style: TextStyle(color: Colors.white)),
      ),
    );
    if (MediaQuery.sizeOf(context).width < 900) return listPane;
    return Row(children: [
      SizedBox(width: 410, child: listPane),
      const VerticalDivider(width: 1, thickness: 1, color: Color(0xFFD9DEE1)),
      Expanded(
        child: _showPostForm
            ? PostListingScreen(
                token: widget.token,
                me: widget.me,
                embedded: true,
                onClose: () => setState(() => _showPostForm = false),
                onPublished: () async {
                  setState(() => _showPostForm = false);
                  await _load();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('המודעה פורסמה בהצלחה')));
                  }
                },
              )
            : _selectedItem == null
                ? const _DesktopListingWelcome()
                : ListingDetailScreen(
                    key: ValueKey(_selectedItem!['id']),
                    item: _selectedItem!,
                    token: widget.token,
                    me: widget.me,
                    socket: widget.socket,
                    embedded: true,
                    onClose: () => setState(() => _selectedItem = null),
                    onUpdated: _load,
                    onConversationStarted: widget.onConversationStarted,
                  ),
      ),
    ]);
  }

  bool get _hasAdvancedFilters =>
      _typeFilter != 'all' ||
      _catFilter != 'הכל' ||
      _cityFilter.isNotEmpty ||
      _queryFilter.isNotEmpty ||
      _minPrice != null ||
      _maxPrice != null ||
      _radius > 0 ||
      _sortFilter != 'newest';

  Widget _quickFilterChip(String value, String label) {
    final selected = _typeFilter == value;
    return Material(
      color: selected ? Colors.white : const Color(0xFF17679D),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => _setQuickType(value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
          ),
          child: Text(label,
              style: TextStyle(
                color: selected ? kPrimary : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              )),
        ),
      ),
    );
  }

  void _showFilterSheet() {
    final cityCtrl = TextEditingController(text: _cityFilter);
    final queryCtrl = TextEditingController(text: _queryFilter);
    final minPriceCtrl = TextEditingController(
        text: _minPrice == null ? '' : _minPrice!.toStringAsFixed(0));
    final maxPriceCtrl = TextEditingController(
        text: _maxPrice == null ? '' : _maxPrice!.toStringAsFixed(0));
    String tmpType = _typeFilter;
    String tmpCategory = _catFilter;
    String tmpSort = _sortFilter;
    double tmpRadius = _radius;
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (ctx) {
          return StatefulBuilder(
              builder: (ctx, setS) => Padding(
                    padding: EdgeInsets.only(
                        bottom: MediaQuery.of(ctx).viewInsets.bottom,
                        left: 20,
                        right: 20,
                        top: 20),
                    child: SingleChildScrollView(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('חיפוש מתקדם',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 16),
                            TextField(
                              controller: queryCtrl,
                              textDirection: TextDirection.rtl,
                              decoration: const InputDecoration(
                                  labelText: 'מה מחפשים?',
                                  hintText: 'שם או תיאור המוצר',
                                  prefixIcon: Icon(Icons.search)),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              value: tmpType,
                              decoration: const InputDecoration(
                                  labelText: 'סוג מודעה',
                                  prefixIcon: Icon(Icons.sell_outlined)),
                              items: const [
                                DropdownMenuItem(
                                    value: 'all', child: Text('הכול')),
                                DropdownMenuItem(
                                    value: 'free',
                                    child: Text('למסירה ללא תשלום')),
                                DropdownMenuItem(
                                    value: 'sale', child: Text('למכירה')),
                              ],
                              onChanged: (value) =>
                                  setS(() => tmpType = value ?? 'all'),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              value: tmpCategory,
                              decoration: const InputDecoration(
                                  labelText: 'קטגוריה',
                                  prefixIcon: Icon(Icons.category_outlined)),
                              items: _kCategories
                                  .map((category) => DropdownMenuItem(
                                      value: category, child: Text(category)))
                                  .toList(),
                              onChanged: (value) =>
                                  setS(() => tmpCategory = value ?? 'הכל'),
                            ),
                            const SizedBox(height: 12),
                            Row(children: [
                              Expanded(
                                child: TextField(
                                  controller: minPriceCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                      labelText: 'מחיר מינימום',
                                      prefixText: '₪ '),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: maxPriceCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                      labelText: 'מחיר מקסימום',
                                      prefixText: '₪ '),
                                ),
                              ),
                            ]),
                            const SizedBox(height: 12),
                            _LocationAutocompleteField(
                              controller: cityCtrl,
                              label: 'עיר או אזור',
                              hint: 'התחל להקליד ובחר מהרשימה',
                            ),
                            const SizedBox(height: 16),
                            Text(
                                'רדיוס: ${tmpRadius == 0 ? "ללא" : "${tmpRadius.toInt()} ק״מ"}'),
                            Slider(
                              value: tmpRadius,
                              min: 0,
                              max: 100,
                              divisions: 10,
                              activeColor: kPrimary,
                              onChanged: (v) => setS(() => tmpRadius = v),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<String>(
                              value: tmpSort,
                              decoration: const InputDecoration(
                                  labelText: 'מיון תוצאות',
                                  prefixIcon: Icon(Icons.sort)),
                              items: const [
                                DropdownMenuItem(
                                    value: 'newest',
                                    child: Text('החדשות ביותר')),
                                DropdownMenuItem(
                                    value: 'price_asc',
                                    child: Text('מחיר: מהנמוך לגבוה')),
                                DropdownMenuItem(
                                    value: 'price_desc',
                                    child: Text('מחיר: מהגבוה לנמוך')),
                              ],
                              onChanged: (value) =>
                                  setS(() => tmpSort = value ?? 'newest'),
                            ),
                            const SizedBox(height: 12),
                            Row(children: [
                              Expanded(
                                  child: OutlinedButton(
                                onPressed: () {
                                  setState(() {
                                    _cityFilter = '';
                                    _queryFilter = '';
                                    _searchCtrl.clear();
                                    _typeFilter = 'all';
                                    _catFilter = 'הכל';
                                    _minPrice = null;
                                    _maxPrice = null;
                                    _sortFilter = 'newest';
                                    _radius = 0;
                                  });
                                  Navigator.pop(ctx);
                                  _load();
                                },
                                child: const Text('נקה'),
                              )),
                              const SizedBox(width: 12),
                              Expanded(
                                  child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: kPrimary),
                                onPressed: () {
                                  setState(() {
                                    _cityFilter = cityCtrl.text.trim();
                                    _queryFilter = queryCtrl.text.trim();
                                    _searchCtrl.text = _queryFilter;
                                    _typeFilter = tmpType;
                                    _catFilter = tmpCategory;
                                    _minPrice = double.tryParse(
                                        minPriceCtrl.text.trim());
                                    _maxPrice = double.tryParse(
                                        maxPriceCtrl.text.trim());
                                    _sortFilter = tmpSort;
                                    _radius = tmpRadius;
                                  });
                                  Navigator.pop(ctx);
                                  _load();
                                },
                                child: const Text('החל',
                                    style: TextStyle(color: Colors.white)),
                              )),
                            ]),
                            const SizedBox(height: 16),
                          ]),
                    ),
                  ));
        });
  }
}

class _DesktopListingWelcome extends StatelessWidget {
  const _DesktopListingWelcome();

  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFFF0F2F5),
        child: const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.storefront_outlined, size: 84, color: Color(0xFF9EADBA)),
            SizedBox(height: 22),
            Text('מודעות בתשובה',
                style: TextStyle(fontSize: 30, color: Color(0xFF41525D))),
            SizedBox(height: 10),
            Text('בחר מודעה מהרשימה כדי לראות את כל הפרטים',
                style: TextStyle(fontSize: 14, color: Color(0xFF667781))),
          ]),
        ),
      );
}

class _ListingCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onTap;
  final bool selected;
  const _ListingCard(
      {required this.item, required this.onTap, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final isFree = item['type'] == 'free';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
            color: selected ? const Color(0xFFE8F4FD) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: selected ? Border.all(color: kPrimary, width: 1.5) : null,
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.06),
                  blurRadius: 8,
                  offset: const Offset(0, 2))
            ]),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Image
          ClipRRect(
            borderRadius:
                const BorderRadius.horizontal(right: Radius.circular(14)),
            child: item['image_url'] != null
                ? _PersistentMediaImage(
                    url: item['image_url'].toString(),
                    width: 110,
                    height: 110,
                    fit: BoxFit.cover,
                    errorBuilder: (_) => _placeholder())
                : _placeholder(),
          ),
          // Info
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: isFree
                              ? const Color(0xFFD1FAE5)
                              : const Color(0xFFEDE9FE),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                            isFree
                                ? 'חינם'
                                : '₪${item['price']?.toStringAsFixed(0) ?? ''}',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isFree
                                    ? const Color(0xFF065F46)
                                    : const Color(0xFF5B21B6))),
                      ),
                      const SizedBox(width: 6),
                      if (item['category'] != null)
                        Text(item['category'],
                            style: TextStyle(fontSize: 12, color: kSubtext)),
                      const Spacer(),
                      if (_listingPublishedAt(item['created_at'], compact: true)
                          .isNotEmpty)
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.calendar_today_outlined,
                              size: 12, color: kSubtext),
                          const SizedBox(width: 3),
                          Text(
                            _listingPublishedAt(item['created_at'],
                                compact: true),
                            style: TextStyle(fontSize: 11, color: kSubtext),
                          ),
                        ]),
                    ]),
                    const SizedBox(height: 6),
                    Text(item['title'] ?? '',
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    if (item['city'] != null)
                      Row(children: [
                        Icon(Icons.location_on_outlined,
                            size: 14, color: kSubtext),
                        const SizedBox(width: 2),
                        Text(item['city'],
                            style: TextStyle(fontSize: 12, color: kSubtext)),
                        if (item['distance_km'] != null) ...[
                          Text(' · ', style: TextStyle(color: kSubtext)),
                          Text('${item['distance_km']} ק״מ',
                              style: TextStyle(fontSize: 12, color: kSubtext)),
                        ],
                      ]),
                  ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _placeholder() => Container(
      width: 110,
      height: 110,
      color: const Color(0xFFE8F4FD),
      child: Icon(Icons.image_outlined, size: 36, color: kSubtext));
}

// ── My Listings Screen ────────────────────────────────────────────
class MyListingsScreen extends StatefulWidget {
  final String token;
  const MyListingsScreen({super.key, required this.token});
  @override
  State<MyListingsScreen> createState() => _MyListingsScreenState();
}

class _MyListingsScreenState extends State<MyListingsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final res = await http.get(
        Uri.parse('$kApi/listings?mine=true'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      setState(() {
        _items = List<Map<String, dynamic>>.from(jsonDecode(res.body));
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markSold(String id) async {
    await http.put(
      Uri.parse('$kApi/listings/$id/status'),
      headers: {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json'
      },
      body: jsonEncode({'status': 'sold'}),
    );
    _load();
  }

  Future<void> _edit(String id) async {
    final updated = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => EditListingScreen(listingId: id, token: widget.token),
        ));
    if (updated == true) _load();
  }

  Future<void> _delete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('מחיקת מודעה'),
        content: const Text('למחוק את המודעה לצמיתות?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('מחק', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await http.delete(
      Uri.parse('$kApi/listings/$id'),
      headers: {'Authorization': 'Bearer ${widget.token}'},
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: kPrimary,
        title: const Text('המודעות שלי',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        leading: BackButton(color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.storefront_outlined, size: 64, color: kSubtext),
                  const SizedBox(height: 12),
                  Text('עדיין אין לך מודעות',
                      style: TextStyle(color: kSubtext, fontSize: 16)),
                ]))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _items.length,
                    itemBuilder: (_, i) => _MyListingCard(
                      item: _items[i],
                      onMarkSold: () => _markSold(_items[i]['id']),
                      onDelete: () => _delete(_items[i]['id']),
                      onEdit: () => _edit(_items[i]['id']),
                    ),
                  ),
                ),
    );
  }
}

class _MyListingCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onMarkSold;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  const _MyListingCard(
      {required this.item,
      required this.onMarkSold,
      required this.onDelete,
      required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final isFree = item['type'] == 'free';
    final status = item['status'] as String? ?? 'active';
    final isActive = status == 'active';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: item['image_url'] != null
                  ? _PersistentMediaImage(
                      url: item['image_url'].toString(),
                      width: 66,
                      height: 66,
                      fit: BoxFit.cover,
                      errorBuilder: (_) => _imgPlaceholder())
                  : _imgPlaceholder(),
            ),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(item['title'] ?? '',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 5),
                  Wrap(spacing: 5, children: [
                    _badge(
                        isFree
                            ? 'חינם'
                            : '₪${item['price']?.toStringAsFixed(0) ?? ''}',
                        isFree
                            ? const Color(0xFFD1FAE5)
                            : const Color(0xFFEDE9FE),
                        isFree
                            ? const Color(0xFF065F46)
                            : const Color(0xFF5B21B6)),
                    _badge(
                        status == 'active'
                            ? 'פעיל'
                            : status == 'sold'
                                ? 'נסגר'
                                : 'פג תוקף',
                        isActive
                            ? const Color(0xFFDCFCE7)
                            : const Color(0xFFF3F4F6),
                        isActive
                            ? const Color(0xFF166534)
                            : const Color(0xFF6B7280)),
                  ]),
                ])),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.visibility_outlined, size: 15, color: kSubtext),
            const SizedBox(width: 3),
            Text('${item['view_count'] ?? 0}',
                style: TextStyle(fontSize: 13, color: kSubtext)),
            const SizedBox(width: 12),
            Icon(Icons.chat_bubble_outline, size: 15, color: kSubtext),
            const SizedBox(width: 3),
            Text('${item['contact_count'] ?? 0}',
                style: TextStyle(fontSize: 13, color: kSubtext)),
            const Spacer(),
            _actionBtn('ערוך', const Color(0xFFE0F2FE), const Color(0xFF0369A1),
                onEdit),
            const SizedBox(width: 6),
            if (isActive) ...[
              _actionBtn('סגור', const Color(0xFFD1FAE5),
                  const Color(0xFF065F46), onMarkSold),
              const SizedBox(width: 6),
            ],
            _actionBtn('מחק', const Color(0xFFFEE2E2), const Color(0xFF991B1B),
                onDelete),
          ]),
        ]),
      ),
    );
  }

  Widget _imgPlaceholder() => Container(
      width: 66,
      height: 66,
      decoration: BoxDecoration(
          color: const Color(0xFFE8F4FD),
          borderRadius: BorderRadius.circular(8)),
      child: Icon(Icons.image_outlined, color: kSubtext, size: 28));

  Widget _badge(String text, Color bg, Color fg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(text,
          style:
              TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: fg)));

  Widget _actionBtn(String label, Color bg, Color fg, VoidCallback onTap) =>
      GestureDetector(
          onTap: onTap,
          child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  color: bg, borderRadius: BorderRadius.circular(8)),
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: fg))));
}

// ── Post Listing Screen ───────────────────────────────────────────
class PostListingScreen extends StatefulWidget {
  final String token;
  final Map<String, dynamic>? me;
  final bool embedded;
  final VoidCallback? onClose;
  final Future<void> Function()? onPublished;
  const PostListingScreen({
    super.key,
    required this.token,
    required this.me,
    this.embedded = false,
    this.onClose,
    this.onPublished,
  });
  @override
  State<PostListingScreen> createState() => _PostListingScreenState();
}

class _PostListingScreenState extends State<PostListingScreen> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _quantityCtrl = TextEditingController(text: '1');
  final _pickupCtrl = TextEditingController();
  final _plateCtrl = TextEditingController();
  final _vehicleManufacturerCtrl = TextEditingController();
  final _vehicleModelCtrl = TextEditingController();
  final _vehicleYearCtrl = TextEditingController();
  final _vehicleMileageCtrl = TextEditingController();
  final _vehicleHandCtrl = TextEditingController();
  final _vehicleFuelCtrl = TextEditingController();
  final _vehicleColorCtrl = TextEditingController();
  final _vehicleTestCtrl = TextEditingController();
  late final _cityCtrl =
      TextEditingController(text: widget.me?['city'] as String? ?? '');
  String _category = 'אחר';
  String _condition = 'good';
  String _deliveryMethod = 'pickup';
  int _expiryDays = 30;
  bool _negotiable = false;
  bool _showPhone = false;
  final List<String?> _imageUrls = List<String?>.filled(8, null);
  final List<bool> _uploadingSlot = List<bool>.filled(8, false);
  final List<_FileUploadOutcome?> _imageOutcomes =
      List<_FileUploadOutcome?>.filled(8, null);
  final List<String?> _imageReasons = List<String?>.filled(8, null);
  bool _saving = false;
  bool _vehicleLookupLoading = false;
  String? _vehicleLookupMessage;
  String _vehicleTransmission = 'automatic';
  Timer? _plateLookupTimer;
  String _mirroredTitle = '';

  @override
  void initState() {
    super.initState();
    _titleCtrl.addListener(_mirrorTitleIntoDescription);
    if (_cityCtrl.text.trim().isEmpty) _loadCityFromProfile();
  }

  void _mirrorTitleIntoDescription() {
    final title = _titleCtrl.text.trim();
    final current = _descCtrl.text;
    String? updated;
    if (_mirroredTitle.isEmpty && current.trim().isEmpty) {
      updated = title;
    } else if (current.trim() == _mirroredTitle) {
      updated = title;
    } else if (_mirroredTitle.isNotEmpty &&
        current.startsWith('$_mirroredTitle\n\n')) {
      final remainder = current.substring(_mirroredTitle.length + 2);
      updated = title.isEmpty ? remainder : '$title\n\n$remainder';
    }
    _mirroredTitle = title;
    if (updated != null && updated != current) {
      _descCtrl.value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: updated.length),
      );
    }
  }

  Future<void> _loadCityFromProfile() async {
    try {
      final response = await http.get(Uri.parse('$kApi/profile'),
          headers: {'Authorization': 'Bearer ${widget.token}'});
      if (!mounted || response.statusCode != 200 || _cityCtrl.text.isNotEmpty) {
        return;
      }
      final profile = jsonDecode(response.body);
      final city = profile is Map ? profile['city']?.toString().trim() : null;
      if (city != null && city.isNotEmpty) {
        setState(() => _cityCtrl.text = city);
      } else {
        await _loadCityFromDevice();
      }
    } catch (_) {
      await _loadCityFromDevice();
    }
  }

  Future<void> _loadCityFromDevice() async {
    if (!mounted || _cityCtrl.text.trim().isNotEmpty) return;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) return;
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 10),
        ),
      );
      final response = await http.put(
        Uri.parse('$kApi/location/city'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'latitude': position.latitude,
          'longitude': position.longitude,
        }),
      );
      if (!mounted || response.statusCode != 200) return;
      final payload = jsonDecode(response.body);
      final city = payload is Map ? payload['city']?.toString().trim() : null;
      if (city != null && city.isNotEmpty && _cityCtrl.text.trim().isEmpty) {
        setState(() => _cityCtrl.text = city);
      }
    } catch (_) {
      // The locality can always be selected manually when location is denied.
    }
  }

  Future<void> _lookupVehicle() async {
    final plate = _plateCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (plate.length != 7 && plate.length != 8) {
      setState(() => _vehicleLookupMessage = 'יש להזין 7 או 8 ספרות');
      return;
    }
    setState(() {
      _vehicleLookupLoading = true;
      _vehicleLookupMessage = null;
    });
    try {
      final response = await http.get(
        Uri.parse('$kApi/vehicles/$plate'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      ).timeout(const Duration(seconds: 12));
      if (!mounted) return;
      final payload = jsonDecode(response.body);
      if (response.statusCode != 200 || payload is! Map) {
        setState(() => _vehicleLookupMessage = payload is Map
            ? (payload['error']?.toString() ?? 'הרכב לא נמצא')
            : 'הרכב לא נמצא');
        return;
      }
      final details = Map<String, dynamic>.from(payload['details'] as Map);
      _vehicleManufacturerCtrl.text = details['manufacturer']?.toString() ?? '';
      _vehicleModelCtrl.text = details['model']?.toString() ?? '';
      _vehicleYearCtrl.text = details['year']?.toString() ?? '';
      _vehicleFuelCtrl.text = details['fuel']?.toString() ?? '';
      _vehicleColorCtrl.text = details['color']?.toString() ?? '';
      _vehicleTestCtrl.text = details['test_valid_until']?.toString() ?? '';
      if (_titleCtrl.text.trim().isEmpty) {
        _titleCtrl.text = [
          _vehicleManufacturerCtrl.text,
          _vehicleModelCtrl.text,
          _vehicleYearCtrl.text,
        ].where((value) => value.trim().isNotEmpty).join(' ');
      }
      setState(() => _vehicleLookupMessage =
          'הפרטים אותרו במאגר משרד התחבורה — מומלץ לבדוק אותם');
    } catch (_) {
      if (mounted) {
        setState(() => _vehicleLookupMessage =
            'לא ניתן לבדוק כרגע; אפשר למלא את הפרטים ידנית');
      }
    } finally {
      if (mounted) setState(() => _vehicleLookupLoading = false);
    }
  }

  void _onPlateChanged(String value) {
    _plateLookupTimer?.cancel();
    final plate = value.replaceAll(RegExp(r'\D'), '');
    if (plate.length == 7 || plate.length == 8) {
      _plateLookupTimer =
          Timer(const Duration(milliseconds: 650), _lookupVehicle);
    }
  }

  Future<void> _pickImage(int slot) async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(imageQuality: 80);
    if (picked.isEmpty || !mounted) return;
    final availableSlots = <int>[
      slot,
      for (var i = 0; i < _imageUrls.length; i++)
        if (i != slot && _imageUrls[i] == null) i,
    ];
    final selected = picked.take(availableSlots.length).toList();
    if (picked.length > availableSlots.length) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('ניתן לצרף עד 8 תמונות למודעה'),
      ));
    }
    setState(() {
      for (var i = 0; i < selected.length; i++) {
        _uploadingSlot[availableSlots[i]] = true;
      }
    });
    final completed = ValueNotifier<int>(0);
    try {
      final results = await _runImageUploadQueue(
        selected,
        (file) => _uploadFileRequest(
          file: file,
          fileName: file.name,
          token: widget.token,
          fields: const {'listingImage': 'true'},
        ),
        completed,
      );
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < results.length; i++) {
          final target = availableSlots[i];
          final result = results[i];
          final url = result.data['url']?.toString();
          _imageOutcomes[target] = result.outcome;
          _imageReasons[target] =
              result.data['reason']?.toString() ?? result.error;
          // The server keeps rejected/pending uploads for moderation. Show the
          // returned image to its owner, but only approved URLs are published.
          if (url != null && url.isNotEmpty) _imageUrls[target] = url;
        }
      });
      _showImageBatchSummary(context, results);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('שגיאה בהעלאת תמונה: $error')));
      }
    } finally {
      completed.dispose();
      if (mounted) {
        setState(() {
          for (var i = 0; i < selected.length; i++) {
            _uploadingSlot[availableSlots[i]] = false;
          }
        });
      }
    }
  }

  Future<void> _removeImage(int slot) async {
    if (_imageUrls[slot] == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('מחיקת תמונה'),
        content: const Text(
            'להסיר את התמונה מהמודעה? המחיקה תושלם לאחר לחיצה על „שמור שינויים”.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('ביטול'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.delete_outline, color: Colors.white),
            label:
                const Text('הסר תמונה', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() {
        _imageUrls[slot] = null;
        _imageOutcomes[slot] = null;
        _imageReasons[slot] = null;
      });
    }
  }

  Future<void> _submit() async {
    if (_titleCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('נדרשת כותרת')));
      return;
    }
    if (_descCtrl.text.trim().length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('יש להוסיף תיאור ברור של לפחות 10 תווים')));
      return;
    }
    final priceText = _priceCtrl.text.trim();
    final parsedPrice = priceText.isEmpty ? 0.0 : double.tryParse(priceText);
    if (parsedPrice == null || parsedPrice < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('יש להזין מחיר תקין, 0 או יותר')));
      return;
    }
    final listingType = parsedPrice == 0 ? 'free' : 'sale';
    if (_cityCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('יש להזין עיר או אזור')));
      return;
    }
    setState(() => _saving = true);
    try {
      final urls = <String>[];
      for (var i = 0; i < _imageUrls.length; i++) {
        if (_imageUrls[i] != null &&
            _imageOutcomes[i] == _FileUploadOutcome.approved) {
          urls.add(_imageUrls[i]!);
        }
      }
      final city = _cityCtrl.text.trim();
      final title = _titleCtrl.text.trim();
      final enteredDescription = _descCtrl.text.trim();
      final description = enteredDescription.startsWith(title)
          ? enteredDescription
          : '$title\n\n$enteredDescription';
      final body = <String, dynamic>{
        'type': listingType,
        'title': title,
        'description': description,
        'category': _category,
        'item_condition': _condition,
        'negotiable': listingType == 'sale' && _negotiable,
        'quantity': int.tryParse(_quantityCtrl.text) ?? 1,
        'delivery_method': _deliveryMethod,
        'pickup_details': _pickupCtrl.text.trim(),
        'contact_phone_visible': _showPhone,
        'expires_in_days': _expiryDays,
        if (city.isNotEmpty) 'city': city,
        if (urls.isNotEmpty) 'image_urls': urls,
        if (_category == 'רכב' && _plateCtrl.text.trim().isNotEmpty)
          'license_plate': _plateCtrl.text,
        if (_category == 'רכב')
          'vehicle_details': {
            'manufacturer': _vehicleManufacturerCtrl.text.trim(),
            'model': _vehicleModelCtrl.text.trim(),
            'year': _vehicleYearCtrl.text.trim(),
            'mileage': _vehicleMileageCtrl.text.trim(),
            'hand': _vehicleHandCtrl.text.trim(),
            'transmission': _vehicleTransmission,
            'fuel': _vehicleFuelCtrl.text.trim(),
            'color': _vehicleColorCtrl.text.trim(),
            'test_valid_until': _vehicleTestCtrl.text.trim(),
          },
      };
      body['price'] = parsedPrice;
      final res = await http
          .post(
            Uri.parse('$kApi/listings'),
            headers: {
              'Authorization': 'Bearer ${widget.token}',
              'Content-Type': 'application/json'
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (res.statusCode == 200) {
        if (widget.embedded) {
          await widget.onPublished?.call();
        } else {
          Navigator.pop(context, true);
        }
        return;
      }
      var message = 'פרסום המודעה נכשל';
      try {
        final response = jsonDecode(res.body);
        if (response is Map && response['error'] != null) {
          message = response['error'].toString();
        }
      } catch (_) {}
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$message (${res.statusCode})')),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('פרסום המודעה נכשל: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _titleCtrl.removeListener(_mirrorTitleIntoDescription);
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _quantityCtrl.dispose();
    _pickupCtrl.dispose();
    _plateLookupTimer?.cancel();
    _plateCtrl.dispose();
    _vehicleManufacturerCtrl.dispose();
    _vehicleModelCtrl.dispose();
    _vehicleYearCtrl.dispose();
    _vehicleMileageCtrl.dispose();
    _vehicleHandCtrl.dispose();
    _vehicleFuelCtrl.dispose();
    _vehicleColorCtrl.dispose();
    _vehicleTestCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kPrimary,
        title: const Text('פרסום מתקדם', style: TextStyle(color: Colors.white)),
        leading: BackButton(
          color: Colors.white,
          onPressed: widget.onClose ?? () => Navigator.pop(context),
        ),
      ),
      body: Align(
        alignment: widget.embedded ? Alignment.topCenter : Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(right: BorderSide(color: kBorder)),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Choose the category first so category-specific fields
                    // are shown before the rest of the listing form.
                    DropdownButtonFormField<String>(
                      value: _category,
                      decoration: const InputDecoration(
                          labelText: 'קטגוריה', border: OutlineInputBorder()),
                      items: _kCategories
                          .skip(1)
                          .map(
                              (c) => DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: (v) => setState(() => _category = v!),
                    ),
                    if (_category == 'רכב') ...[
                      const SizedBox(height: 12),
                      _vehicleFields(),
                    ],
                    const SizedBox(height: 12),
                    // Title
                    TextField(
                        controller: _titleCtrl,
                        textDirection: TextDirection.rtl,
                        decoration: const InputDecoration(
                            labelText: 'כותרת המודעה *',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    // Description
                    TextField(
                        controller: _descCtrl,
                        textDirection: TextDirection.rtl,
                        maxLines: 3,
                        decoration: InputDecoration(
                            labelText: 'תיאור מפורט *',
                            hintText: _category == 'רכב'
                                ? 'מצב הרכב, טיפולים, בעלות קודמת, פגמים וכל פרט חשוב'
                                : 'מצב המוצר, מידות, גיל, פגמים וכל פרט חשוב',
                            border: const OutlineInputBorder())),
                    const SizedBox(height: 12),
                    TextField(
                        controller: _priceCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'מחיר (₪) — 0 למסירה',
                            hintText: '0',
                            helperText: 'מחיר 0 יסווג את המודעה כמסירה',
                            border: OutlineInputBorder(),
                            prefixText: '₪ ')),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('המחיר גמיש'),
                      subtitle: const Text('רלוונטי כאשר המחיר גדול מאפס'),
                      value: _negotiable,
                      onChanged: (value) => setState(() => _negotiable = value),
                    ),
                    if (_category != 'רכב') ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: _condition,
                        decoration: const InputDecoration(
                            labelText: 'מצב המוצר *',
                            prefixIcon: Icon(Icons.verified_outlined),
                            border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(value: 'new', child: Text('חדש')),
                          DropdownMenuItem(
                              value: 'like_new', child: Text('כמו חדש')),
                          DropdownMenuItem(
                              value: 'good', child: Text('מצב טוב')),
                          DropdownMenuItem(
                              value: 'fair', child: Text('מצב סביר')),
                          DropdownMenuItem(
                              value: 'for_parts',
                              child: Text('לתיקון / לחלקים')),
                        ],
                        onChanged: (value) =>
                            setState(() => _condition = value ?? 'good'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _quantityCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'כמות',
                            prefixIcon: Icon(Icons.numbers),
                            border: OutlineInputBorder()),
                      ),
                    ],
                    const SizedBox(height: 12),
                    // City
                    _LocationAutocompleteField(
                      controller: _cityCtrl,
                      label: 'עיר או אזור *',
                      hint: 'התחל להקליד ובחר מהרשימה',
                    ),
                    if (_category != 'רכב') ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: _deliveryMethod,
                        decoration: const InputDecoration(
                            labelText: 'אופן קבלה *',
                            prefixIcon: Icon(Icons.local_shipping_outlined),
                            border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(
                              value: 'pickup', child: Text('איסוף עצמי')),
                          DropdownMenuItem(
                              value: 'delivery', child: Text('משלוח')),
                          DropdownMenuItem(
                              value: 'both',
                              child: Text('איסוף עצמי או משלוח')),
                        ],
                        onChanged: (value) =>
                            setState(() => _deliveryMethod = value ?? 'pickup'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _pickupCtrl,
                        textDirection: TextDirection.rtl,
                        maxLines: 2,
                        decoration: const InputDecoration(
                            labelText: 'פרטי איסוף או משלוח',
                            hintText:
                                'לדוגמה: איסוף בשעות הערב, קומה ללא מעלית',
                            border: OutlineInputBorder()),
                      ),
                    ],
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('הצגת מספר הטלפון במודעה'),
                      subtitle:
                          const Text('כבוי כברירת מחדל; תמיד אפשר לפנות בצ׳אט'),
                      value: _showPhone,
                      onChanged: (value) => setState(() => _showPhone = value),
                    ),
                    DropdownButtonFormField<int>(
                      value: _expiryDays,
                      decoration: const InputDecoration(
                          labelText: 'משך פרסום',
                          prefixIcon: Icon(Icons.schedule_outlined),
                          border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: 7, child: Text('7 ימים')),
                        DropdownMenuItem(value: 14, child: Text('14 ימים')),
                        DropdownMenuItem(value: 30, child: Text('30 ימים')),
                        DropdownMenuItem(value: 60, child: Text('60 ימים')),
                      ],
                      onChanged: (value) =>
                          setState(() => _expiryDays = value ?? 30),
                    ),
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 12),
                    Text('הוספת תמונות',
                        style: TextStyle(
                            fontSize: 17,
                            color: kTextDark,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text('ניתן להוסיף עד 8 תמונות, ללא אנשים',
                        style: TextStyle(fontSize: 13, color: kSubtext)),
                    const SizedBox(height: 10),
                    _dynamicImagePicker(),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: kPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 14)),
                      onPressed: _saving ? null : _submit,
                      child: _saving
                          ? const CircularProgressIndicator(color: Colors.white)
                          : const Text('פרסם',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                    ),
                  ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _unusedEditVehicleFieldsA() {
    Widget field(TextEditingController controller, String label,
            {bool numeric = false}) =>
        TextField(
          controller: controller,
          keyboardType: numeric ? TextInputType.number : TextInputType.text,
          inputFormatters:
              numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F9FD),
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _plateCtrl,
          keyboardType: TextInputType.number,
          maxLength: 8,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'מספר לוחית רישוי',
            counterText: '',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: field(_vehicleManufacturerCtrl, 'יצרן')),
          const SizedBox(width: 10),
          Expanded(child: field(_vehicleModelCtrl, 'דגם')),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: field(_vehicleYearCtrl, 'שנת ייצור', numeric: true)),
          const SizedBox(width: 10),
          Expanded(
              child: field(_vehicleMileageCtrl, 'קילומטראז׳', numeric: true)),
          const SizedBox(width: 10),
          Expanded(child: field(_vehicleHandCtrl, 'יד', numeric: true)),
        ]),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _vehicleTransmission,
          decoration: const InputDecoration(
              labelText: 'תיבת הילוכים', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 'automatic', child: Text('אוטומטית')),
            DropdownMenuItem(value: 'manual', child: Text('ידנית')),
            DropdownMenuItem(value: 'robotic', child: Text('רובוטית')),
            DropdownMenuItem(value: 'other', child: Text('אחרת')),
          ],
          onChanged: (value) =>
              setState(() => _vehicleTransmission = value ?? 'automatic'),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: field(_vehicleFuelCtrl, 'סוג דלק')),
          const SizedBox(width: 10),
          Expanded(child: field(_vehicleColorCtrl, 'צבע')),
        ]),
        const SizedBox(height: 10),
        field(_vehicleTestCtrl, 'תוקף מבחן רישוי (טסט)'),
      ]),
    );
  }

  Widget _unusedEditVehicleFieldsB() {
    Widget field(TextEditingController controller, String label,
            {bool numeric = false}) =>
        TextField(
          controller: controller,
          keyboardType: numeric ? TextInputType.number : TextInputType.text,
          inputFormatters:
              numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F9FD),
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _plateCtrl,
          keyboardType: TextInputType.number,
          maxLength: 8,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'מספר לוחית רישוי',
            counterText: '',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: field(_vehicleManufacturerCtrl, 'יצרן')),
          const SizedBox(width: 10),
          Expanded(child: field(_vehicleModelCtrl, 'דגם')),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: field(_vehicleYearCtrl, 'שנת ייצור', numeric: true)),
          const SizedBox(width: 10),
          Expanded(
              child: field(_vehicleMileageCtrl, 'קילומטראז׳', numeric: true)),
          const SizedBox(width: 10),
          Expanded(child: field(_vehicleHandCtrl, 'יד', numeric: true)),
        ]),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _vehicleTransmission,
          decoration: const InputDecoration(
              labelText: 'תיבת הילוכים', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 'automatic', child: Text('אוטומטית')),
            DropdownMenuItem(value: 'manual', child: Text('ידנית')),
            DropdownMenuItem(value: 'robotic', child: Text('רובוטית')),
            DropdownMenuItem(value: 'other', child: Text('אחרת')),
          ],
          onChanged: (value) =>
              setState(() => _vehicleTransmission = value ?? 'automatic'),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: field(_vehicleFuelCtrl, 'סוג דלק')),
          const SizedBox(width: 10),
          Expanded(child: field(_vehicleColorCtrl, 'צבע')),
        ]),
        const SizedBox(height: 10),
        field(_vehicleTestCtrl, 'תוקף מבחן רישוי (טסט)'),
      ]),
    );
  }

  Widget _imageSlot(int i) {
    final url = _imageUrls[i];
    final uploading = _uploadingSlot[i];
    final outcome = _imageOutcomes[i];
    final rejected = outcome == _FileUploadOutcome.rejected ||
        outcome == _FileUploadOutcome.failed;
    final pending = outcome == _FileUploadOutcome.pending;
    return GestureDetector(
      onTap: uploading ? null : () => _pickImage(i),
      onLongPress: url != null ? () => _removeImage(i) : null,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFE8F4FD),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kBorder),
        ),
        child: uploading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : url != null
                ? Stack(fit: StackFit.expand, children: [
                    ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child:
                            _PersistentMediaImage(url: url, fit: BoxFit.cover)),
                    Positioned(
                        top: 3,
                        left: 3,
                        child: Material(
                          color: Colors.red.shade700,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => _removeImage(i),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(Icons.delete_outline,
                                  size: 18, color: Colors.white),
                            ),
                          ),
                        )),
                    Positioned(
                      right: 3,
                      bottom: 3,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: const BoxDecoration(
                            color: Colors.black54, shape: BoxShape.circle),
                        child: const Icon(Icons.edit,
                            size: 13, color: Colors.white),
                      ),
                    ),
                    if (rejected || pending)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            alignment: Alignment.bottomCenter,
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(9),
                              color: rejected
                                  ? const Color(0x66B91C1C)
                                  : const Color(0x556B7280),
                            ),
                            child: Text(
                              rejected
                                  ? 'לא אושרה\n${_imageReasons[i] ?? ''}'
                                  : 'ממתינה לסריקה',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                  ])
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                        Icon(Icons.add_photo_alternate_outlined,
                            size: 24, color: kPrimary),
                        if (i == 0)
                          Text('תמונה ראשית',
                              style: TextStyle(fontSize: 9, color: kSubtext),
                              textAlign: TextAlign.center),
                      ]),
      ),
    );
  }

  Widget _dynamicImagePicker() {
    final occupied = <int>[
      for (var i = 0; i < 8; i++)
        if (_imageUrls[i] != null || _uploadingSlot[i]) i,
    ];
    int? firstFree;
    for (var i = 0; i < 8; i++) {
      if (_imageUrls[i] == null && !_uploadingSlot[i]) {
        firstFree = i;
        break;
      }
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final i in occupied)
          SizedBox(width: 150, height: 150, child: _imageSlot(i)),
        if (firstFree != null)
          SizedBox(
            width: 150,
            height: 150,
            child: OutlinedButton.icon(
              onPressed: () => _pickImage(firstFree!),
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text(occupied.isEmpty ? 'בחירת תמונות' : 'הוסף תמונות'),
            ),
          ),
      ],
    );
  }

  Widget _vehicleFields() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F9FD),
          border: Border.all(color: kBorder),
          borderRadius: BorderRadius.circular(14),
        ),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.directions_car_outlined, color: kPrimary),
            const SizedBox(width: 8),
            Text('מאפייני הרכב',
                style: TextStyle(
                    color: kTextDark,
                    fontSize: 17,
                    fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 6),
          Text(
              'מספר הרישוי אינו חובה. אם יוזן, ננסה להשלים פרטים מהמאגר הממשלתי.',
              style: TextStyle(color: kSubtext, fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
            controller: _plateCtrl,
            keyboardType: TextInputType.number,
            maxLength: 8,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: _onPlateChanged,
            decoration: InputDecoration(
              labelText: 'מספר לוחית רישוי (לא חובה)',
              hintText: '7 או 8 ספרות',
              counterText: '',
              prefixIcon: const Icon(Icons.pin_outlined),
              suffixIcon: _vehicleLookupLoading
                  ? const Padding(
                      padding: EdgeInsets.all(13),
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : IconButton(
                      tooltip: 'איתור פרטי הרכב',
                      onPressed: _lookupVehicle,
                      icon: const Icon(Icons.search)),
              border: const OutlineInputBorder(),
            ),
          ),
          if (_vehicleLookupMessage != null) ...[
            const SizedBox(height: 6),
            Text(_vehicleLookupMessage!,
                style: TextStyle(
                    color: _vehicleLookupMessage!.startsWith('הפרטים אותרו')
                        ? Colors.green.shade700
                        : Colors.orange.shade800,
                    fontSize: 12)),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
                child: _vehicleTextField(_vehicleManufacturerCtrl, 'יצרן')),
            const SizedBox(width: 10),
            Expanded(child: _vehicleTextField(_vehicleModelCtrl, 'דגם')),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
                child: _vehicleTextField(_vehicleYearCtrl, 'שנת ייצור',
                    numeric: true)),
            const SizedBox(width: 10),
            Expanded(
                child: _vehicleTextField(_vehicleMileageCtrl, 'קילומטראז׳',
                    numeric: true)),
            const SizedBox(width: 10),
            Expanded(
                child:
                    _vehicleTextField(_vehicleHandCtrl, 'יד', numeric: true)),
          ]),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: _vehicleTransmission,
            decoration: const InputDecoration(
                labelText: 'תיבת הילוכים', border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'automatic', child: Text('אוטומטית')),
              DropdownMenuItem(value: 'manual', child: Text('ידנית')),
              DropdownMenuItem(value: 'robotic', child: Text('רובוטית')),
              DropdownMenuItem(value: 'other', child: Text('אחרת')),
            ],
            onChanged: (value) =>
                setState(() => _vehicleTransmission = value ?? 'automatic'),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _vehicleTextField(_vehicleFuelCtrl, 'סוג דלק')),
            const SizedBox(width: 10),
            Expanded(child: _vehicleTextField(_vehicleColorCtrl, 'צבע')),
          ]),
          const SizedBox(height: 10),
          _vehicleTextField(_vehicleTestCtrl, 'תוקף מבחן רישוי (טסט)'),
          const SizedBox(height: 6),
          Text(
              'המידע מהמשרד הממשלתי הוא מידע מסייע ואינו תחליף לבדיקת הרכב והרישיון.',
              style: TextStyle(color: kSubtext, fontSize: 11)),
        ]),
      );

  Widget _vehicleTextField(TextEditingController controller, String label,
          {bool numeric = false}) =>
      TextField(
        controller: controller,
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        inputFormatters:
            numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
      );
}

// ── Edit Listing Screen ───────────────────────────────────────────
class EditListingScreen extends StatefulWidget {
  final String listingId;
  final String token;
  const EditListingScreen(
      {super.key, required this.listingId, required this.token});
  @override
  State<EditListingScreen> createState() => _EditListingScreenState();
}

class _EditListingScreenState extends State<EditListingScreen> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _quantityCtrl = TextEditingController(text: '1');
  final _pickupCtrl = TextEditingController();
  final _plateCtrl = TextEditingController();
  final _vehicleManufacturerCtrl = TextEditingController();
  final _vehicleModelCtrl = TextEditingController();
  final _vehicleYearCtrl = TextEditingController();
  final _vehicleMileageCtrl = TextEditingController();
  final _vehicleHandCtrl = TextEditingController();
  final _vehicleFuelCtrl = TextEditingController();
  final _vehicleColorCtrl = TextEditingController();
  final _vehicleTestCtrl = TextEditingController();
  String _category = 'אחר';
  String _condition = 'good';
  String _deliveryMethod = 'pickup';
  String _vehicleTransmission = 'automatic';
  int _expiryDays = 30;
  bool _negotiable = false;
  bool _showPhone = false;
  final List<String?> _imageUrls = List<String?>.filled(8, null);
  final List<bool> _uploadingSlot = List<bool>.filled(8, false);
  final List<_FileUploadOutcome?> _imageOutcomes =
      List<_FileUploadOutcome?>.filled(8, null);
  final List<String?> _imageReasons = List<String?>.filled(8, null);
  bool _loading = true;
  bool _saving = false;
  String _mirroredTitle = '';

  Widget _editVehicleFields() {
    Widget field(TextEditingController controller, String label,
            {bool numeric = false}) =>
        TextField(
          controller: controller,
          keyboardType: numeric ? TextInputType.number : TextInputType.text,
          inputFormatters:
              numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
        );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF4F9FD),
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _plateCtrl,
          keyboardType: TextInputType.number,
          maxLength: 8,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'מספר לוחית רישוי',
            counterText: '',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: field(_vehicleManufacturerCtrl, 'יצרן')),
          const SizedBox(width: 10),
          Expanded(child: field(_vehicleModelCtrl, 'דגם')),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: field(_vehicleYearCtrl, 'שנת ייצור', numeric: true)),
          const SizedBox(width: 10),
          Expanded(
              child: field(_vehicleMileageCtrl, 'קילומטראז׳', numeric: true)),
          const SizedBox(width: 10),
          Expanded(child: field(_vehicleHandCtrl, 'יד', numeric: true)),
        ]),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          value: _vehicleTransmission,
          decoration: const InputDecoration(
              labelText: 'תיבת הילוכים', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 'automatic', child: Text('אוטומטית')),
            DropdownMenuItem(value: 'manual', child: Text('ידנית')),
            DropdownMenuItem(value: 'robotic', child: Text('רובוטית')),
            DropdownMenuItem(value: 'other', child: Text('אחרת')),
          ],
          onChanged: (value) =>
              setState(() => _vehicleTransmission = value ?? 'automatic'),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: field(_vehicleFuelCtrl, 'סוג דלק')),
          const SizedBox(width: 10),
          Expanded(child: field(_vehicleColorCtrl, 'צבע')),
        ]),
        const SizedBox(height: 10),
        field(_vehicleTestCtrl, 'תוקף מבחן רישוי (טסט)'),
      ]),
    );
  }

  @override
  void initState() {
    super.initState();
    _titleCtrl.addListener(_mirrorTitleIntoDescription);
    _loadDetail();
  }

  void _mirrorTitleIntoDescription() {
    final title = _titleCtrl.text.trim();
    final current = _descCtrl.text;
    String? updated;
    if (_mirroredTitle.isEmpty && current.trim().isEmpty) {
      updated = title;
    } else if (current.trim() == _mirroredTitle) {
      updated = title;
    } else if (_mirroredTitle.isNotEmpty &&
        current.startsWith('$_mirroredTitle\n\n')) {
      final remainder = current.substring(_mirroredTitle.length + 2);
      updated = title.isEmpty ? remainder : '$title\n\n$remainder';
    }
    _mirroredTitle = title;
    if (updated != null && updated != current) {
      _descCtrl.value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: updated.length),
      );
    }
  }

  @override
  void dispose() {
    _titleCtrl.removeListener(_mirrorTitleIntoDescription);
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _cityCtrl.dispose();
    _quantityCtrl.dispose();
    _pickupCtrl.dispose();
    _plateCtrl.dispose();
    _vehicleManufacturerCtrl.dispose();
    _vehicleModelCtrl.dispose();
    _vehicleYearCtrl.dispose();
    _vehicleMileageCtrl.dispose();
    _vehicleHandCtrl.dispose();
    _vehicleFuelCtrl.dispose();
    _vehicleColorCtrl.dispose();
    _vehicleTestCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDetail() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/listings/${widget.listingId}'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      final item = jsonDecode(res.body) as Map<String, dynamic>;
      final imgs = List<String>.from(item['images'] ??
          (item['image_url'] != null ? [item['image_url']] : []));
      final vehicle = item['vehicle_details'] is Map
          ? Map<String, dynamic>.from(item['vehicle_details'] as Map)
          : <String, dynamic>{};
      setState(() {
        _category = item['category'] as String? ?? 'אחר';
        _titleCtrl.text = item['title'] as String? ?? '';
        _descCtrl.text = item['description'] as String? ?? '';
        _priceCtrl.text =
            item['price'] != null ? item['price'].toString() : '0';
        _cityCtrl.text = item['city'] as String? ?? '';
        _condition = item['item_condition']?.toString() ?? 'good';
        _negotiable = item['negotiable'] == true;
        _quantityCtrl.text = item['quantity']?.toString() ?? '1';
        _deliveryMethod = item['delivery_method']?.toString() ?? 'pickup';
        _pickupCtrl.text = item['pickup_details']?.toString() ?? '';
        _showPhone = item['contact_phone_visible'] == true;
        _plateCtrl.text = item['license_plate']?.toString() ?? '';
        _vehicleManufacturerCtrl.text =
            vehicle['manufacturer']?.toString() ?? '';
        _vehicleModelCtrl.text = vehicle['model']?.toString() ?? '';
        _vehicleYearCtrl.text = vehicle['year']?.toString() ?? '';
        _vehicleMileageCtrl.text = vehicle['mileage']?.toString() ?? '';
        _vehicleHandCtrl.text = vehicle['hand']?.toString() ?? '';
        _vehicleTransmission =
            vehicle['transmission']?.toString() ?? 'automatic';
        _vehicleFuelCtrl.text = vehicle['fuel']?.toString() ?? '';
        _vehicleColorCtrl.text = vehicle['color']?.toString() ?? '';
        _vehicleTestCtrl.text = vehicle['test_valid_until']?.toString() ?? '';
        for (int i = 0; i < 8; i++) {
          _imageUrls[i] = i < imgs.length ? imgs[i] : null;
          _imageOutcomes[i] =
              i < imgs.length ? _FileUploadOutcome.approved : null;
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickImage(int slot) async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(imageQuality: 80);
    if (picked.isEmpty || !mounted) return;
    final availableSlots = <int>[
      slot,
      for (var i = 0; i < _imageUrls.length; i++)
        if (i != slot && _imageUrls[i] == null) i,
    ];
    final selected = picked.take(availableSlots.length).toList();
    if (picked.length > availableSlots.length) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('ניתן לצרף עד 8 תמונות למודעה'),
      ));
    }
    setState(() {
      for (var i = 0; i < selected.length; i++) {
        _uploadingSlot[availableSlots[i]] = true;
      }
    });
    final completed = ValueNotifier<int>(0);
    try {
      final results = await _runImageUploadQueue(
        selected,
        (file) => _uploadFileRequest(
          file: file,
          fileName: file.name,
          token: widget.token,
          fields: const {'listingImage': 'true'},
        ),
        completed,
      );
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < results.length; i++) {
          final target = availableSlots[i];
          final result = results[i];
          final url = result.data['url']?.toString();
          _imageOutcomes[target] = result.outcome;
          _imageReasons[target] =
              result.data['reason']?.toString() ?? result.error;
          if (url != null && url.isNotEmpty) _imageUrls[target] = url;
        }
      });
      _showImageBatchSummary(context, results);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('שגיאה בהעלאת תמונה: $error')));
      }
    } finally {
      completed.dispose();
      if (mounted) {
        setState(() {
          for (var i = 0; i < selected.length; i++) {
            _uploadingSlot[availableSlots[i]] = false;
          }
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_titleCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('נדרשת כותרת')));
      return;
    }
    setState(() => _saving = true);
    try {
      final urls = <String>[];
      for (var i = 0; i < _imageUrls.length; i++) {
        if (_imageUrls[i] != null &&
            _imageOutcomes[i] == _FileUploadOutcome.approved) {
          urls.add(_imageUrls[i]!);
        }
      }
      final city = _cityCtrl.text.trim();
      final title = _titleCtrl.text.trim();
      final enteredDescription = _descCtrl.text.trim();
      final description = enteredDescription.startsWith(title)
          ? enteredDescription
          : '$title\n\n$enteredDescription';
      final parsedPrice = double.tryParse(_priceCtrl.text.trim()) ?? 0;
      final listingType = parsedPrice <= 0 ? 'free' : 'sale';
      final body = <String, dynamic>{
        'type': listingType,
        'title': title,
        'description': description,
        'category': _category,
        'item_condition': _condition,
        'negotiable': listingType == 'sale' && _negotiable,
        'quantity': int.tryParse(_quantityCtrl.text) ?? 1,
        'delivery_method': _deliveryMethod,
        'pickup_details': _pickupCtrl.text.trim(),
        'contact_phone_visible': _showPhone,
        'expires_in_days': _expiryDays,
        if (city.isNotEmpty) 'city': city,
        'image_urls': urls,
        'price': parsedPrice,
        if (_category == 'רכב' && _plateCtrl.text.trim().isNotEmpty)
          'license_plate': _plateCtrl.text.trim(),
        if (_category == 'רכב')
          'vehicle_details': {
            'manufacturer': _vehicleManufacturerCtrl.text.trim(),
            'model': _vehicleModelCtrl.text.trim(),
            'year': _vehicleYearCtrl.text.trim(),
            'mileage': _vehicleMileageCtrl.text.trim(),
            'hand': _vehicleHandCtrl.text.trim(),
            'transmission': _vehicleTransmission,
            'fuel': _vehicleFuelCtrl.text.trim(),
            'color': _vehicleColorCtrl.text.trim(),
            'test_valid_until': _vehicleTestCtrl.text.trim(),
          },
      };
      final res = await http.put(
        Uri.parse('$kApi/listings/${widget.listingId}'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json'
        },
        body: jsonEncode(body),
      );
      if (res.statusCode == 200 && mounted)
        Navigator.pop(context, true);
      else if (mounted) {
        final err = jsonDecode(res.body)['error'] ?? 'שגיאה';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kPrimary,
        title: const Text('עריכת מודעה', style: TextStyle(color: Colors.white)),
        leading: BackButton(color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('תמונות (עד 8, ללא אנשים)',
                            style: TextStyle(
                                fontSize: 13,
                                color: kSubtext,
                                fontWeight: FontWeight.w500)),
                        const SizedBox(height: 8),
                        _dynamicImagePicker(),
                        const SizedBox(height: 16),
                        TextField(
                            controller: _titleCtrl,
                            textDirection: TextDirection.rtl,
                            decoration: const InputDecoration(
                                labelText: 'כותרת המודעה *',
                                border: OutlineInputBorder())),
                        const SizedBox(height: 12),
                        TextField(
                            controller: _descCtrl,
                            textDirection: TextDirection.rtl,
                            maxLines: 3,
                            decoration: const InputDecoration(
                                labelText: 'תיאור',
                                border: OutlineInputBorder())),
                        const SizedBox(height: 12),
                        TextField(
                            controller: _priceCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: 'מחיר (₪) — 0 למסירה',
                                helperText: 'מחיר 0 יסווג את המודעה כמסירה',
                                border: OutlineInputBorder(),
                                prefixText: '₪ ')),
                        const SizedBox(height: 12),
                        InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'קטגוריה (לא ניתנת לשינוי)',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                          child: Text(_category,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600)),
                        ),
                        if (_category == 'רכב') ...[
                          const SizedBox(height: 12),
                          _editVehicleFields(),
                        ],
                        const SizedBox(height: 12),
                        _LocationAutocompleteField(
                          controller: _cityCtrl,
                          label: 'עיר או יישוב',
                        ),
                        if (_category != 'רכב') ...[
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: _condition,
                            decoration: const InputDecoration(
                              labelText: 'מצב המוצר',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(
                                  value: 'new', child: Text('חדש')),
                              DropdownMenuItem(
                                  value: 'like_new', child: Text('כמו חדש')),
                              DropdownMenuItem(
                                  value: 'good', child: Text('מצב טוב')),
                              DropdownMenuItem(
                                  value: 'fair', child: Text('מצב סביר')),
                              DropdownMenuItem(
                                  value: 'for_parts',
                                  child: Text('לתיקון / לחלקים')),
                            ],
                            onChanged: (value) =>
                                setState(() => _condition = value ?? 'good'),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _quantityCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'כמות',
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            value: _deliveryMethod,
                            decoration: const InputDecoration(
                              labelText: 'אופן קבלה',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(
                                  value: 'pickup', child: Text('איסוף עצמי')),
                              DropdownMenuItem(
                                  value: 'delivery', child: Text('משלוח')),
                              DropdownMenuItem(
                                  value: 'both',
                                  child: Text('איסוף עצמי או משלוח')),
                            ],
                            onChanged: (value) => setState(
                                () => _deliveryMethod = value ?? 'pickup'),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _pickupCtrl,
                            maxLines: 2,
                            textDirection: TextDirection.rtl,
                            decoration: const InputDecoration(
                              labelText: 'פרטי איסוף או משלוח',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ],
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('המחיר גמיש'),
                          value: _negotiable,
                          onChanged: (value) =>
                              setState(() => _negotiable = value),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('הצגת מספר הטלפון במודעה'),
                          value: _showPhone,
                          onChanged: (value) =>
                              setState(() => _showPhone = value),
                        ),
                        DropdownButtonFormField<int>(
                          value: _expiryDays,
                          decoration: const InputDecoration(
                            labelText: 'הארכת הפרסום ממועד השמירה',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(value: 7, child: Text('7 ימים')),
                            DropdownMenuItem(value: 14, child: Text('14 ימים')),
                            DropdownMenuItem(value: 30, child: Text('30 ימים')),
                            DropdownMenuItem(value: 60, child: Text('60 ימים')),
                          ],
                          onChanged: (value) =>
                              setState(() => _expiryDays = value ?? 30),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: kPrimary,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14)),
                          onPressed: _saving ? null : _submit,
                          child: _saving
                              ? const CircularProgressIndicator(
                                  color: Colors.white)
                              : const Text('שמור שינויים',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold)),
                        ),
                      ]),
                ),
              ),
            ),
    );
  }

  Widget _imageSlot(int i) {
    final url = _imageUrls[i];
    final uploading = _uploadingSlot[i];
    final outcome = _imageOutcomes[i];
    final rejected = outcome == _FileUploadOutcome.rejected ||
        outcome == _FileUploadOutcome.failed;
    final pending = outcome == _FileUploadOutcome.pending;
    return GestureDetector(
      onTap: uploading ? null : () => _pickImage(i),
      onLongPress: url != null ? () => _clearEditImage(i) : null,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFE8F4FD),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kBorder),
        ),
        child: uploading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : url != null
                ? Stack(fit: StackFit.expand, children: [
                    ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child:
                            _PersistentMediaImage(url: url, fit: BoxFit.cover)),
                    Positioned(
                        top: 3,
                        left: 3,
                        child: GestureDetector(
                            onTap: () => _clearEditImage(i),
                            child: Container(
                                width: 20,
                                height: 20,
                                decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle),
                                child: const Icon(Icons.close,
                                    size: 13, color: Colors.white)))),
                    Positioned(
                      right: 3,
                      bottom: 3,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: const BoxDecoration(
                            color: Colors.black54, shape: BoxShape.circle),
                        child: const Icon(Icons.edit,
                            size: 13, color: Colors.white),
                      ),
                    ),
                    if (rejected || pending)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            alignment: Alignment.bottomCenter,
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(9),
                              color: rejected
                                  ? const Color(0x66B91C1C)
                                  : const Color(0x556B7280),
                            ),
                            child: Text(
                              rejected
                                  ? 'לא אושרה\n${_imageReasons[i] ?? ''}'
                                  : 'ממתינה לסריקה',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                  ])
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                        Icon(Icons.add_photo_alternate_outlined,
                            size: 24, color: kPrimary),
                        if (i == 0)
                          Text('תמונה ראשית',
                              style: TextStyle(fontSize: 9, color: kSubtext),
                              textAlign: TextAlign.center),
                      ]),
      ),
    );
  }

  void _clearEditImage(int index) => setState(() {
        _imageUrls[index] = null;
        _imageOutcomes[index] = null;
        _imageReasons[index] = null;
      });

  Widget _dynamicImagePicker() {
    final occupied = <int>[
      for (var i = 0; i < 8; i++)
        if (_imageUrls[i] != null || _uploadingSlot[i]) i,
    ];
    int? firstFree;
    for (var i = 0; i < 8; i++) {
      if (_imageUrls[i] == null && !_uploadingSlot[i]) {
        firstFree = i;
        break;
      }
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final i in occupied)
          SizedBox(width: 150, height: 150, child: _imageSlot(i)),
        if (firstFree != null)
          SizedBox(
            width: 150,
            height: 150,
            child: OutlinedButton.icon(
              onPressed: () => _pickImage(firstFree!),
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text(occupied.isEmpty ? 'בחירת תמונות' : 'הוסף תמונות'),
            ),
          ),
      ],
    );
  }
}

// ── Listing Detail Screen ─────────────────────────────────────────
class _ListingDetailBadge extends StatelessWidget {
  final IconData icon;
  final String text;
  const _ListingDetailBadge({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFFE8F4FD),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 17, color: kPrimary),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 13)),
        ]),
      );
}

class ListingDetailScreen extends StatefulWidget {
  final Map<String, dynamic> item;
  final String token;
  final Map<String, dynamic>? me;
  final IO.Socket? socket;
  final bool embedded;
  final VoidCallback? onClose;
  final Future<void> Function()? onUpdated;
  final Future<void> Function(Map<String, dynamic> recipient)?
      onConversationStarted;
  const ListingDetailScreen(
      {super.key,
      required this.item,
      required this.token,
      required this.me,
      required this.socket,
      this.embedded = false,
      this.onClose,
      this.onUpdated,
      this.onConversationStarted});
  @override
  State<ListingDetailScreen> createState() => _ListingDetailScreenState();
}

class _ListingDetailScreenState extends State<ListingDetailScreen> {
  late String _status;

  @override
  void initState() {
    super.initState();
    _status = widget.item['status'] as String? ?? 'active';
  }

  List<String> get _images {
    final raw = widget.item['images'];
    if (raw is List && raw.isNotEmpty) return List<String>.from(raw);
    final single = widget.item['image_url'] as String?;
    return single != null ? [single] : [];
  }

  Future<void> _openImageViewer(List<String> images, int initialIndex) async {
    final controller = PageController(initialPage: initialIndex);
    var currentIndex = initialIndex;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setViewerState) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: SafeArea(
            child: Stack(children: [
              PageView.builder(
                controller: controller,
                itemCount: images.length,
                onPageChanged: (index) =>
                    setViewerState(() => currentIndex = index),
                itemBuilder: (_, index) => InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: Center(
                    child: _PersistentMediaImage(
                      url: images[index],
                      fit: BoxFit.contain,
                      loadingBuilder: (_) => const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                      errorBuilder: (_) => const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white70,
                        size: 72,
                      ),
                    ),
                  ),
                ),
              ),
              PositionedDirectional(
                top: 12,
                start: 12,
                child: IconButton.filled(
                  tooltip: 'סגור',
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close, color: Colors.white),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                  ),
                ),
              ),
              PositionedDirectional(
                top: 18,
                end: 18,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    '${currentIndex + 1} / ${images.length}',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
              if (images.length > 1 && currentIndex > 0)
                Positioned(
                  left: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: IconButton.filled(
                      tooltip: 'התמונה הקודמת',
                      onPressed: () => controller.previousPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      ),
                      icon: const Icon(Icons.chevron_left,
                          color: Colors.white, size: 34),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                      ),
                    ),
                  ),
                ),
              if (images.length > 1 && currentIndex < images.length - 1)
                Positioned(
                  right: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: IconButton.filled(
                      tooltip: 'התמונה הבאה',
                      onPressed: () => controller.nextPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      ),
                      icon: const Icon(Icons.chevron_right,
                          color: Colors.white, size: 34),
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
    controller.dispose();
  }

  String _listingDefaultMessage() {
    final title = (widget.item['title'] ?? '').toString().trim();
    final id = (widget.item['id'] ?? '').toString().trim();
    final link = id.isNotEmpty ? '\nbetshuva://listing/$id' : '';
    if (title.isNotEmpty) {
      return 'שלום, ראיתי את המודעה שלך על "$title". זה עדיין זמין?$link';
    }
    return 'שלום, המודעה עדיין זמינה?$link';
  }

  void _openChat() {
    final recipient = <String, dynamic>{
      'id': widget.item['seller_id'],
      'name': widget.item['seller_name'],
      'profile_pic_url': widget.item['seller_pic']
    };
    Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            token: widget.token,
            recipient: recipient,
            me: widget.me,
            socket: widget.socket,
            initialText: _listingDefaultMessage(),
            listingId: widget.item['id']?.toString(),
            onMessageSent: () {
              final callback = widget.onConversationStarted;
              Navigator.of(context).popUntil((route) => route.isFirst);
              callback?.call(recipient);
            },
          ),
        ));
  }

  Future<void> _openEdit() async {
    final updated = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => EditListingScreen(
          listingId: widget.item['id'] as String,
          token: widget.token,
        ),
      ),
    );
    if (updated == true && mounted) {
      if (widget.embedded) {
        await widget.onUpdated?.call();
      } else {
        Navigator.pop(context, true);
      }
    }
  }

  Future<void> _setStatus(String newStatus) async {
    final label = newStatus == 'sold' ? 'נמכר' : 'נמסר';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('סמן כ$label?'),
        content: Text('לשנות את סטטוס המודעה ל"$label"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
            onPressed: () => Navigator.pop(context, true),
            child:
                Text('כן, $label', style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final res = await http.put(
      Uri.parse('$kApi/listings/${widget.item['id']}/status'),
      headers: {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json'
      },
      body: jsonEncode({'status': newStatus}),
    );
    if (res.statusCode == 200 && mounted) {
      setState(() => _status = newStatus);
      await widget.onUpdated?.call();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('המודעה סומנה כ$label')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFree = widget.item['type'] == 'free';
    final isOwner = widget.me?['id'] == widget.item['seller_id'];
    final images = _images.take(8).toList(growable: false);
    const conditionLabels = {
      'new': 'חדש',
      'like_new': 'כמו חדש',
      'good': 'מצב טוב',
      'fair': 'מצב סביר',
      'for_parts': 'לתיקון / לחלקים',
    };
    const deliveryLabels = {
      'pickup': 'איסוף עצמי',
      'delivery': 'משלוח',
      'both': 'איסוף עצמי או משלוח',
    };
    final vehicleDetails = widget.item['vehicle_details'] is Map
        ? Map<String, dynamic>.from(widget.item['vehicle_details'] as Map)
        : <String, dynamic>{};
    final galleryHeight =
        (MediaQuery.sizeOf(context).width * 0.56).clamp(280.0, 520.0);
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: kPrimary,
        title: Text(widget.item['title'] ?? '',
            style: const TextStyle(color: Colors.white)),
        leading: BackButton(
          color: Colors.white,
          onPressed: widget.onClose ?? () => Navigator.pop(context),
        ),
        actions: [
          if (!isOwner)
            IconButton(
              tooltip: 'דיווח על המודעה',
              icon: const Icon(Icons.flag_outlined, color: Colors.white),
              onPressed: () => _showReportDialog(
                context: context,
                token: widget.token,
                targetType: 'listing',
                targetId: widget.item['id']?.toString() ?? '',
                targetLabel: 'המודעה',
              ),
            ),
          if (isOwner)
            TextButton.icon(
              onPressed: _openEdit,
              icon: const Icon(Icons.edit_outlined, color: Colors.white),
              label: const Text('ערוך', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: SingleChildScrollView(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (images.isNotEmpty)
            images.length == 1
                ? SizedBox(
                    height: galleryHeight,
                    child: InkWell(
                      onTap: () => _openImageViewer(images, 0),
                      child: _PersistentMediaImage(
                        url: images.first,
                        width: double.infinity,
                        height: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_) =>
                            Container(color: const Color(0xFFE8F4FD)),
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final galleryWidth =
                          math.min(constraints.maxWidth - 16, 1050.0);
                      final tileWidth = (galleryWidth - 17) / 4;
                      final rows = (images.length / 4).ceil();
                      return Align(
                        alignment: Alignment.topRight,
                        child: SizedBox(
                          width: galleryWidth,
                          child: Container(
                            margin: const EdgeInsets.fromLTRB(8, 8, 8, 2),
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: kBorder),
                            ),
                            child: SizedBox(
                              height: rows * tileWidth + (rows - 1) * 3,
                              child: GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                padding: EdgeInsets.zero,
                                itemCount: images.length,
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 4,
                                  crossAxisSpacing: 3,
                                  mainAxisSpacing: 3,
                                ),
                                itemBuilder: (_, i) => Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(9),
                                    onTap: () => _openImageViewer(images, i),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(9),
                                      child: _PersistentMediaImage(
                                        url: images[i],
                                        width: double.infinity,
                                        height: double.infinity,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_) => Container(
                                            color: const Color(0xFFE8F4FD),
                                            child: Icon(
                                                Icons.broken_image_outlined,
                                                color: kSubtext)),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  )
          else
            Container(
                height: galleryHeight,
                color: const Color(0xFFE8F4FD),
                child: Icon(Icons.image_outlined, size: 80, color: kSubtext)),
          Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isFree
                        ? const Color(0xFFD1FAE5)
                        : const Color(0xFFEDE9FE),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                      isFree
                          ? 'חינם'
                          : '₪${widget.item['price']?.toStringAsFixed(0) ?? ''}',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: isFree
                              ? const Color(0xFF065F46)
                              : const Color(0xFF5B21B6))),
                ),
                const Spacer(),
                if (widget.item['city'] != null)
                  Row(children: [
                    Icon(Icons.location_on_outlined, size: 16, color: kSubtext),
                    Text(widget.item['city'],
                        style: TextStyle(color: kSubtext)),
                  ]),
              ]),
              const SizedBox(height: 12),
              Text(widget.item['title'] ?? '',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold)),
              if (widget.item['description'] != null &&
                  widget.item['description'].toString().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(widget.item['description'],
                    style:
                        TextStyle(fontSize: 15, color: kTextDark, height: 1.6)),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ListingDetailBadge(
                    icon: Icons.verified_outlined,
                    text: conditionLabels[widget.item['item_condition']] ??
                        'מצב טוב',
                  ),
                  _ListingDetailBadge(
                    icon: Icons.inventory_2_outlined,
                    text: 'כמות: ${widget.item['quantity'] ?? 1}',
                  ),
                  _ListingDetailBadge(
                    icon: Icons.local_shipping_outlined,
                    text: deliveryLabels[widget.item['delivery_method']] ??
                        'איסוף עצמי',
                  ),
                  if (!isFree && widget.item['negotiable'] == true)
                    const _ListingDetailBadge(
                      icon: Icons.handshake_outlined,
                      text: 'מחיר גמיש',
                    ),
                  if (_listingPublishedAt(widget.item['created_at']).isNotEmpty)
                    _ListingDetailBadge(
                      icon: Icons.calendar_today_outlined,
                      text: _listingPublishedAt(widget.item['created_at']),
                    ),
                ],
              ),
              if (widget.item['category'] == 'רכב' &&
                  (vehicleDetails.isNotEmpty ||
                      (widget.item['license_plate'] ?? '')
                          .toString()
                          .isNotEmpty)) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F9FD),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: kBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(children: [
                        Icon(Icons.directions_car_outlined, color: kPrimary),
                        SizedBox(width: 8),
                        Text('פרטי הרכב',
                            style: TextStyle(
                                fontSize: 17, fontWeight: FontWeight.bold)),
                      ]),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if ((widget.item['license_plate'] ?? '')
                              .toString()
                              .isNotEmpty)
                            _ListingDetailBadge(
                                icon: Icons.pin_outlined,
                                text:
                                    'מספר רישוי: ${widget.item['license_plate']}'),
                          for (final entry in const {
                            'manufacturer': 'יצרן',
                            'model': 'דגם',
                            'year': 'שנת ייצור',
                            'mileage': 'קילומטראז׳',
                            'hand': 'יד',
                            'fuel': 'דלק',
                            'color': 'צבע',
                            'test_valid_until': 'טסט עד',
                          }.entries)
                            if ((vehicleDetails[entry.key] ?? '')
                                .toString()
                                .trim()
                                .isNotEmpty)
                              _ListingDetailBadge(
                                  icon: Icons.check_circle_outline,
                                  text:
                                      '${entry.value}: ${vehicleDetails[entry.key]}'),
                          if ((vehicleDetails['transmission'] ?? '')
                              .toString()
                              .isNotEmpty)
                            _ListingDetailBadge(
                              icon: Icons.settings_outlined,
                              text: 'תיבה: ${{
                                    'automatic': 'אוטומטית',
                                    'manual': 'ידנית',
                                    'robotic': 'רובוטית',
                                    'other': 'אחרת'
                                  }[vehicleDetails['transmission']] ?? vehicleDetails['transmission']}',
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              if ((widget.item['pickup_details'] ?? '')
                  .toString()
                  .trim()
                  .isNotEmpty) ...[
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.info_outline, color: kPrimary),
                  title: const Text('פרטי איסוף או משלוח'),
                  subtitle: Text(widget.item['pickup_details'].toString()),
                ),
              ],
              if ((widget.item['seller_phone'] ?? '')
                  .toString()
                  .trim()
                  .isNotEmpty) ...[
                const SizedBox(height: 6),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.phone_outlined, color: kPrimary),
                  title: const Text('טלפון ליצירת קשר'),
                  subtitle: Text(widget.item['seller_phone'].toString()),
                ),
              ],
              const SizedBox(height: 20),
              // Seller info
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  CircleAvatar(
                      radius: 24,
                      backgroundColor: kBorder,
                      backgroundImage: widget.item['seller_pic'] != null
                          ? NetworkImage(widget.item['seller_pic'])
                          : null,
                      child: widget.item['seller_pic'] == null
                          ? Text((widget.item['seller_name'] ?? '?')[0],
                              style: TextStyle(
                                  color: kPrimary, fontWeight: FontWeight.bold))
                          : null),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(widget.item['seller_name'] ?? '',
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 15)),
                        Text('המפרסם',
                            style: TextStyle(color: kSubtext, fontSize: 13)),
                      ])),
                ]),
              ),
              const SizedBox(height: 20),
              if (isOwner) ...[
                OutlinedButton.icon(
                  onPressed: _openEdit,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('ערוך מודעה'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 46),
                  ),
                ),
                const SizedBox(height: 10),
                if (_status != 'active')
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: _status == 'sold'
                          ? const Color(0xFFEDE9FE)
                          : const Color(0xFFD1FAE5),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _status == 'sold' ? 'נמכר / נמסר' : 'פג תוקף',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: _status == 'sold'
                              ? const Color(0xFF5B21B6)
                              : const Color(0xFF065F46)),
                    ),
                  )
                else
                  Row(children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD1FAE5),
                          foregroundColor: const Color(0xFF065F46),
                          minimumSize: const Size(0, 46),
                          elevation: 0,
                        ),
                        onPressed: () => _setStatus('sold'),
                        icon: const Icon(Icons.check_circle_outline, size: 18),
                        label: const Text('נמסר / נמכר',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ]),
              ] else
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: kPrimary,
                      minimumSize: const Size(double.infinity, 50)),
                  onPressed: _openChat,
                  icon: const Icon(Icons.chat_bubble_outline,
                      color: Colors.white),
                  label: const Text('שלח הודעה למפרסם',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold)),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── Conversations Screen ──────────────────────────────────────────
class ConversationsScreen extends StatefulWidget {
  final List<Map<String, dynamic>> users;
  final String token;
  final Map<String, dynamic>? me;
  final IO.Socket? socket;
  final Map<String, int> unreadCounts;
  final Map<String, int> groupUnreadCounts;
  final Map<String, String> groupTypingNames;
  final Set<String> typingUserIds;
  final void Function(String userId) onChatOpened;
  final void Function(Map<String, dynamic> user)? onUserSelected;
  final String? selectedUserId;
  final String? selectedGroupId;
  final void Function(Map<String, dynamic> group, bool openMembers)?
      onGroupSelected;
  final Future<void> Function() onLogout;
  final VoidCallback onSettings;
  final Future<void> Function() onContactsChanged;
  final void Function(Map<String, dynamic> user) onVoiceCall;

  const ConversationsScreen({
    super.key,
    required this.users,
    required this.token,
    required this.me,
    required this.socket,
    required this.unreadCounts,
    required this.groupUnreadCounts,
    required this.groupTypingNames,
    required this.typingUserIds,
    required this.onChatOpened,
    required this.onLogout,
    required this.onSettings,
    required this.onContactsChanged,
    required this.onVoiceCall,
    this.onUserSelected,
    this.selectedUserId,
    this.selectedGroupId,
    this.onGroupSelected,
  });

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  int _tab = 0;
  static const _tabs = ['כל השיחות', 'לא נקרא', 'קבוצות'];
  List<Map<String, dynamic>> _groups = [];
  bool _groupsLoaded = false;
  bool _searching = false;
  String _searchQuery = '';
  late final void Function(dynamic) _groupInvitedHandler;
  late final void Function(dynamic) _groupDeletedHandler;
  late final void Function(dynamic) _groupMessageHandler;

  DateTime _lastMessageTime(Map<String, dynamic> item) =>
      DateTime.tryParse(item['last_message_at']?.toString() ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _togglePin(String type, Map<String, dynamic> item) async {
    final pinned = item['pinned_at'] == null;
    try {
      final response = await http.put(
        Uri.parse('$kApi/pins/$type/${item['id']}'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'pinned': pinned}),
      );
      if (response.statusCode == 200 && mounted) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() => item['pinned_at'] = body['pinned_at']);
        if (type == 'group') {
          await _loadGroups(force: true);
        } else {
          await widget.onContactsChanged();
        }
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _loadGroups();
    _groupInvitedHandler = (data) {
      if (!mounted) return;
      _loadGroups(force: true);
      final groupName = data is Map ? data['groupName'] : null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
          groupName == null ? 'נוספת לקבוצה חדשה' : 'נוספת לקבוצה "$groupName"',
        )),
      );
    };
    widget.socket?.on('group:invited', _groupInvitedHandler);
    _groupDeletedHandler = (data) {
      if (!mounted || data is! Map) return;
      final groupId = data['groupId']?.toString();
      if (groupId == null) return;
      setState(() =>
          _groups.removeWhere((group) => group['id']?.toString() == groupId));
    };
    widget.socket?.on('group:deleted', _groupDeletedHandler);
    _groupMessageHandler = (_) {
      if (mounted) _loadGroups(force: true);
    };
    widget.socket?.on('group:message', _groupMessageHandler);
  }

  @override
  void dispose() {
    widget.socket?.off('group:invited', _groupInvitedHandler);
    widget.socket?.off('group:deleted', _groupDeletedHandler);
    widget.socket?.off('group:message', _groupMessageHandler);
    super.dispose();
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('התנתקות'),
        content: const Text('האם ברצונך להתנתק מהחשבון?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('ביטול'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.logout),
            label: const Text('התנתק'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.onLogout();
  }

  Future<void> _showFindFriendDialog() async {
    String normalizeContactPhone(String value) {
      var digits = value.replaceAll(RegExp(r'\D'), '');
      if (digits.startsWith('972') && digits.length > 10) {
        digits = '0${digits.substring(3)}';
      }
      return digits;
    }

    final deviceResults = <Map<String, dynamic>>[];
    var contactsPermissionDenied = false;
    if (!kIsWeb) {
      try {
        final granted = await FlutterContacts.requestPermission(readonly: true);
        contactsPermissionDenied = !granted;
        if (granted) {
          final contacts =
              await FlutterContacts.getContacts(withProperties: true);
          final localContacts = <Map<String, dynamic>>[];
          final phones = <String>[];
          final emails = <String>[];
          for (final contact in contacts) {
            final phone = contact.phones.isEmpty
                ? ''
                : normalizeContactPhone(contact.phones.first.number);
            final email = contact.emails.isEmpty
                ? ''
                : contact.emails.first.address.trim().toLowerCase();
            if (phone.isEmpty && email.isEmpty) continue;
            localContacts.add({
              'name': contact.displayName.trim().isEmpty
                  ? phone.isNotEmpty
                      ? phone
                      : email
                  : contact.displayName.trim(),
              'phone': phone,
              'email': email,
            });
            if (phone.isNotEmpty) phones.add(phone);
            if (email.contains('@')) emails.add(email);
          }
          var matched = <Map<String, dynamic>>[];
          if (phones.isNotEmpty || emails.isNotEmpty) {
            final response = await http.post(
              Uri.parse('$kApi/contacts/match'),
              headers: {
                'Authorization': 'Bearer ${widget.token}',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'phones': phones, 'emails': emails}),
            );
            if (response.statusCode == 200) {
              matched = (jsonDecode(response.body) as List)
                  .cast<Map<String, dynamic>>();
            }
          }
          final matchedPhones = matched
              .map((u) => normalizeContactPhone((u['phone'] ?? '').toString()))
              .where((value) => value.isNotEmpty)
              .toSet();
          final matchedEmails = matched
              .map((u) => (u['email'] ?? '').toString().trim().toLowerCase())
              .where((value) => value.isNotEmpty)
              .toSet();
          for (final local in localContacts) {
            Map<String, dynamic>? appUser;
            for (final candidate in matched) {
              final candidatePhone = (candidate['phone'] ?? '').toString();
              final candidateEmail =
                  (candidate['email'] ?? '').toString().trim().toLowerCase();
              if ((local['phone'].toString().isNotEmpty &&
                      normalizeContactPhone(candidatePhone) ==
                          local['phone']) ||
                  (local['email'].toString().isNotEmpty &&
                      candidateEmail == local['email'])) {
                appUser = Map<String, dynamic>.from(candidate);
                break;
              }
            }
            if (appUser != null) {
              appUser['device_name'] = local['name'];
              appUser['saved'] = false;
              if (!deviceResults.any((u) => u['id'] == appUser!['id'])) {
                deviceResults.add(appUser);
              }
            } else if (!matchedPhones.contains(local['phone']) &&
                !matchedEmails.contains(local['email'])) {
              deviceResults.add({...local, 'device_only': true});
            }
          }
        }
      } catch (_) {
        contactsPermissionDenied = true;
      }
    }
    if (!mounted) return;
    final directoryResults = <Map<String, dynamic>>[];

    List<Map<String, dynamic>> mergeAndSort(
      Iterable<Map<String, dynamic>> primary,
      Iterable<Map<String, dynamic>> secondary,
    ) {
      final merged = <Map<String, dynamic>>[];
      for (final item in [...primary, ...secondary]) {
        final key = item['id']?.toString() ??
            '${item['phone'] ?? ''}|${item['email'] ?? ''}';
        if (!merged.any((existing) =>
            (existing['id']?.toString() ??
                '${existing['phone'] ?? ''}|${existing['email'] ?? ''}') ==
            key)) {
          merged.add(item);
        }
      }
      merged.sort((a, b) {
        final aName = (a['device_name'] ?? a['name'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        final bName = (b['device_name'] ?? b['name'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        return aName.compareTo(bName);
      });
      return merged;
    }

    var initialResults = mergeAndSort(deviceResults, directoryResults);
    final searchController = TextEditingController();
    Timer? searchDebounce;
    var results = List<Map<String, dynamic>>.from(initialResults);
    var loading = false;
    var directoryLoading = true;
    var directoryLoadStarted = false;
    String? error;
    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (!directoryLoadStarted) {
            directoryLoadStarted = true;
            Future<void>(() async {
              try {
                final response = await http.get(
                  Uri.parse('$kApi/users/directory'),
                  headers: {'Authorization': 'Bearer ${widget.token}'},
                );
                if (response.statusCode == 200) {
                  directoryResults
                    ..clear()
                    ..addAll((jsonDecode(response.body) as List)
                        .cast<Map<String, dynamic>>());
                }
              } catch (_) {
                // Search remains available even if the initial directory
                // cannot be loaded.
              }
              if (!dialogContext.mounted) return;
              setDialogState(() {
                directoryLoading = false;
                initialResults = mergeAndSort(deviceResults, directoryResults);
                if (searchController.text.trim().isEmpty) {
                  results = List<Map<String, dynamic>>.from(initialResults);
                }
              });
            });
          }

          Future<void> search() async {
            final query = searchController.text.trim();
            if (query.isEmpty) {
              setDialogState(() {
                results = List<Map<String, dynamic>>.from(initialResults);
                error = null;
              });
              return;
            }
            setDialogState(() {
              loading = true;
              error = null;
            });
            try {
              final response = await http.get(
                Uri.parse('$kApi/users/search')
                    .replace(queryParameters: {'q': query}),
                headers: {'Authorization': 'Bearer ${widget.token}'},
              );
              if (!dialogContext.mounted) return;
              final serverResults = response.statusCode == 200
                  ? (jsonDecode(response.body) as List)
                      .cast<Map<String, dynamic>>()
                  : <Map<String, dynamic>>[];
              final lowerQuery = query.toLowerCase();
              final localMatches = deviceResults.where((item) {
                final haystack = [
                  item['name'],
                  item['device_name'],
                  item['phone'],
                  item['email'],
                ].whereType<Object>().join(' ').toLowerCase();
                return haystack.contains(lowerQuery);
              });
              final merged = mergeAndSort(localMatches, serverResults);
              setDialogState(() {
                loading = false;
                results = merged;
                if (results.isEmpty) error = 'לא נמצאו משתמשים';
              });
            } catch (_) {
              if (dialogContext.mounted) {
                setDialogState(() {
                  loading = false;
                  error = 'שגיאה בחיפוש';
                });
              }
            }
          }

          Future<void> save(Map<String, dynamic> user) async {
            final response = await http.post(
              Uri.parse('$kApi/contacts/save/${user['id']}'),
              headers: {'Authorization': 'Bearer ${widget.token}'},
            );
            if (response.statusCode == 200) {
              await widget.onContactsChanged();
              if (!dialogContext.mounted) return;
              setDialogState(() => user['saved'] = true);
            }
          }

          Future<void> invite(Map<String, dynamic> contact) async {
            final email = (contact['email'] ?? '').toString();
            final phone = (contact['phone'] ?? '').toString();
            final delivery = await _chooseInviteDelivery(
              dialogContext,
              hasPhone: phone.trim().isNotEmpty,
              hasEmail: email.contains('@'),
            );
            if (delivery == null) return;
            var message = 'הצטרף אליי לאפליקציית בתשובה: $_appInviteUrl';
            if (delivery != 'system_sms') {
              try {
                final prepareResponse = await http.post(
                  Uri.parse('$kApi/invites/prepare'),
                  headers: {
                    'Authorization': 'Bearer ${widget.token}',
                    'Content-Type': 'application/json',
                  },
                  body: jsonEncode({'phone': phone, 'email': email}),
                );
                if (prepareResponse.statusCode != 200) {
                  if (!dialogContext.mounted) return;
                  var reason = 'לא ניתן להכין את ההזמנה';
                  try {
                    reason = (jsonDecode(prepareResponse.body)
                            as Map<String, dynamic>)['error']
                        .toString();
                  } catch (_) {}
                  ScaffoldMessenger.of(dialogContext)
                      .showSnackBar(SnackBar(content: Text(reason)));
                  return;
                }
                message = (jsonDecode(prepareResponse.body)
                            as Map<String, dynamic>)['message']
                        ?.toString() ??
                    message;
              } catch (_) {
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('לא ניתן להכין את ההזמנה')),
                );
                return;
              }
            }
            if (delivery == 'whatsapp') {
              final opened = await _openWhatsApp(phone, message);
              if (!opened) {
                await Clipboard.setData(ClipboardData(text: message));
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('לא ניתן לפתוח את WhatsApp. ההודעה הועתקה.'),
                  ),
                );
              }
              return;
            }
            if (delivery == 'device_sms') {
              await launchUrl(_deviceSmsUri(phone, message),
                  mode: LaunchMode.externalApplication);
              return;
            }
            if (delivery == 'email') {
              await launchUrl(
                Uri(
                  scheme: 'mailto',
                  path: email,
                  queryParameters: {
                    'subject': 'הזמנה לבתשובה',
                    'body': message,
                  },
                ),
                mode: LaunchMode.externalApplication,
              );
              return;
            }
            if (delivery == 'system_sms') {
              final response = await http.post(
                Uri.parse('$kApi/invites/send'),
                headers: {
                  'Authorization': 'Bearer ${widget.token}',
                  'Content-Type': 'application/json',
                },
                body: jsonEncode({'phone': phone}),
              );
              if (!dialogContext.mounted) return;
              ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(
                content: Text(response.statusCode == 200
                    ? 'ההזמנה נשלחה ב־SMS'
                    : 'שליחת ה־SMS נכשלה'),
              ));
            }
          }

          final media = MediaQuery.of(dialogContext);
          final availableHeight =
              media.size.height - media.viewInsets.bottom - 48;
          final contentHeight = math.max(
            220.0,
            math.min(520.0, availableHeight - 150),
          );
          return AlertDialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
            contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            title: const Text('חיפוש ושמירת חבר'),
            content: SizedBox(
              width: math.min(520, media.size.width - 56),
              height: contentHeight,
              child: Column(
                children: [
                  TextField(
                    controller: searchController,
                    autofocus: true,
                    textDirection: TextDirection.rtl,
                    decoration: InputDecoration(
                      hintText: 'שם, מספר טלפון או אימייל',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: search,
                      ),
                    ),
                    onChanged: (_) {
                      searchDebounce?.cancel();
                      searchDebounce = Timer(
                          const Duration(milliseconds: 300), () => search());
                    },
                    onSubmitted: (_) => search(),
                  ),
                  const SizedBox(height: 12),
                  if (directoryLoading && !loading)
                    const LinearProgressIndicator(minHeight: 2),
                  if (contactsPermissionDenied && !kIsWeb)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'כדי להציג אנשי קשר יש לאשר הרשאת אנשי קשר בהגדרות הטלפון',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.orange),
                      ),
                    ),
                  if (loading) const CircularProgressIndicator(),
                  if (error != null && !loading)
                    Text(error!, style: const TextStyle(color: kSubtext)),
                  if (!loading && results.isNotEmpty)
                    Expanded(
                      child: Scrollbar(
                        thumbVisibility: true,
                        child: ListView.builder(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: results.length,
                          itemBuilder: (_, index) {
                            final user = results[index];
                            final deviceOnly = user['device_only'] == true;
                            final saved = user['saved'] == true;
                            return ListTile(
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              horizontalTitleGap: 10,
                              leading: UserAvatar(
                                picUrl: user['profile_pic_url'] as String?,
                                name: user['name'] as String? ?? '',
                              ),
                              title: Text((user['device_name'] ?? user['name'])
                                  .toString()),
                              subtitle: Text(
                                (user['phone'] as String?)?.isNotEmpty == true
                                    ? user['phone'] as String
                                    : user['email'] as String? ?? '',
                              ),
                              trailing: deviceOnly
                                  ? TextButton(
                                      onPressed: () => invite(user),
                                      child: const Text('הזמן'),
                                    )
                                  : saved
                                      ? const Icon(Icons.check_circle,
                                          color: Colors.green)
                                      : TextButton(
                                          onPressed: () => save(user),
                                          child: const Text('שמור'),
                                        ),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('סגור'),
              ),
            ],
          );
        },
      ),
    );
    searchDebounce?.cancel();
    searchController.dispose();
  }

  Future<void> _loadGroups({bool force = false}) async {
    if (_groupsLoaded && !force) return;
    try {
      final res = await http.get(Uri.parse('$kApi/groups'),
          headers: {'Authorization': 'Bearer ${widget.token}'});
      if (res.statusCode == 200 && mounted) {
        setState(() {
          _groups = (jsonDecode(res.body) as List).cast();
          _groupsLoaded = true;
        });
      }
    } catch (_) {}
  }

  Future<void> _createGroup() async {
    final nameCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('קבוצה חדשה'),
        content: TextField(
          controller: nameCtrl,
          textDirection: TextDirection.rtl,
          decoration: const InputDecoration(labelText: 'שם הקבוצה'),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('צור')),
        ],
      ),
    );
    if (confirmed != true || nameCtrl.text.trim().isEmpty) return;
    try {
      final res = await http.post(Uri.parse('$kApi/groups'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({'name': nameCtrl.text.trim()}));
      if (res.statusCode == 200 && mounted) {
        final g = jsonDecode(res.body) as Map<String, dynamic>;
        widget.socket?.emit('group:join', {'groupId': g['id']});
        await _loadGroups(force: true);
        if (!mounted) return;
        await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => ContentFilterSettingsScreen(
              token: widget.token,
              groupId: g['id']?.toString(),
              groupName: g['name'] as String?,
              requireSave: true,
            ),
          ),
        );
        if (!mounted) return;
        if (widget.onGroupSelected != null &&
            MediaQuery.sizeOf(context).width >= 900) {
          widget.onGroupSelected!(g, true);
        } else {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => GroupChatScreen(
                      group: g,
                      token: widget.token,
                      me: widget.me,
                      socket: widget.socket,
                      openAddMembersOnStart: true)));
        }
      } else if (mounted) {
        var error = 'לא ניתן ליצור את הקבוצה';
        try {
          error = (jsonDecode(res.body) as Map)['error']?.toString() ?? error;
        } catch (_) {}
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('שגיאת תקשורת ביצירת הקבוצה')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F6FC),
      appBar: AppBar(
        backgroundColor: kPrimary,
        elevation: 0,
        toolbarHeight: 72,
        titleSpacing: 16,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'בסיעתא דשמיא  •  ${fullHebrewDate(DateTime.now())}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.w400),
            ),
            const SizedBox(height: 4),
            if (_searching)
              TextField(
                autofocus: true,
                style: const TextStyle(color: kTextDark, fontSize: 14),
                cursorColor: kPrimary,
                textDirection: TextDirection.rtl,
                decoration: InputDecoration(
                  hintText: 'חיפוש שיחה או קבוצה...',
                  hintStyle: const TextStyle(color: kSubtext),
                  filled: true,
                  fillColor: Colors.white,
                  prefixIcon:
                      const Icon(Icons.search, color: kPrimary, size: 20),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (value) =>
                    setState(() => _searchQuery = value.trim().toLowerCase()),
              )
            else
              Row(
                children: [
                  if ((widget.me?['profile_pic_url'] as String?) != null)
                    UserAvatar(
                      radius: 17,
                      picUrl: widget.me?['profile_pic_url'] as String?,
                      name: widget.me?['name'] as String? ?? '',
                    )
                  else
                    _magenDavid(size: 34),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('בתשובה',
                              style: TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  height: 1.1)),
                          SizedBox(width: 7),
                          Text('תוכן יהודי נקי',
                              style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                  height: 1.1)),
                        ],
                      ),
                      Text(widget.me?['name'] as String? ?? '',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w300,
                              color: Colors.white70,
                              letterSpacing: 0.5)),
                    ],
                  ),
                ],
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1, color: Colors.white),
            tooltip: 'חיפוש ושמירת חבר',
            onPressed: _showFindFriendDialog,
          ),
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search,
                color: Colors.white),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _searchQuery = '';
            }),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            tooltip: 'תפריט',
            onSelected: (value) {
              if (value == 'settings') widget.onSettings();
              if (value == 'logout') _confirmLogout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings_outlined),
                    SizedBox(width: 10),
                    Text('הגדרות'),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: Colors.red),
                    SizedBox(width: 10),
                    Text('התנתקות'),
                  ],
                ),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(38),
          child: Container(
            color: kHeader,
            child: Row(
              children: List.generate(_tabs.length, (i) {
                final active = _tab == i;
                return Expanded(
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _tab = i);
                      if (i == 2) _loadGroups();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: active ? Colors.white : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Text(
                        _tabs[i],
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400,
                          color: active
                              ? Colors.white
                              : Colors.white.withOpacity(0.6),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          // List
          if (_tab == 2) ...[
            // ── קבוצות tab ──
            Padding(
              padding: const EdgeInsets.all(12),
              child: ElevatedButton.icon(
                onPressed: _createGroup,
                icon: const Icon(Icons.group_add),
                label: const Text('צור קבוצה חדשה',
                    style: TextStyle(fontSize: 15)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: kPrimary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            Expanded(
              child: _groups
                      .where((g) => (g['name'] as String? ?? '')
                          .toLowerCase()
                          .contains(_searchQuery))
                      .isEmpty
                  ? const Center(
                      child: Text('אין קבוצות עדיין',
                          style: TextStyle(color: kSubtext)))
                  : ListView.separated(
                      itemCount: _groups
                          .where((g) => (g['name'] as String? ?? '')
                              .toLowerCase()
                              .contains(_searchQuery))
                          .length,
                      separatorBuilder: (_, __) => const Divider(
                          height: 1, color: Color(0xFFD4E9F7), indent: 76),
                      itemBuilder: (_, i) {
                        final g = _groups
                            .where((g) => (g['name'] as String? ?? '')
                                .toLowerCase()
                                .contains(_searchQuery))
                            .toList()[i];
                        final unread = widget.groupUnreadCounts[g['id']] ?? 0;
                        return ListTile(
                          selected: widget.selectedGroupId == g['id'],
                          selectedTileColor: const Color(0xFFE9EDEF),
                          leading: CircleAvatar(
                            backgroundColor: kPrimary,
                            child: const Icon(Icons.group, color: Colors.white),
                          ),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  g['name'] as String? ?? '',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              _AdminBadge(
                                adminName: g['role'] == 'admin'
                                    ? 'אתה'
                                    : g['admin_name'] as String?,
                              ),
                            ],
                          ),
                          subtitle: Text(
                            widget.groupTypingNames[g['id']] != null
                                ? '${widget.groupTypingNames[g['id']]} מקליד...'
                                : '${g['member_count'] ?? 0} חברים',
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.groupTypingNames[g['id']] != null
                                  ? const Color(0xFF16A34A)
                                  : kSubtext,
                              fontStyle:
                                  widget.groupTypingNames[g['id']] != null
                                      ? FontStyle.italic
                                      : FontStyle.normal,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: g['pinned_at'] == null
                                    ? 'הצמד קבוצה'
                                    : 'בטל הצמדה',
                                onPressed: () => _togglePin('group', g),
                                icon: Icon(
                                  g['pinned_at'] == null
                                      ? Icons.push_pin_outlined
                                      : Icons.push_pin,
                                  color: g['pinned_at'] == null
                                      ? kSubtext
                                      : kPrimary,
                                  size: 19,
                                ),
                              ),
                              if (unread > 0) _UnreadBadge(count: unread),
                            ],
                          ),
                          onTap: () {
                            widget.onGroupSelected?.call(g, false);
                            if (MediaQuery.sizeOf(context).width < 900) {
                              Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => GroupChatScreen(
                                          group: g,
                                          token: widget.token,
                                          me: widget.me,
                                          socket: widget.socket)));
                            }
                          },
                        );
                      },
                    ),
            ),
          ] else ...[
            Expanded(
              child: widget.users.isEmpty && (_tab != 0 || _groups.isEmpty)
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 74,
                              height: 74,
                              decoration: const BoxDecoration(
                                color: Color(0xFFE0F0FB),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.person_add_alt_1,
                                  size: 36, color: kPrimary),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _tab == 1
                                  ? 'אין הודעות שלא נקראו'
                                  : 'רשימת החברים שלך ריקה',
                              style: const TextStyle(
                                  color: kTextDark,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600),
                            ),
                            if (_tab != 1) ...[
                              const SizedBox(height: 7),
                              const Text(
                                'חפש משתמש לפי מספר טלפון או אימייל ושמור אותו כחבר',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: kSubtext, fontSize: 13),
                              ),
                              const SizedBox(height: 18),
                              ElevatedButton.icon(
                                onPressed: _showFindFriendDialog,
                                icon: const Icon(Icons.person_search),
                                label: const Text('חיפוש והוספת חבר'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: kPrimary,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 24, vertical: 13),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : Builder(builder: (context) {
                      final visibleUsers = _tab == 1
                          ? widget.users
                              .where((u) =>
                                  (widget.unreadCounts[u['id']] ?? 0) > 0)
                              .toList()
                          : widget.users;
                      final searchedUsers = visibleUsers
                          .where((u) => (u['name'] as String? ?? '')
                              .toLowerCase()
                              .contains(_searchQuery))
                          .toList();
                      final showGroups = _tab == 0
                          ? _groups
                              .where((g) => (g['name'] as String? ?? '')
                                  .toLowerCase()
                                  .contains(_searchQuery))
                              .toList()
                          : <Map<String, dynamic>>[];
                      final conversationItems = <Map<String, dynamic>>[
                        ...showGroups.map((group) => {
                              'isGroup': true,
                              'data': group,
                            }),
                        ...searchedUsers.map((user) => {
                              'isGroup': false,
                              'data': user,
                            }),
                      ]..sort((a, b) {
                          final aData = a['data'] as Map<String, dynamic>;
                          final bData = b['data'] as Map<String, dynamic>;
                          final aPinned = aData['pinned_at'] != null;
                          final bPinned = bData['pinned_at'] != null;
                          if (aPinned != bPinned) return aPinned ? -1 : 1;
                          if (aPinned && bPinned) {
                            final pinOrder = DateTime.tryParse(
                                        bData['pinned_at']?.toString() ?? '')
                                    ?.compareTo(DateTime.tryParse(
                                            aData['pinned_at']?.toString() ??
                                                '') ??
                                        DateTime.fromMillisecondsSinceEpoch(
                                            0)) ??
                                0;
                            if (pinOrder != 0) return pinOrder;
                          }
                          final aScanBot =
                              a['isGroup'] != true && aData['id'] == kScanBotId;
                          final bScanBot =
                              b['isGroup'] != true && bData['id'] == kScanBotId;
                          if (aScanBot != bScanBot) return aScanBot ? -1 : 1;
                          return _lastMessageTime(bData)
                              .compareTo(_lastMessageTime(aData));
                        });
                      if (searchedUsers.isEmpty && showGroups.isEmpty) {
                        return const Center(
                          child: Text('אין הודעות שלא נקראו',
                              style: TextStyle(color: kSubtext, fontSize: 15)),
                        );
                      }
                      return ListView.separated(
                        itemCount: conversationItems.length,
                        separatorBuilder: (_, __) => const Divider(
                            height: 1, color: Color(0xFFD4E9F7), indent: 76),
                        itemBuilder: (_, i) {
                          final item = conversationItems[i];
                          if (item['isGroup'] == true) {
                            final group = item['data'] as Map<String, dynamic>;
                            final unread =
                                widget.groupUnreadCounts[group['id']] ?? 0;
                            final lastMessage = _conversationPreview(group);
                            final previewIcon = _conversationPreviewIcon(group);
                            final lastMessageIsMine =
                                group['last_message_is_mine'] == true;
                            final lastSender =
                                group['last_message_sender_name'] as String? ??
                                    '';
                            final groupPreview = lastMessage.isEmpty
                                ? '${group['member_count'] ?? 0} חברים'
                                : '${lastMessageIsMine ? 'את/ה' : lastSender}: $lastMessage';
                            final typingName =
                                widget.groupTypingNames[group['id']];
                            return ListTile(
                              selected: widget.selectedGroupId == group['id'],
                              selectedTileColor: const Color(0xFFE9EDEF),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 6),
                              leading: UserAvatar(
                                radius: 24,
                                picUrl: group['profile_pic_url'] as String?,
                                name: group['name'] as String? ?? 'קבוצה',
                              ),
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      group['name'] as String? ?? '',
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _AdminBadge(
                                    adminName: group['role'] == 'admin'
                                        ? 'אתה'
                                        : group['admin_name'] as String?,
                                  ),
                                ],
                              ),
                              subtitle: Row(
                                children: [
                                  if (typingName == null &&
                                      lastMessageIsMine &&
                                      lastMessage.isNotEmpty) ...[
                                    const Icon(Icons.done,
                                        size: 15, color: kPrimaryMid),
                                    const SizedBox(width: 4),
                                  ],
                                  if (typingName == null &&
                                      previewIcon != null) ...[
                                    Icon(previewIcon,
                                        size: 14, color: kSubtext),
                                    const SizedBox(width: 4),
                                  ],
                                  Expanded(
                                    child: Text(
                                      typingName != null
                                          ? '$typingName מקליד...'
                                          : groupPreview,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: typingName != null
                                              ? const Color(0xFF16A34A)
                                              : kSubtext,
                                          fontStyle: typingName != null
                                              ? FontStyle.italic
                                              : FontStyle.normal),
                                    ),
                                  ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: group['pinned_at'] == null
                                        ? 'הצמד קבוצה'
                                        : 'בטל הצמדה',
                                    onPressed: () => _togglePin('group', group),
                                    icon: Icon(
                                      group['pinned_at'] == null
                                          ? Icons.push_pin_outlined
                                          : Icons.push_pin,
                                      color: group['pinned_at'] == null
                                          ? kSubtext
                                          : kPrimary,
                                      size: 19,
                                    ),
                                  ),
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _conversationTime(
                                            group['last_message_at']),
                                        style: const TextStyle(
                                            fontSize: 11, color: kSubtext),
                                      ),
                                      if (unread > 0) ...[
                                        const SizedBox(height: 4),
                                        _UnreadBadge(count: unread),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () {
                                widget.onGroupSelected?.call(group, false);
                                if (MediaQuery.sizeOf(context).width < 900) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => GroupChatScreen(
                                        group: group,
                                        token: widget.token,
                                        me: widget.me,
                                        socket: widget.socket,
                                      ),
                                    ),
                                  );
                                }
                              },
                            );
                          }
                          final user = item['data'] as Map<String, dynamic>;
                          return _ConversationTile(
                            user: user,
                            pinned: user['pinned_at'] != null,
                            onPin: () => _togglePin('chat', user),
                            isTyping: widget.typingUserIds.contains(user['id']),
                            selected: widget.selectedUserId == user['id'],
                            unreadCount: widget.unreadCounts[user['id']] ?? 0,
                            onTap: () {
                              widget.onChatOpened(user['id'] as String);
                              if (widget.onUserSelected != null &&
                                  MediaQuery.sizeOf(context).width >= 900) {
                                widget.onUserSelected!(user);
                              } else {
                                Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => ChatScreen(
                                            token: widget.token,
                                            me: widget.me,
                                            recipient: user,
                                            socket: widget.socket,
                                            onVoiceCall: () =>
                                                widget.onVoiceCall(user))));
                              }
                            },
                          );
                        },
                      );
                    }),
            ),
          ]
        ],
      ),
    );
  }
}

String _conversationTime(dynamic raw) {
  final parsed = DateTime.tryParse(raw?.toString() ?? '')?.toLocal();
  if (parsed == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(parsed.year, parsed.month, parsed.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) {
    return '${parsed.hour.toString().padLeft(2, '0')}:'
        '${parsed.minute.toString().padLeft(2, '0')}';
  }
  if (difference == 1) return 'אתמול';
  return '${parsed.day.toString().padLeft(2, '0')}/'
      '${parsed.month.toString().padLeft(2, '0')}';
}

String _conversationPreview(Map<String, dynamic> item) {
  switch (item['last_message_type'] as String?) {
    case 'image':
      return 'תמונה';
    case 'document':
      return 'מסמך';
    case 'audio':
      return 'הודעה קולית';
    case 'video':
      return 'סרטון וידאו';
    default:
      return item['last_message'] as String? ?? '';
  }
}

IconData? _conversationPreviewIcon(Map<String, dynamic> item) {
  switch (item['last_message_type'] as String?) {
    case 'image':
      return Icons.image_outlined;
    case 'document':
      return Icons.insert_drive_file_outlined;
    case 'audio':
      return Icons.mic_none;
    case 'video':
      return Icons.videocam_outlined;
    default:
      return null;
  }
}

class _ConversationTile extends StatelessWidget {
  final Map<String, dynamic> user;
  final VoidCallback onTap;
  final int unreadCount;
  final bool selected;
  final bool isTyping;
  final bool pinned;
  final VoidCallback onPin;

  const _ConversationTile({
    required this.user,
    required this.onTap,
    required this.onPin,
    this.unreadCount = 0,
    this.selected = false,
    this.isTyping = false,
    this.pinned = false,
  });

  Widget _lastMessageStatus() {
    if (user['last_message_is_mine'] != true) {
      return const SizedBox.shrink();
    }
    switch (user['last_message_status'] as String?) {
      case 'read':
        return const Icon(Icons.done_all, size: 16, color: kReadTick);
      case 'delivered':
        return const Icon(Icons.done_all, size: 16, color: kPrimaryMid);
      default:
        return const Icon(Icons.done, size: 16, color: kPrimaryMid);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = user['name'] as String? ?? '';
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected
            ? const Color(0xFFE9EDEF)
            : (unreadCount > 0 ? const Color(0xFFF0F7FF) : Colors.white),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            user['id'] == kScanBotId
                ? Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color:
                          unreadCount > 0 ? kPrimary : const Color(0xFFC5DFF2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.document_scanner_outlined,
                        color: unreadCount > 0 ? Colors.white : kHeader,
                        size: 25),
                  )
                : UserAvatar(
                    picUrl: user['profile_pic_url'] as String?,
                    name: name,
                    radius: 24,
                  ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: kTextDark,
                                fontSize: 14,
                                fontWeight: unreadCount > 0
                                    ? FontWeight.w700
                                    : FontWeight.w600)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(children: [
                    if (!isTyping && user['last_message_is_mine'] == true) ...[
                      _lastMessageStatus(),
                      const SizedBox(width: 4),
                    ],
                    if (!isTyping &&
                        _conversationPreviewIcon(user) != null) ...[
                      Icon(_conversationPreviewIcon(user),
                          size: 14, color: kSubtext),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        isTyping
                            ? 'מקליד...'
                            : _conversationPreview(user).isNotEmpty
                                ? _conversationPreview(user)
                                : unreadCount > 0
                                    ? 'יש הודעות חדשות!'
                                    : user['id'] == kScanBotId
                                        ? 'שלח תמונה וקבל דוח סריקה מלא'
                                        : 'לחץ לפתיחת שיחה',
                        style: TextStyle(
                            fontSize: 12,
                            color: isTyping
                                ? const Color(0xFF16A34A)
                                : unreadCount > 0
                                    ? kPrimary
                                    : kSubtext,
                            fontStyle:
                                isTyping ? FontStyle.italic : FontStyle.normal,
                            fontWeight: unreadCount > 0 || isTyping
                                ? FontWeight.w600
                                : FontWeight.normal),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: pinned ? 'בטל הצמדה' : 'הצמד שיחה',
              onPressed: onPin,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(
                pinned ? Icons.push_pin : Icons.push_pin_outlined,
                size: 18,
                color: pinned ? kPrimary : kSubtext,
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _conversationTime(user['last_message_at']),
                  style: const TextStyle(fontSize: 11, color: kSubtext),
                ),
                if (unreadCount > 0) ...[
                  const SizedBox(height: 4),
                  _UnreadBadge(count: unreadCount),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 24,
        height: 24,
        child: Container(
          decoration: const BoxDecoration(
            color: kPrimaryMid,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            count > 99 ? '99+' : '$count',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
}

class _AdminBadge extends StatelessWidget {
  final String? adminName;
  const _AdminBadge({required this.adminName});

  @override
  Widget build(BuildContext context) {
    final message = adminName == null || adminName!.isEmpty
        ? 'מנהל הקבוצה'
        : 'מנהל הקבוצה: $adminName';
    return Tooltip(
      message: message,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 2),
          )),
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(
            Icons.admin_panel_settings_outlined,
            size: 19,
            color: Color(0xFF9A6500),
          ),
        ),
      ),
    );
  }
}

class _CompactMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _CompactMenuItem(this.icon, this.label, {this.color = kTextDark});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(fontSize: 13, color: color)),
        ],
      );
}

class _AllowedReceivingFilterIcons extends StatelessWidget {
  final Map<String, bool>? filter;
  final bool forGroup;

  const _AllowedReceivingFilterIcons(
      {required this.filter, this.forGroup = false});

  static const _items = <String, (IconData, String)>{
    'text': (Icons.chat_bubble_outline, 'מאפשרת לקבל הודעות טקסט'),
    'video': (Icons.videocam_outlined, 'מאפשרת לקבל סרטוני וידאו מסווגים'),
    'nonHumanImages': (
      Icons.landscape_outlined,
      'מאפשרת לקבל תמונות נוף או חפצים'
    ),
    'men': (Icons.man, 'מאפשרת לקבל תמונות גברים'),
    'women': (Icons.woman, 'מאפשרת לקבל תמונות נשים'),
    'children': (Icons.child_care, 'מאפשרת לקבל תמונות ילדים'),
  };

  @override
  Widget build(BuildContext context) {
    final allowed =
        _items.entries.where((entry) => filter?[entry.key] == true).toList();
    if (allowed.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: allowed
          .map((entry) => Tooltip(
                message: forGroup ? 'הקבוצה ${entry.value.$2}' : entry.value.$2,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 3),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.16),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white54, width: 0.7),
                    ),
                    alignment: Alignment.center,
                    child: Icon(entry.value.$1, size: 15, color: Colors.white),
                  ),
                ),
              ))
          .toList(),
    );
  }
}

// ── Chat Screen ───────────────────────────────────────────────────
class ChatScreen extends StatefulWidget {
  final String token;
  final Map<String, dynamic>? me;
  final Map<String, dynamic> recipient;
  final IO.Socket? socket;
  final String? initialText;
  final String? listingId;
  final VoidCallback? onMessageSent;
  final bool embedded;
  final VoidCallback? onClose;
  final VoidCallback? onVoiceCall;

  const ChatScreen({
    super.key,
    required this.token,
    required this.me,
    required this.recipient,
    required this.socket,
    this.initialText,
    this.listingId,
    this.onMessageSent,
    this.embedded = false,
    this.onClose,
    this.onVoiceCall,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<Map<String, dynamic>> _messages = [];
  final _msgCtrl = TextEditingController();
  final _msgFocusNode = FocusNode();
  late final ClipboardImagePasteListener _clipboardImagePasteListener;
  final _scrollCtrl = ScrollController();
  Map<String, dynamic>? _replyTo;
  Map<String, dynamic>? _editingMsg;
  bool _loading = true;
  bool _isTyping = false;
  late final void Function(dynamic) _chatTypingHandler;
  late final void Function(dynamic) _scanRejectedSocketHandler;
  late final void Function(dynamic) _messageRejectedSocketHandler;
  Timer? _messageRefreshTimer;
  String? _serverMessagesFingerprint;
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  String _voiceFileName = 'voice_message.webm';
  Map<String, bool>? _recipientReceivingFilter;

  @override
  void initState() {
    super.initState();
    _clipboardImagePasteListener = ClipboardImagePasteListener(
      focusNode: _msgFocusNode,
      onImage: (bytes, fileName, mimeType) => _uploadAndSend(
        XFile.fromData(bytes, name: fileName, mimeType: mimeType),
        fileName,
        'image',
        extraFields: const {'clipboardPaste': 'true'},
      ),
    );
    final prefill = (widget.initialText ?? '').trim();
    if (prefill.isNotEmpty) {
      _msgCtrl.text = prefill;
      _msgCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _msgCtrl.text.length),
      );
    }
    _loadMessages();
    _loadRecipientReceivingFilter();
    _setupSocket();
    // WebSocket delivery is best-effort (a browser can sleep or reconnect).
    // Quietly reconcile with the server so an incoming message can never stay
    // invisible until the user closes and reopens the conversation.
    _messageRefreshTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _loadMessages(silent: true),
    );
  }

  Future<void> _loadRecipientReceivingFilter() async {
    if (widget.recipient['id'] == kScanBotId) return;
    try {
      final response = await http.get(
        Uri.parse('$kApi/users/${widget.recipient['id']}/receiving-filter'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted || response.statusCode != 200) return;
      final body = jsonDecode(response.body);
      final raw = body is Map ? body['filter'] : null;
      if (raw is! Map) return;
      setState(() {
        _recipientReceivingFilter = raw.map(
          (key, value) => MapEntry(key.toString(), value == true),
        );
      });
    } catch (_) {}
  }

  Future<void> _loadMessages({bool silent = false}) async {
    final cacheKey = 'cache_msgs_${widget.me?['id']}_${widget.recipient['id']}';
    // Show cache immediately
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(cacheKey);
      if (!silent && cached != null && mounted) {
        final list = (jsonDecode(cached) as List).cast<Map<String, dynamic>>();
        setState(() {
          _messages
            ..clear()
            ..addAll(list);
          _loading = false;
        });
        _scrollToBottom();
      }
    } catch (_) {}
    // Fetch from server and update
    try {
      final res = await http.get(
        Uri.parse('$kApi/messages/${widget.recipient['id']}'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        final normalized = data.map(_normalizeDbMessage).toList();
        _persistRecentImageUrls(normalized).ignore();
        final fingerprint = jsonEncode(normalized);
        if (silent && fingerprint == _serverMessagesFingerprint) return;
        _serverMessagesFingerprint = fingerprint;
        setState(() {
          final pending = _messages
              .where((m) => (m['id'] as String? ?? '').startsWith('temp_'))
              .toList();
          _messages.clear();
          _messages.addAll(normalized);
          for (final p in pending) {
            final alreadySaved = p['fileUrl'] != null
                ? _messages.any((message) => message['fileUrl'] == p['fileUrl'])
                : _messages.any((message) => message['text'] == p['text']);
            if (!alreadySaved) {
              _messages.add(p);
            }
          }
          _loading = false;
        });
        _scrollToBottom();
        _markAsRead();
        // Save to cache (last 50 messages)
        final prefs = await SharedPreferences.getInstance();
        final toCache = normalized.length > 50
            ? normalized.sublist(normalized.length - 50)
            : normalized;
        await prefs.setString(cacheKey, jsonEncode(toCache));
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic> _normalizeDbMessage(dynamic m) {
    final map = m as Map<String, dynamic>;
    final msgType = _normalizeIncomingFileType(
          map['type'] as String?,
          fileUrl: map['file_url'] as String?,
          fileName: map['file_name'] as String?,
        ) ??
        'text';
    final isFile = (map['file_url'] != null) ||
        (msgType != 'text' && msgType != 'group_invite');
    return {
      'id': map['id'],
      'text': map['body'] ?? map['file_name'] ?? '',
      'from': map['sender_id'],
      'time': _formatTime(map['created_at']),
      'createdAt': map['created_at']?.toString(),
      'isUnread': map['sender_id'] != widget.me?['id'] &&
          map['is_read'] != true &&
          map['is_read'] != 1,
      'status': map['message_status'] == 'pending_scan'
          ? 'pending_scan'
          : map['message_status'] == 'rejected_scan'
              ? 'rejected_scan'
              : map['message_status'] == 'read'
                  ? 'read'
                  : map['message_status'] == 'delivered'
                      ? 'delivered'
                      : 'sent',
      if (map['scan_reason'] != null) 'scanReason': map['scan_reason'],
      if (map['image_classification'] != null)
        'classification': map['image_classification'],
      if (map['reply_to_id'] != null)
        'replyTo': {
          'id': map['reply_to_id'],
          'text': map['reply_body'] ?? '',
        },
      'isFile': isFile,
      'fileType': isFile ? msgType : null,
      'fileUrl': map['file_url'],
      'fileName': map['file_name'],
      'educationFormId': map['education_form_id'],
      'educationResponseStatus': map['education_response_status'],
      'isGroupInvite': msgType == 'group_invite',
      'meta': map['file_name'],
      'isEdited': map['is_edited'] == true || map['is_edited'] == 1,
    };
  }

  String _formatTime(dynamic raw) {
    if (raw == null) return '';
    final dt = DateTime.tryParse(raw.toString());
    if (dt == null) return '';
    final l = dt.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  void _setupSocket() {
    widget.socket?.on('chat:message', (data) {
      if (!mounted || data is! Map) return;
      final fileUrl = data['fileUrl'] as String?;
      final fileName = data['fileName'] as String?;
      final fromUserId = data['fromUserId'];
      final isIncoming = fromUserId == widget.recipient['id'];
      final pendingIndex = fileUrl == null
          ? -1
          : _messages.indexWhere((message) =>
              message['status'] == 'pending_scan' &&
              message['fileUrl'] == fileUrl);
      final isDelayedOutgoing =
          fromUserId == widget.me?['id'] && pendingIndex != -1;
      if (!isIncoming && !isDelayedOutgoing) return;
      final fileType = _normalizeIncomingFileType(
        data['fileType'] as String?,
        fileUrl: fileUrl,
        fileName: fileName,
      );
      final isFile =
          fileUrl != null || (fileType != null && fileType != 'text');
      final incoming = <String, dynamic>{
        'id': data['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        'text': data['text'] as String? ?? fileName ?? '',
        'from': isIncoming ? widget.recipient['id'] : widget.me?['id'],
        'time': data['createdAt'] != null
            ? _formatTime(data['createdAt'])
            : _nowTime(),
        'createdAt':
            data['createdAt']?.toString() ?? DateTime.now().toIso8601String(),
        'isUnread': false,
        'status': isIncoming ? 'received' : 'sent',
        'isFile': isFile,
        'fileType': fileType,
        'educationFormId': data['formId'],
        'educationResponseStatus': data['educationResponseStatus'],
        'fileUrl': fileUrl,
        'fileName': fileName,
        if (data['classification'] != null)
          'classification': data['classification'],
        if (data['replyToId'] != null)
          'replyTo': {'id': data['replyToId'], 'text': data['replyBody'] ?? ''},
      };
      setState(() {
        if (pendingIndex != -1) {
          _messages[pendingIndex] = incoming;
        } else if (!_messages
            .any((message) => message['id'] == incoming['id'])) {
          _messages.add(incoming);
        }
        _isTyping = false;
      });
      _scrollToBottom();
      if (isIncoming) _markAsRead();
    });

    _scanRejectedSocketHandler = (data) {
      if (!mounted || data is! Map) return;
      final fileUrl = data['fileUrl'] as String?;
      if (fileUrl == null) return;
      final index = _messages.indexWhere((message) =>
          message['status'] == 'pending_scan' && message['fileUrl'] == fileUrl);
      if (index == -1) return;
      setState(() {
        _messages[index]['status'] = 'rejected_scan';
        _messages[index]['scanReason'] =
            data['reason']?.toString() ?? 'נדחתה בסריקה';
      });
    };
    widget.socket?.on('scan:rejected', _scanRejectedSocketHandler);

    _messageRejectedSocketHandler = (data) {
      if (!mounted || data is! Map) return;
      final targetId = data['toUserId']?.toString();
      if (targetId != null && targetId != widget.recipient['id']?.toString()) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(data['reason']?.toString() ?? 'ההודעה נחסמה'),
        backgroundColor: Colors.red.shade700,
      ));
    };
    widget.socket?.on('message:rejected', _messageRejectedSocketHandler);

    _chatTypingHandler = (data) {
      if (data['fromUserId'] == widget.recipient['id'] && mounted) {
        setState(() => _isTyping = true);
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _isTyping = false);
        });
      }
    };
    widget.socket?.on('chat:typing', _chatTypingHandler);

    widget.socket?.on('messages:read', (_) {
      if (!mounted) return;
      setState(() {
        for (final msg in _messages) {
          if (msg['from'] == widget.me?['id']) msg['status'] = 'read';
        }
      });
    });

    widget.socket?.on('messages:delivered', (_) {
      if (!mounted) return;
      setState(() {
        for (final msg in _messages) {
          if (msg['from'] == widget.me?['id'] && msg['status'] != 'read') {
            msg['status'] = 'delivered';
          }
        }
      });
    });

    widget.socket?.on('message:delivered', (data) {
      if (!mounted) return;
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == data['id']);
        if (index != -1 && _messages[index]['status'] != 'read') {
          _messages[index]['status'] = 'delivered';
        }
      });
    });

    widget.socket?.on('message:deleted', (data) {
      if (!mounted) return;
      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == data['id']);
        if (idx != -1) {
          _messages[idx]['text'] = '🚫 הודעה נמחקה';
          _messages[idx]['isFile'] = false;
          _messages[idx]['fileUrl'] = null;
          _messages[idx]['fileName'] = null;
          _messages[idx]['fileType'] = 'text';
        }
      });
    });

    widget.socket?.on('message:edited', (data) {
      if (!mounted) return;
      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == data['id']);
        if (idx != -1) {
          _messages[idx]['text'] = data['body'] as String;
          _messages[idx]['isEdited'] = true;
        }
      });
    });
  }

  Future<void> _markAsRead() async {
    try {
      await http.put(
        Uri.parse('$kApi/messages/read'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'senderId': widget.recipient['id']}),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _clipboardImagePasteListener.dispose();
    _messageRefreshTimer?.cancel();
    _recordTimer?.cancel();
    _audioRecorder.dispose();
    widget.socket?.off('chat:message');
    widget.socket?.off('scan:rejected', _scanRejectedSocketHandler);
    widget.socket?.off('message:rejected', _messageRejectedSocketHandler);
    widget.socket?.off('chat:typing', _chatTypingHandler);
    widget.socket?.off('messages:read');
    widget.socket?.off('messages:delivered');
    widget.socket?.off('message:delivered');
    widget.socket?.off('message:deleted');
    widget.socket?.off('message:edited');
    _msgCtrl.dispose();
    _msgFocusNode.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  String _nowTime() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _toggleVoiceRecording() async {
    try {
      if (_isRecording) {
        _recordTimer?.cancel();
        final path = await _audioRecorder.stop();
        if (mounted) setState(() => _isRecording = false);
        if (path != null) {
          await _uploadAndSend(XFile(path), _voiceFileName, 'audio');
        }
        return;
      }
      if (!kIsWeb && !await _audioRecorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('יש לאפשר גישה למיקרופון')));
        }
        return;
      }
      final path = kIsWeb
          ? ''
          : '${(await getTemporaryDirectory()).path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';
      var encoder = AudioEncoder.wav;
      if (kIsWeb) {
        if (!await _audioRecorder.isEncoderSupported(AudioEncoder.wav)) {
          throw Exception('הדפדפן אינו תומך בהקלטת אודיו');
        }
      }
      _voiceFileName = 'voice_message.wav';
      await _audioRecorder.start(
          RecordConfig(
              encoder: encoder,
              numChannels: 1,
              sampleRate: 16000,
              bitRate: 32000),
          path: path);
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _recordSeconds = 0;
      });
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordSeconds++);
      });
    } catch (error) {
      if (mounted) {
        setState(() => _isRecording = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('לא ניתן להפעיל את המיקרופון: $error')));
      }
    }
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;

    // Edit mode
    if (_editingMsg != null) {
      final msgId = _editingMsg!['id'] as String;
      final oldText = _editingMsg!['text'] as String;
      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == msgId);
        if (idx != -1) {
          _messages[idx]['text'] = text;
          _messages[idx]['isEdited'] = true;
        }
        _editingMsg = null;
        _msgCtrl.clear();
      });
      try {
        final res = await http.patch(
          Uri.parse('$kApi/messages/$msgId'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({'body': text}),
        );
        if (res.statusCode != 200 && mounted) {
          setState(() {
            final idx = _messages.indexWhere((m) => m['id'] == msgId);
            if (idx != -1) {
              _messages[idx]['text'] = oldText;
              _messages[idx]['isEdited'] = false;
            }
          });
        }
      } catch (_) {}
      return;
    }

    // Normal send
    final replySnapshot = _replyTo;
    final tempId = 'temp_${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _messages.add({
        'id': tempId,
        'text': text,
        'from': widget.me?['id'],
        'time': _nowTime(),
        'createdAt': DateTime.now().toIso8601String(),
        'status': 'sent',
        if (replySnapshot != null)
          'replyTo': Map<String, dynamic>.from(replySnapshot),
      });
      _replyTo = null;
      _msgCtrl.clear();
    });
    // שליחה דרך HTTP — שומרת את ההודעה ב-DB ומעבירה ל-socket של הנמען
    // אם הוא מחובר, או שולחת push notification אחרת.
    // (בעבר השליחה הייתה רק דרך widget.socket?.emit — מה שגרם לאיבוד
    // הודעות כאשר המסך נפתח עם socket=null, למשל ממסך מודעה.)
    () async {
      try {
        final res = await http.post(
          Uri.parse('$kApi/messages'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'toUserId': widget.recipient['id'],
            'text': text,
            if (widget.listingId != null) 'listingId': widget.listingId,
            if (replySnapshot != null) 'replyToId': replySnapshot['id'],
          }),
        );
        if (!mounted) return;
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          if (data['requestPending'] == true) {
            setState(() => _messages.removeWhere((m) => m['id'] == tempId));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('נשלחה בקשת הודעה — ההודעה תימסר לאחר אישור')));
            return;
          }
          setState(() {
            final idx = _messages.indexWhere((m) => m['id'] == tempId);
            if (idx != -1) {
              _messages[idx]['id'] = data['id'];
              _messages[idx]['status'] = data['status'] ?? 'sent';
            }
          });
          if (widget.listingId != null && widget.onMessageSent != null) {
            widget.onMessageSent!.call();
            return;
          }
        } else {
          setState(() {
            final idx = _messages.indexWhere((m) => m['id'] == tempId);
            if (idx != -1) _messages[idx]['status'] = 'failed';
          });
          var error = 'שליחת ההודעה נכשלה';
          try {
            error = (jsonDecode(res.body)['error'] as String?) ?? error;
          } catch (_) {}
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(error),
            backgroundColor: res.statusCode == 422 ? Colors.red.shade700 : null,
          ));
        }
      } catch (_) {
        if (!mounted) return;
        setState(() {
          final idx = _messages.indexWhere((m) => m['id'] == tempId);
          if (idx != -1) _messages[idx]['status'] = 'failed';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('אין חיבור לשרת — ההודעה לא נשלחה')),
        );
      }
    }();
    _scrollToBottom();
  }

  void _showMessageOptions(Map<String, dynamic> msg, bool isMe) {
    final isText = msg['isFile'] != true && msg['isGroupInvite'] != true;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.reply, color: kPrimary),
              title: const Text('ענה'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _replyTo = msg);
              },
            ),
            ListTile(
              leading: const Icon(Icons.forward, color: kPrimary),
              title: const Text('העבר'),
              onTap: () {
                Navigator.pop(context);
                _forwardChatMessage(context, widget.token, widget.socket, msg);
              },
            ),
            if (msg['fileType'] == 'image' &&
                msg['fileUrl'] != null &&
                msg['status'] != 'pending_scan' &&
                msg['status'] != 'rejected_scan' &&
                msg['id']?.toString().startsWith('temp_') != true)
              ListTile(
                leading:
                    const Icon(Icons.account_circle_outlined, color: kPrimary),
                title: const Text('הגדר כתמונת פרופיל'),
                onTap: () {
                  Navigator.pop(context);
                  _setMessageImageAsProfile(
                      context, widget.token, msg, widget.me);
                },
              ),
            if (!isMe &&
                msg['id'] != null &&
                msg['id']?.toString().startsWith('temp_') != true)
              ListTile(
                leading: const Icon(Icons.flag_outlined, color: Colors.orange),
                title: const Text('דווח על ההודעה'),
                onTap: () {
                  Navigator.pop(context);
                  _showReportDialog(
                    context: context,
                    token: widget.token,
                    targetType: 'message',
                    targetId: msg['id'].toString(),
                    targetLabel: 'ההודעה',
                  );
                },
              ),
            if (isMe && isText)
              ListTile(
                leading: const Icon(Icons.edit_outlined, color: kPrimary),
                title: const Text('ערוך הודעה'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _editingMsg = msg;
                    _msgCtrl.text = msg['text'] as String? ?? '';
                  });
                },
              ),
            if (msg['id']?.toString().startsWith('temp_') != true)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('מחק אצלי'),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessage(msg, forEveryone: false);
                },
              ),
            if (isMe && msg['id']?.toString().startsWith('temp_') != true)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('מחק אצל כולם',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessage(msg, forEveryone: true);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMessage(Map<String, dynamic> message,
      {required bool forEveryone}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('מחיקת הודעה'),
        content: Text(forEveryone
            ? 'למחוק את ההודעה אצל כולם?'
            : 'למחוק את ההודעה רק אצלך?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('ביטול'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('מחק'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final response = await http.delete(
        Uri.parse('$kApi/messages/${message['id']}'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'forEveryone': forEveryone}),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() {
          if (forEveryone) {
            message['text'] = '🚫 הודעה נמחקה';
            message['isFile'] = false;
            message['fileUrl'] = null;
            message['fileName'] = null;
            message['fileType'] = 'text';
          } else {
            _messages.removeWhere((item) => item['id'] == message['id']);
          }
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('לא ניתן למחוק את ההודעה')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('שגיאת תקשורת במחיקת ההודעה')),
        );
      }
    }
  }

  void _onTyping() {
    widget.socket?.emit('chat:typing', {'toUserId': widget.recipient['id']});
  }

  void _scrollToBottom() {
    // עם reverse:true, הודעות חדשות נמצאות ב-minScrollExtent (ראש הרשימה הויזואלית)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.minScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openContactFilterSettings() {
    Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ContentFilterSettingsScreen(
            token: widget.token,
            contactId: widget.recipient['id']?.toString(),
            contactName: widget.recipient['name'] as String?,
          ),
        ));
  }

  void _showContactPhoto(String imageUrl, String name) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: Stack(alignment: Alignment.topRight, children: [
          GestureDetector(
            onTap: () => Navigator.pop(dialogContext),
            child: InteractiveViewer(
              minScale: .8,
              maxScale: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.network(
                  _absoluteMediaUrl(imageUrl),
                  fit: BoxFit.contain,
                  semanticLabel: 'תמונה של $name',
                  errorBuilder: (_, __, ___) => const SizedBox(
                    width: 280,
                    height: 280,
                    child: Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.white, size: 58),
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'סגור',
            onPressed: () => Navigator.pop(dialogContext),
            icon: const Icon(Icons.close, color: Colors.white, size: 30),
          ),
        ]),
      ),
    );
  }

  Future<void> _showContactDetails() async {
    final name = widget.recipient['name']?.toString() ?? 'איש קשר';
    final imageUrl = widget.recipient['profile_pic_url']?.toString();
    final phone = widget.recipient['phone']?.toString().trim() ?? '';
    final email = widget.recipient['email']?.toString().trim() ?? '';
    final city = widget.recipient['city']?.toString().trim() ?? '';
    const filterItems = <String, (String, IconData)>{
      'text': ('טקסט', Icons.text_fields),
      'nonHumanImages': ('תמונות נוף או חפצים', Icons.landscape_outlined),
      'men': ('תמונות גברים', Icons.man),
      'women': ('תמונות נשים', Icons.woman),
      'children': ('תמונות ילדים', Icons.child_care),
      'video': ('וידאו', Icons.videocam_outlined),
    };
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          alignment: Alignment.centerLeft,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.only(
              topRight: Radius.circular(22),
              bottomRight: Radius.circular(22),
            ),
          ),
          insetPadding: EdgeInsets.zero,
          contentPadding: const EdgeInsets.fromLTRB(22, 20, 22, 10),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: math.min(420, MediaQuery.sizeOf(context).width * .92),
              maxWidth: math.min(440, MediaQuery.sizeOf(context).width * .92),
              minHeight: MediaQuery.sizeOf(context).height - 70,
              maxHeight: MediaQuery.sizeOf(context).height - 70,
            ),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                GestureDetector(
                  onTap: imageUrl == null
                      ? null
                      : () => _showContactPhoto(imageUrl, name),
                  child: Stack(alignment: Alignment.bottomLeft, children: [
                    UserAvatar(picUrl: imageUrl, name: name, radius: 48),
                    if (imageUrl != null)
                      Container(
                        padding: const EdgeInsets.all(5),
                        decoration: const BoxDecoration(
                            color: kPrimary, shape: BoxShape.circle),
                        child: const Icon(Icons.zoom_in_rounded,
                            size: 17, color: Colors.white),
                      ),
                  ]),
                ),
                const SizedBox(height: 12),
                Text(name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                if (city.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(city,
                      style: const TextStyle(color: kSubtext, fontSize: 13)),
                ],
                const SizedBox(height: 16),
                if (phone.isNotEmpty)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.phone_outlined, color: kPrimary),
                    title: const Text('טלפון'),
                    subtitle: Text(phone, textDirection: TextDirection.ltr),
                    trailing: const Icon(Icons.call_outlined, color: kPrimary),
                    onTap: () => launchUrl(Uri.parse('tel:$phone')),
                  ),
                if (email.isNotEmpty)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.email_outlined, color: kPrimary),
                    title: const Text('אימייל'),
                    subtitle: Text(email, textDirection: TextDirection.ltr),
                    onTap: () => launchUrl(Uri.parse('mailto:$email')),
                  ),
                const Divider(),
                const Align(
                  alignment: Alignment.centerRight,
                  child: Text('סינון תוכן לאיש הקשר',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(height: 6),
                ...filterItems.entries.map((entry) {
                  final allowed = _recipientReceivingFilter?[entry.key] == true;
                  return ListTile(
                    dense: true,
                    leading: Icon(entry.value.$2,
                        color: allowed ? kPrimary : kSubtext),
                    title: Text(entry.value.$1),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: allowed
                            ? const Color(0xFFE5F3FC)
                            : const Color(0xFFF0F3F6),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(allowed ? 'מותר' : 'חסום',
                          style: TextStyle(
                              color: allowed ? kPrimary : kSubtext,
                              fontWeight: FontWeight.w700,
                              fontSize: 11)),
                    ),
                  );
                }),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.tune_rounded, color: kPrimary),
                  title: const Text('הגדרות סינון לאיש הקשר'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    _openContactFilterSettings();
                  },
                ),
                const Divider(),
                ListTile(
                  dense: true,
                  leading:
                      const Icon(Icons.flag_outlined, color: Colors.orange),
                  title: const Text('דיווח על איש הקשר'),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    _showReportDialog(
                      context: context,
                      token: widget.token,
                      targetType: 'user',
                      targetId: widget.recipient['id']?.toString() ?? '',
                      targetLabel: 'המשתמש $name',
                    );
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.block, color: Colors.red),
                  title: const Text('חסימת איש הקשר',
                      style: TextStyle(color: Colors.red)),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    _blockUser();
                  },
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('סגור'),
            ),
          ],
        ),
      ),
    );
  }

  void _showChatMenu() {
    final recipientName = widget.recipient['name'] as String? ?? '';
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.info_outline, color: kPrimary),
              title: const Text('פרטי איש הקשר'),
              subtitle: Text(recipientName),
              onTap: () {
                Navigator.pop(context);
                _showContactDetails();
              },
            ),
            ListTile(
              leading: const Icon(Icons.search, color: kPrimary),
              title: const Text('חיפוש בהודעות'),
              onTap: () {
                Navigator.pop(context);
                _searchInMessages();
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.notifications_off_outlined, color: kPrimary),
              title: const Text('השתקת התראות'),
              onTap: () async {
                Navigator.pop(context);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool(
                    'muted_chat_${widget.recipient['id']}', true);
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('ההתראות לשיחה הושתקו')),
                  );
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.thumb_down_alt_outlined,
                  color: Colors.orange),
              title: const Text('דיווח'),
              onTap: () {
                Navigator.pop(context);
                _showReportDialog(
                  context: context,
                  token: widget.token,
                  targetType: 'user',
                  targetId: widget.recipient['id']?.toString() ?? '',
                  targetLabel: 'המשתמש $recipientName',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.block, color: Colors.red),
              title: Text('חסום את $recipientName',
                  style: const TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _blockUser();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleChatMenuAction(String action) async {
    switch (action) {
      case 'info':
        if (!mounted) return;
        await _showContactDetails();
        break;
      case 'search':
        _searchInMessages();
        break;
      case 'mute':
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('muted_chat_${widget.recipient['id']}', true);
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('ההתראות לשיחה הושתקו')),
          );
        break;
      case 'report':
        if (mounted) {
          await _showReportDialog(
            context: context,
            token: widget.token,
            targetType: 'user',
            targetId: widget.recipient['id']?.toString() ?? '',
            targetLabel: 'המשתמש ${widget.recipient['name'] as String? ?? ''}',
          );
        }
        break;
      case 'block':
        _blockUser();
        break;
    }
  }

  Future<void> _searchInMessages() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final query = controller.text.trim().toLowerCase();
          final matches = query.isEmpty
              ? <Map<String, dynamic>>[]
              : _messages
                  .where((m) => (m['text'] as String? ?? '')
                      .toLowerCase()
                      .contains(query))
                  .toList();
          return AlertDialog(
            title: const Text('חיפוש בהודעות'),
            content: SizedBox(
              width: 420,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(
                    hintText: 'הקלד טקסט לחיפוש...',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: query.isEmpty
                      ? const Text('')
                      : matches.isEmpty
                          ? const Text('לא נמצאו הודעות')
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: matches.length,
                              itemBuilder: (_, i) => ListTile(
                                dense: true,
                                title:
                                    Text(matches[i]['text'] as String? ?? ''),
                                trailing:
                                    Text(matches[i]['time'] as String? ?? ''),
                              ),
                            ),
                ),
              ]),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('סגור'),
              )
            ],
          );
        },
      ),
    );
  }

  Future<void> _blockUser() async {
    final recipientName = widget.recipient['name'] as String? ?? 'משתמש זה';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('חסימת משתמש'),
        content: Text('לחסום את $recipientName?\nלא יוכל לשלוח לך הודעות.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('חסום'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await http.post(
        Uri.parse('$kApi/block/${widget.recipient['id']}'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {}
  }

  Future<void> _sharePhoneContact() async {
    final contact = await _pickPhoneContact(context);
    if (contact == null || !mounted) return;
    _msgCtrl.text = _sharedContactText(contact);
    await _send();
  }

  void _showAttachMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('שיתוף קובץ',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _AttachOption(
                  icon: Icons.image_outlined,
                  label: 'גלריה (עד 10)',
                  color: kPrimary,
                  onTap: () {
                    Navigator.pop(context);
                    _pickFile(ImageSource.gallery);
                  },
                ),
                _AttachOption(
                  icon: Icons.camera_alt_outlined,
                  label: 'צלם תמונה',
                  color: kPrimaryMid,
                  onTap: () {
                    Navigator.pop(context);
                    _capturePhoto();
                  },
                ),
                _AttachOption(
                  icon: Icons.picture_as_pdf_outlined,
                  label: 'מסמך',
                  color: Colors.orange,
                  onTap: () {
                    Navigator.pop(context);
                    _pickDocument();
                  },
                ),
                _AttachOption(
                  icon: Icons.videocam_outlined,
                  label: 'וידאו',
                  color: Colors.deepPurple,
                  onTap: () {
                    Navigator.pop(context);
                    _pickVideo();
                  },
                ),
                _AttachOption(
                  icon: Icons.video_camera_back_outlined,
                  label: 'צלם וידאו',
                  color: Colors.redAccent,
                  onTap: () {
                    Navigator.pop(context);
                    _recordVideo();
                  },
                ),
              ],
            ),
            const SizedBox(height: 14),
            _AttachOption(
              icon: Icons.contact_phone_outlined,
              label: 'שתף איש קשר',
              color: Colors.teal,
              onTap: () {
                Navigator.pop(context);
                _sharePhoneContact();
              },
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(children: [
                Icon(Icons.security_outlined,
                    color: Colors.blue.shade700, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('סרטונים עד 50MB עוברים סריקה לפני השליחה',
                      style: TextStyle(fontSize: 12, color: Colors.blue)),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showExpressions() async {
    final choice = await _showExpressionPicker(context, widget.token);
    if (choice == null || !mounted) return;
    if (choice.startsWith(_remoteExpressionPrefix)) {
      final remoteUrl = choice.substring(_remoteExpressionPrefix.length);
      try {
        final response = await http.get(Uri.parse(remoteUrl), headers: {
          'Authorization': 'Bearer ${widget.token}',
        });
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          throw Exception('הקובץ אינו זמין כרגע');
        }
        final extension =
            Uri.parse(remoteUrl).path.toLowerCase().endsWith('.gif')
                ? 'gif'
                : 'png';
        final fileName = 'betshuva_${Uri.parse(remoteUrl).pathSegments.last}';
        final file = XFile.fromData(response.bodyBytes,
            name: fileName, mimeType: 'image/$extension');
        await _uploadAndSend(file, fileName, 'image', extraFields: const {
          'builtinExpression': 'true',
        });
      } catch (error) {
        if (mounted) _showError('לא ניתן לשלוח את הביטוי: $error');
      }
      return;
    }
    if (choice.startsWith(_originalExpressionPrefix)) {
      final assetPath = choice.substring(_originalExpressionPrefix.length);
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();
      final extension = assetPath.endsWith('.gif') ? 'gif' : 'png';
      final fileName =
          'betshuva_${assetPath.split('/').last.replaceAll('.$extension', '')}.$extension';
      final file =
          XFile.fromData(bytes, name: fileName, mimeType: 'image/$extension');
      await _uploadAndSend(file, fileName, 'image', extraFields: const {
        'builtinExpression': 'true',
      });
      return;
    }
    if (choice == _gifPickerAction) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['gif'],
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      await _uploadAndSend(file.xFile, file.name, 'image');
      return;
    }
    if (choice == _sharedGifUploadAction) {
      final details = await _requestSharedGifDetails(context);
      if (details == null || !mounted) return;
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['gif'],
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      await _uploadAndSend(file.xFile, file.name, 'image', extraFields: {
        'sharedGif': 'true',
        'rightsConfirmed': 'true',
        'sharedGifTitle': details['title']!,
        'sharedGifTags': details['tags']!,
      });
      return;
    }
    if (choice == _personalStickerAction) {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 90,
      );
      if (picked != null) {
        await _uploadAndSend(picked, 'sticker_${picked.name}', 'image');
      }
      return;
    }
    if (choice.startsWith(_sharedGifPrefix)) {
      final gif = jsonDecode(utf8.decode(base64Url.decode(
              base64Url.normalize(choice.substring(_sharedGifPrefix.length)))))
          as Map<String, dynamic>;
      await _applyPrivateUploadResult(
        _FileUploadResult(_FileUploadOutcome.approved,
            data: {'url': gif['preview_url']}),
        gif['file_name'] as String? ?? '${gif['title']}.gif',
        'image',
      );
      http.post(Uri.parse('$kApi/gifs/${gif['id']}/use'),
          headers: {'Authorization': 'Bearer ${widget.token}'}).ignore();
      return;
    }
    if (choice.startsWith(_stickerPrefix)) {
      _msgCtrl.text = choice.substring(_stickerPrefix.length);
      await _send();
      return;
    }
    final selection = _msgCtrl.selection;
    final start = selection.isValid ? selection.start : _msgCtrl.text.length;
    final end = selection.isValid ? selection.end : _msgCtrl.text.length;
    final next = _msgCtrl.text.replaceRange(start, end, choice);
    _msgCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + choice.length),
    );
  }

  Future<void> _pickFile(ImageSource source) async {
    final picker = ImagePicker();
    if (source == ImageSource.gallery) {
      final picked = await picker.pickMultiImage(
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
        limit: _maxBatchImages,
      );
      if (picked.isEmpty) return;
      final selected = picked.take(_maxBatchImages).toList();
      if (picked.length > _maxBatchImages && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('ניתן להעלות עד 20 תמונות בכל פעם',
              textDirection: TextDirection.rtl),
        ));
      }
      await _uploadPrivateImageBatch(selected);
      return;
    }

    final picked = await picker.pickImage(
        source: source, maxWidth: 1920, maxHeight: 1920, imageQuality: 85);
    if (picked != null) await _uploadAndSend(picked, picked.name, 'image');
  }

  Future<void> _capturePhoto() async {
    final photo = kIsWeb
        ? await captureWebPhoto(context)
        : await ImagePicker().pickImage(
            source: ImageSource.camera,
            maxWidth: 1920,
            maxHeight: 1920,
            imageQuality: 85,
          );
    if (photo == null) return;
    await _uploadAndSend(photo, photo.name, 'image');
  }

  Future<void> _uploadPrivateImageBatch(List<XFile> files) async {
    if (!mounted || files.isEmpty) return;
    final completed = ValueNotifier<int>(0);
    var refreshScanBot = false;
    await _runImageUploadQueue(
      files,
      (file) => _uploadFileRequest(
        file: file,
        fileName: file.name,
        token: widget.token,
        fields: {
          'toUserId': widget.recipient['id'].toString(),
          if (kIsWeb) 'scanReport': 'true',
        },
      ),
      completed,
      onResult: (index, file, result) async {
        final needsRefresh = await _applyPrivateUploadResult(
          result,
          file.name,
          'image',
          showNotice: false,
          refreshScanBot: false,
        );
        if (needsRefresh) refreshScanBot = true;
      },
    );
    completed.dispose();
    if (!mounted) return;

    if (refreshScanBot) await _loadMessages(silent: true);
    if (!mounted) return;
  }

  Future<void> _pickDocument() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx'],
    );
    if (result == null) return;
    final f = result.files.single;
    await _uploadAndSend(f, f.name, 'document');
  }

  Future<void> _pickVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp4', 'webm', 'mov'],
      withData: kIsWeb,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    await _uploadAndSend(file.xFile, file.name, 'video');
  }

  Future<void> _recordVideo() async {
    final video = kIsWeb
        ? await captureWebVideo(context)
        : await ImagePicker().pickVideo(
            source: ImageSource.camera,
            maxDuration: const Duration(seconds: 30),
          );
    if (video == null) return;
    await _uploadAndSend(video, video.name, 'video');
  }

  Future<void> _uploadAndSend(dynamic file, String fileName, String fileType,
      {Map<String, String> extraFields = const {}}) async {
    if (!mounted) return;
    final isClipboardPaste = extraFields['clipboardPaste'] == 'true';
    final showProgress = fileType != 'image' || isClipboardPaste;
    final navigator =
        showProgress ? Navigator.of(context, rootNavigator: true) : null;
    final dialogFuture = showProgress
        ? showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => PopScope(
              canPop: false,
              child: AlertDialog(
                title: const Row(children: [
                  Icon(Icons.security, color: kPrimary),
                  SizedBox(width: 8),
                  Text('סריקה והעלאה'),
                ]),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(color: kPrimary),
                  const SizedBox(height: 16),
                  Text('$fileName\nעובר בדיקת תוכן לא ראוי והעלאה...'),
                ]),
              ),
            ),
          )
        : null;
    final result = await _uploadFileRequest(
      file: file,
      fileName: fileName,
      token: widget.token,
      fields: {
        'toUserId': widget.recipient['id'].toString(),
        if (kIsWeb) 'scanReport': 'true',
        ...extraFields,
      },
    );
    if (navigator != null && navigator.mounted && navigator.canPop()) {
      navigator.pop();
    }
    if (dialogFuture != null) await dialogFuture;
    if (!mounted) return;
    await _applyPrivateUploadResult(result, fileName, fileType,
        showNotice: fileType != 'image' || isClipboardPaste);
  }

  Future<bool> _applyPrivateUploadResult(
    _FileUploadResult result,
    String fileName,
    String fileType, {
    bool showNotice = true,
    bool refreshScanBot = true,
  }) async {
    final data = result.data;
    final fileUrl = data['url'] as String?;
    switch (result.outcome) {
      case _FileUploadOutcome.failed:
        setState(() {
          _messages.add({
            'id': _newUploadMessageId('failed_'),
            'text': fileName,
            'from': widget.me?['id'],
            'time': _nowTime(),
            'createdAt': DateTime.now().toIso8601String(),
            'status': 'failed',
            'isFile': true,
            'fileType': fileType,
            'fileName': fileName,
          });
        });
        _scrollToBottom();
        if (showNotice) _showError(result.error ?? 'שגיאה בהעלאה');
        return false;
      case _FileUploadOutcome.rejected:
        setState(() {
          final existingIndex = fileUrl == null
              ? -1
              : _messages
                  .indexWhere((message) => message['fileUrl'] == fileUrl);
          if (existingIndex != -1) {
            _messages[existingIndex]['status'] = 'rejected_scan';
            _messages[existingIndex]['scanReason'] = data['reason'];
          } else {
            _messages.add({
              'id': _newUploadMessageId('temp_'),
              'text': fileName,
              'from': widget.me?['id'],
              'time': _nowTime(),
              'createdAt': DateTime.now().toIso8601String(),
              'status': 'rejected_scan',
              'isFile': true,
              'fileType': fileType,
              'fileUrl': fileUrl,
              'fileName': fileName,
              if (data['classification'] != null)
                'classification': data['classification'],
              'scanReason': data['reason'],
            });
          }
        });
        _scrollToBottom();
        if (showNotice) {
          _showBlockedDialog(data['reason'] as String? ?? 'התמונה לא נשלחה');
        }
        return false;
      case _FileUploadOutcome.pending:
        setState(() {
          final existingIndex = fileUrl == null
              ? -1
              : _messages
                  .indexWhere((message) => message['fileUrl'] == fileUrl);
          if (existingIndex != -1) {
            _messages[existingIndex]['status'] = 'pending_scan';
          } else {
            _messages.add({
              'id': _newUploadMessageId('temp_'),
              'text': fileName,
              'from': widget.me?['id'],
              'time': _nowTime(),
              'createdAt': DateTime.now().toIso8601String(),
              'status': 'pending_scan',
              'isFile': true,
              'fileType': fileType,
              'fileUrl': fileUrl,
              'fileName': fileName,
              if (data['classification'] != null)
                'classification': data['classification'],
            });
          }
        });
        _scrollToBottom();
        if (showNotice) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'הקובץ בהמתנה לסריקה — יישלח אוטומטית כשהשירות יחזור',
                  textDirection: TextDirection.rtl),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        }
        return false;
      case _FileUploadOutcome.scanBot:
        if (refreshScanBot) await _loadMessages(silent: true);
        return true;
      case _FileUploadOutcome.approved:
        Map<String, dynamic> sendData = const <String, dynamic>{};
        try {
          final response = await http
              .post(
                Uri.parse('$kApi/messages'),
                headers: {
                  'Authorization': 'Bearer ${widget.token}',
                  'Content-Type': 'application/json',
                },
                body: jsonEncode({
                  'toUserId': widget.recipient['id'],
                  'fileUrl': fileUrl,
                  'fileName': fileName,
                  'fileType': fileType,
                }),
              )
              .timeout(const Duration(seconds: 30));
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map<String, dynamic>) sendData = decoded;
          } catch (_) {}
          if (response.statusCode != 200) {
            result.outcome = _FileUploadOutcome.failed;
            result.error =
                sendData['error']?.toString() ?? 'הקובץ הועלה אך לא נשלח';
            if (showNotice && mounted) _showError(result.error!);
            return false;
          }
          if (sendData['requestPending'] == true) {
            if (!mounted) return false;
            setState(() {
              _messages.add({
                'id': sendData['id'] ?? _newUploadMessageId('request_'),
                'text': fileName,
                'from': widget.me?['id'],
                'time': _nowTime(),
                'createdAt': DateTime.now().toIso8601String(),
                'status': 'awaiting_contact_approval',
                'isFile': true,
                'fileType': fileType,
                'fileUrl': fileUrl,
                'fileName': fileName,
              });
            });
            _scrollToBottom();
            if (showNotice) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('נשלחה בקשת חברות — הקובץ יימסר לאחר האישור'),
              ));
            }
            return false;
          }
        } catch (error) {
          result.outcome = _FileUploadOutcome.failed;
          result.error = 'הקובץ הועלה אך לא נשלח: $error';
          if (showNotice && mounted) _showError(result.error!);
          return false;
        }
        if (!mounted) return false;
        final messageId = sendData['id'] ?? _newUploadMessageId('temp_');
        setState(() {
          _messages.removeWhere((message) =>
              message['fileUrl'] == fileUrl &&
              message['status'] == 'pending_scan' &&
              message['id'] != messageId);
          if (!_messages.any((message) => message['id'] == messageId)) {
            _messages.add({
              'id': messageId,
              'text': fileName,
              'from': widget.me?['id'],
              'time': _nowTime(),
              'createdAt': sendData['createdAt']?.toString() ??
                  DateTime.now().toIso8601String(),
              'status': sendData['status'] ?? 'sent',
              'isFile': true,
              'fileType': fileType,
              'fileUrl': fileUrl,
              'fileName': fileName,
              if (data['classification'] != null)
                'classification': data['classification'],
            });
          }
        });
        _scrollToBottom();
        return false;
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    if (msg.contains('נחסמה')) {
      _showBlockedDialog(msg);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg, textDirection: TextDirection.rtl),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  void _showBlockedDialog(String reason) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFE8E8),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.shield,
                    size: 38, color: Color(0xFFB91C1C)),
              ),
              const SizedBox(height: 16),
              const Text(
                'התמונה נחסמה',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0D2137)),
              ),
              const SizedBox(height: 10),
              Text(
                reason,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14, color: Color(0xFF4B5563), height: 1.5),
              ),
              const SizedBox(height: 8),
              const Text(
                'אנא בחר תמונה אחרת',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Color(0xFF8AAFC9)),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(_),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('הבנתי',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recipientName = widget.recipient['name'] as String? ?? '';
    return Scaffold(
      backgroundColor: kChatBg,
      appBar: AppBar(
        backgroundColor: kPrimary,
        leading: BackButton(
            color: Colors.white,
            onPressed: widget.onClose ?? () => Navigator.pop(context)),
        leadingWidth: 40,
        title: Row(
          children: [
            Semantics(
              button: true,
              label: 'פתיחת פרטי איש הקשר',
              child: GestureDetector(
                onTap: _showContactDetails,
                child: Tooltip(
                  message: 'פרטי איש הקשר',
                  child: UserAvatar(
                    radius: 19,
                    picUrl: widget.recipient['profile_pic_url'] as String?,
                    name: recipientName,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(recipientName,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                    _AllowedReceivingFilterIcons(
                        filter: _recipientReceivingFilter),
                  ],
                ),
                Row(
                  children: [
                    const Icon(Icons.verified_user_outlined,
                        size: 10, color: Colors.white60),
                    const SizedBox(width: 3),
                    const Text('מסונן · מקוון',
                        style: TextStyle(fontSize: 11, color: Colors.white70)),
                  ],
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.phone_outlined, color: Colors.white),
            onPressed: widget.recipient['id'] == kScanBotId
                ? null
                : () {
                    if (widget.onVoiceCall != null) {
                      widget.onVoiceCall!();
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('יש לפתוח את השיחה מרשימת אנשי הקשר'),
                        ),
                      );
                    }
                  },
            tooltip: 'שיחת קול',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'אפשרויות שיחה',
            position: PopupMenuPosition.under,
            constraints: const BoxConstraints(minWidth: 210, maxWidth: 250),
            onSelected: _handleChatMenuAction,
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'info',
                  height: 40,
                  child: _CompactMenuItem(Icons.info_outline, 'פרטי איש הקשר')),
              PopupMenuItem(
                  value: 'search',
                  height: 40,
                  child: _CompactMenuItem(Icons.search, 'חיפוש בהודעות')),
              PopupMenuItem(
                  value: 'mute',
                  height: 40,
                  child: _CompactMenuItem(
                      Icons.notifications_off_outlined, 'השתקת התראות')),
              PopupMenuDivider(height: 8),
              PopupMenuItem(
                  value: 'report',
                  height: 40,
                  child:
                      _CompactMenuItem(Icons.thumb_down_alt_outlined, 'דיווח')),
              PopupMenuItem(
                  value: 'block',
                  height: 40,
                  child: _CompactMenuItem(Icons.block, 'חסימה',
                      color: Colors.red)),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Reply preview bar
          if (_replyTo != null)
            Container(
              color: kCard,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 36,
                    color: kPrimary,
                    margin: const EdgeInsets.only(left: 8),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('ציטוט',
                            style: TextStyle(
                                color: kPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                        Text(
                          _replyTo!['text'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: kSubtext),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _replyTo = null),
                  ),
                ],
              ),
            ),

          // Edit mode bar
          if (_editingMsg != null)
            Container(
              color: const Color(0xFFFFF8E1),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 36,
                    color: Colors.orange,
                    margin: const EdgeInsets.only(left: 8),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('עריכת הודעה',
                            style: TextStyle(
                                color: Colors.orange,
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                        Text(
                          _editingMsg!['text'] as String? ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: kSubtext),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() {
                      _editingMsg = null;
                      _msgCtrl.clear();
                    }),
                  ),
                ],
              ),
            ),

          // Messages list
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: kPrimary))
                : _messages.isEmpty
                    ? const Center(
                        child: Text('אין הודעות עדיין — שלח הודעה ראשונה!',
                            style: TextStyle(color: kSubtext)))
                    : ListView.builder(
                        controller: _scrollCtrl,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) {
                          final messageIndex = _messages.length - 1 - i;
                          final msg = _messages[messageIndex];
                          final isMe = msg['from'] == widget.me?['id'];
                          var imageRunStart = messageIndex;
                          var imageRunEnd = messageIndex;
                          if (_isGridImageMessage(msg)) {
                            while (imageRunStart > 0 &&
                                _isGridImageMessage(
                                    _messages[imageRunStart - 1]) &&
                                _sameImageSequenceSender(
                                    msg, _messages[imageRunStart - 1])) {
                              imageRunStart--;
                            }
                            while (imageRunEnd + 1 < _messages.length &&
                                _isGridImageMessage(
                                    _messages[imageRunEnd + 1]) &&
                                _sameImageSequenceSender(
                                    msg, _messages[imageRunEnd + 1])) {
                              imageRunEnd++;
                            }
                            if (imageRunStart != imageRunEnd &&
                                messageIndex != imageRunEnd) {
                              return const SizedBox.shrink();
                            }
                          }
                          final imageSequence = imageRunEnd > imageRunStart
                              ? _messages.sublist(
                                  imageRunStart, imageRunEnd + 1)
                              : const <Map<String, dynamic>>[];
                          final firstUnreadIndex = _messages.indexWhere(
                              (message) => message['isUnread'] == true);
                          final dateIndex = imageSequence.isNotEmpty
                              ? imageRunStart
                              : messageIndex;
                          final showDate = dateIndex == 0 ||
                              !_sameMessageDay(_messages[dateIndex],
                                  _messages[dateIndex - 1]);
                          return Column(
                            children: [
                              if (showDate)
                                _DateDivider(label: _messageDateLabel(msg)),
                              if (firstUnreadIndex >= imageRunStart &&
                                  firstUnreadIndex <= imageRunEnd)
                                const _UnreadMessagesDivider(),
                              if (msg['isGroupInvite'] == true && !isMe)
                                _GroupInviteCard(
                                  message: msg,
                                  token: widget.token,
                                  onJoined: () => setState(() {}),
                                )
                              else if (imageSequence.isNotEmpty)
                                _ConsecutiveImageGrid(
                                    messages: imageSequence,
                                    conversationMessages: _messages,
                                    isMe: isMe,
                                    onForwardAll: () => _forwardChatMessages(
                                        context,
                                        widget.token,
                                        widget.socket,
                                        imageSequence),
                                    onMessageOptions: (message) =>
                                        _showMessageOptions(
                                            message,
                                            message['from'] ==
                                                widget.me?['id']))
                              else
                                GestureDetector(
                                  onTap: !kIsWeb && msg['isFile'] != true
                                      ? () => _copyMessageText(context, msg)
                                      : null,
                                  onDoubleTap: kIsWeb && msg['isFile'] != true
                                      ? () => _copyMessageText(context, msg)
                                      : null,
                                  onLongPress: () =>
                                      _showMessageOptions(msg, isMe),
                                  child: _MessageBubble(
                                    message: msg,
                                    conversationMessages: _messages,
                                    isMe: isMe,
                                    token: widget.token,
                                    me: widget.me,
                                    onMessageOptions: (message) =>
                                        _showMessageOptions(
                                            message,
                                            message['from'] ==
                                                widget.me?['id']),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
          ),

          // Typing indicator
          if (_isTyping)
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.only(right: 12, left: 12, bottom: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 2),
                    _TypingDots(),
                  ],
                ),
              ),
            ),

          // Input bar
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0F6FC),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                          color: const Color(0xFFC5DFF2), width: 1.5),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 10),
                        const Icon(Icons.verified_user_outlined,
                            size: 16, color: kPrimary),
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: 'סמיילים ומדבקות של בתשובה',
                          icon: const Icon(Icons.emoji_emotions_outlined,
                              size: 19, color: kPrimary),
                          onPressed: _showExpressions,
                          padding: const EdgeInsets.all(8),
                          constraints: const BoxConstraints(),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _msgCtrl,
                            focusNode: _msgFocusNode,
                            textDirection: TextDirection.rtl,
                            maxLines: 4,
                            minLines: 1,
                            onChanged: (_) => _onTyping(),
                            decoration: InputDecoration(
                              hintText: 'כתוב הודעה...',
                              hintTextDirection: TextDirection.rtl,
                              hintStyle: const TextStyle(
                                  fontSize: 13, color: kSubtext),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 9),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                            style:
                                const TextStyle(fontSize: 13, color: kTextDark),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.attach_file,
                              size: 18, color: kSubtext),
                          onPressed: _showAttachMenu,
                          padding: const EdgeInsets.all(8),
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (_isRecording)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      'מקליט ${(_recordSeconds ~/ 60).toString().padLeft(2, '0')}:${(_recordSeconds % 60).toString().padLeft(2, '0')}',
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                IconButton(
                  tooltip: _isRecording ? 'סיים ושלח' : 'הקלט הודעה קולית',
                  onPressed: _toggleVoiceRecording,
                  icon: Icon(_isRecording ? Icons.stop_circle : Icons.mic,
                      color: _isRecording ? Colors.red : kPrimary),
                ),
                GestureDetector(
                  onTap: _send,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: kPrimary,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child:
                        const Icon(Icons.send, color: Colors.white, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final offset =
                math.sin((_ctrl.value * 2 * math.pi) - (i * 0.6)) * 3;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 6,
              height: 6,
              decoration:
                  const BoxDecoration(color: kSubtext, shape: BoxShape.circle),
              transform: Matrix4.translationValues(0, -offset, 0),
            );
          }),
        );
      },
    );
  }
}

class _DateDivider extends StatelessWidget {
  final String label;
  const _DateDivider({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kBorder),
          ),
          child: Text(label,
              style: const TextStyle(fontSize: 11, color: kSubtext)),
        ),
      ),
    );
  }
}

DateTime? _messageLocalDate(Map<String, dynamic> message) {
  final parsed = DateTime.tryParse(message['createdAt']?.toString() ?? '');
  return parsed?.toLocal();
}

bool _sameMessageDay(Map<String, dynamic> first, Map<String, dynamic> second) {
  final a = _messageLocalDate(first);
  final b = _messageLocalDate(second);
  return a != null &&
      b != null &&
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day;
}

String _messageDateLabel(Map<String, dynamic> message) {
  final date = _messageLocalDate(message);
  if (date == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(date.year, date.month, date.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) return 'היום';
  if (difference == 1) return 'אתמול';
  return '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';
}

class _UnreadMessagesDivider extends StatelessWidget {
  const _UnreadMessagesDivider();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          const Expanded(child: Divider(color: kPrimaryMid)),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFDCEEFF),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text('הודעות שלא נקראו',
                style: TextStyle(
                    color: kPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ),
          const Expanded(child: Divider(color: kPrimaryMid)),
        ]),
      );
}

class _GroupInviteCard extends StatefulWidget {
  final Map<String, dynamic> message;
  final String token;
  final VoidCallback onJoined;
  const _GroupInviteCard(
      {required this.message, required this.token, required this.onJoined});
  @override
  State<_GroupInviteCard> createState() => _GroupInviteCardState();
}

class _GroupInviteCardState extends State<_GroupInviteCard> {
  bool _joined = false;
  bool _declined = false;
  bool _loading = false;

  Map<String, dynamic> get _meta {
    try {
      final raw = widget.message['meta'] as String? ?? '{}';
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _join() async {
    final groupId = _meta['groupId'] as String?;
    if (groupId == null) return;
    setState(() => _loading = true);
    try {
      final res = await http.post(
        Uri.parse('$kApi/groups/$groupId/join'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        setState(() {
          _joined = true;
          _loading = false;
        });
        widget.onJoined();
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupName = _meta['groupName'] as String? ?? 'קבוצה';
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kPrimary.withOpacity(0.3)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 4)
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.group_add_outlined, color: kPrimary, size: 20),
                const SizedBox(width: 8),
                const Text('הזמנה לקבוצה',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: kPrimary)),
              ]),
              const SizedBox(height: 8),
              Text('הוזמנת להצטרף לקבוצה\n"$groupName"',
                  textDirection: TextDirection.rtl,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              if (_joined)
                const Text('✓ הצטרפת לקבוצה',
                    style: TextStyle(color: Colors.green, fontSize: 13))
              else if (_declined)
                const Text('ההזמנה נדחתה',
                    style: TextStyle(color: kSubtext, fontSize: 13))
              else
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _loading ? null : _join,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: _loading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Text('הצטרף',
                                style: TextStyle(color: Colors.white)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setState(() => _declined = true),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          side: const BorderSide(color: kSubtext),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('דחה',
                            style: TextStyle(color: kSubtext)),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// Opens a listing by its id fetched from the server.
Future<void> _openListingLink(BuildContext context, String listingId,
    String token, Map<String, dynamic>? me) async {
  try {
    final res = await http.get(
      Uri.parse('$kApi/listings/$listingId'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode == 200 && context.mounted) {
      final item = jsonDecode(res.body) as Map<String, dynamic>;
      Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ListingDetailScreen(
                item: item, token: token, me: me, socket: null),
          ));
    }
  } catch (_) {}
}

class VoiceMessagePlayer extends StatefulWidget {
  final String url;
  final bool isMe;
  const VoiceMessagePlayer({super.key, required this.url, required this.isMe});

  @override
  State<VoiceMessagePlayer> createState() => _VoiceMessagePlayerState();
}

class _VoiceMessagePlayerState extends State<VoiceMessagePlayer> {
  final AudioPlayer _player = AudioPlayer();
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _player.onPositionChanged.listen((value) {
      if (mounted) setState(() => _position = value);
    });
    _player.onDurationChanged.listen((value) {
      if (mounted) setState(() => _duration = value);
    });
    _player.onPlayerStateChanged.listen((value) {
      if (mounted) setState(() => _playing = value == PlayerState.playing);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _position = Duration.zero);
    });
  }

  String _durationLabel(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  Future<void> _toggle() async {
    try {
      if (_playing) {
        await _player.pause();
      } else if (kIsWeb && _duration == Duration.zero) {
        final response =
            await http.get(Uri.parse(_absoluteMediaUrl(widget.url)));
        if (response.statusCode != 200)
          throw Exception('audio download failed');
        final lowerUrl = widget.url.toLowerCase();
        final mimeType = lowerUrl.endsWith('.webm')
            ? 'audio/webm'
            : lowerUrl.endsWith('.wav')
                ? 'audio/wav'
                : 'audio/mp4';
        await _player.play(BytesSource(response.bodyBytes, mimeType: mimeType));
      } else {
        await _player.play(UrlSource(_absoluteMediaUrl(widget.url)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('לא ניתן לנגן את ההודעה הקולית')));
      }
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = _duration.inMilliseconds;
    final progress = totalMs == 0
        ? 0.0
        : (_position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    return SizedBox(
      width: 245,
      child: Row(children: [
        CircleAvatar(
          radius: 23,
          backgroundColor: const Color(0xFFC8F7C5),
          child: Icon(Icons.person, color: kPrimary, size: 28),
        ),
        IconButton(
          onPressed: _toggle,
          icon:
              Icon(_playing ? Icons.pause : Icons.play_arrow, color: kTextDark),
        ),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(
              children: List.generate(
                  22,
                  (i) => Expanded(
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          height: 5.0 + ((i * 7) % 15),
                          color: i / 22 <= progress
                              ? kPrimaryMid
                              : const Color(0xFFCDD3D6),
                        ),
                      )),
            ),
            const SizedBox(height: 3),
            Text(
              '${_durationLabel(_position)} / ${_durationLabel(_duration)}',
              style: const TextStyle(fontSize: 10, color: kSubtext),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _ChatVideoPlayer extends StatefulWidget {
  final String url;
  const _ChatVideoPlayer({required this.url});

  @override
  State<_ChatVideoPlayer> createState() => _ChatVideoPlayerState();
}

class _ChatVideoPlayerState extends State<_ChatVideoPlayer> {
  late VideoPlayerController _controller;
  late Future<void> _initialization;

  @override
  void initState() {
    super.initState();
    _createController();
  }

  void _createController() {
    _controller = VideoPlayerController.networkUrl(
      Uri.parse(_absoluteMediaUrl(widget.url)),
    );
    _initialization = _controller.initialize().then((_) {
      _controller.setLooping(false);
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _ChatVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _controller.dispose();
      _createController();
    }
  }

  Future<void> _toggle() async {
    if (!_controller.value.isInitialized) return;
    if (_controller.value.isPlaying) {
      await _controller.pause();
    } else {
      if (_controller.value.position >= _controller.value.duration) {
        await _controller.seekTo(Duration.zero);
      }
      await _controller.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _retry() async {
    await _controller.dispose();
    if (!mounted) return;
    setState(_createController);
  }

  Future<void> _openExternally() async {
    final uri = Uri.parse(_absoluteMediaUrl(widget.url));
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('לא ניתן לפתוח את הסרטון בדפדפן')),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initialization,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Container(
            width: 280,
            constraints: const BoxConstraints(minHeight: 150),
            padding: const EdgeInsets.all(14),
            color: Colors.black87,
            alignment: Alignment.center,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.videocam_off_outlined,
                  color: Colors.white70, size: 34),
              const SizedBox(height: 8),
              const Text('הנגן המובנה לא הצליח לטעון את הסרטון',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
                OutlinedButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('נסה שוב'),
                  style:
                      OutlinedButton.styleFrom(foregroundColor: Colors.white),
                ),
                FilledButton.icon(
                  onPressed: _openExternally,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('הפעל בדפדפן'),
                ),
              ]),
            ]),
          );
        }
        if (snapshot.connectionState != ConnectionState.done ||
            !_controller.value.isInitialized) {
          return Container(
            width: 260,
            height: 150,
            color: Colors.black87,
            alignment: Alignment.center,
            child: const CircularProgressIndicator(color: Colors.white),
          );
        }
        final ratio = _controller.value.aspectRatio > 0
            ? _controller.value.aspectRatio
            : 16 / 9;
        return SizedBox(
          width: 280,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ColoredBox(
              color: Colors.black,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                GestureDetector(
                  onTap: _toggle,
                  child: Stack(alignment: Alignment.center, children: [
                    AspectRatio(
                      aspectRatio: ratio,
                      child: VideoPlayer(_controller),
                    ),
                    if (!_controller.value.isPlaying)
                      Container(
                        width: 54,
                        height: 54,
                        decoration: const BoxDecoration(
                            color: Colors.black54, shape: BoxShape.circle),
                        child: const Icon(Icons.play_arrow,
                            color: Colors.white, size: 38),
                      ),
                  ]),
                ),
                VideoProgressIndicator(
                  _controller,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: kPrimaryMid,
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white12,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 5),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _ImageStatusBadge extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;

  const _ImageStatusBadge({required this.message, required this.isMe});

  @override
  Widget build(BuildContext context) {
    var status = message['status'] as String? ?? (isMe ? 'sent' : 'received');
    final reportText = message['text']?.toString() ?? '';
    if (reportText.contains('דוח סריקה:')) {
      if (reportText.contains('תוצאה: ⛔')) {
        status = 'rejected_scan';
      } else if (reportText.contains('תוצאה: ✅')) {
        status = 'scan_approved';
      } else if (reportText.contains('תוצאה: ⏳')) {
        status = 'pending_scan';
      }
    }
    late final String label;
    late final IconData icon;
    late final Color color;
    switch (status) {
      case 'pending_scan':
        label = 'נסרק';
        icon = Icons.document_scanner_outlined;
        color = Colors.orange;
        break;
      case 'awaiting_contact_approval':
        label = 'ממתין לאישור חברות';
        icon = Icons.person_add_alt_1;
        color = Colors.orange;
        break;
      case 'failed':
        label = 'השליחה נכשלה';
        icon = Icons.error_outline;
        color = Colors.red;
        break;
      case 'rejected_scan':
        label = 'נחסם';
        icon = Icons.block;
        color = Colors.red;
        break;
      case 'scan_approved':
        label = 'עבר סריקה';
        icon = Icons.verified_outlined;
        color = Colors.green.shade700;
        break;
      case 'received':
      case 'delivered':
      case 'read':
        label = 'התקבל';
        icon = Icons.done_all;
        color = kReadTick;
        break;
      default:
        label = isMe ? 'נשלח' : 'התקבל';
        icon = isMe ? Icons.done : Icons.done_all;
        color = kPrimary;
    }
    return Tooltip(
      message: label,
      child: Container(
        width: 27,
        height: 27,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.92),
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(color: Colors.black26, blurRadius: 3),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 17, color: color),
      ),
    );
  }
}

class _ImageClassificationBadges extends StatelessWidget {
  final Map<String, dynamic> message;

  const _ImageClassificationBadges({required this.message});

  static const _labels = <String, String>{
    'video': 'הסרטון עבר סריקה וסיווג',
    'men': 'זוהה גבר',
    'women': 'זוהתה אישה',
    'children': 'זוהו ילד או ילדה',
    'nonHumanImages': 'לא זוהו בני אדם',
    'people': 'זוהו אנשים',
    'landscape': 'זוהה נוף או תוכן ללא אדם',
    'uncertain': 'הסיווג אינו ודאי',
  };

  static const _icons = <String, IconData>{
    'video': Icons.videocam_outlined,
    'men': Icons.man,
    'women': Icons.woman,
    'children': Icons.child_care,
    'nonHumanImages': Icons.landscape_outlined,
    'people': Icons.groups_outlined,
    'landscape': Icons.landscape_outlined,
    'uncertain': Icons.help_outline,
  };

  @override
  Widget build(BuildContext context) {
    final raw = message['classification'];
    if (raw is! Map) return const SizedBox.shrink();
    final detected = raw['detectedCategories'];
    var categories = detected is List
        ? detected.map((value) => value.toString()).toList()
        : <String>[];
    if (categories.isEmpty) {
      final category = raw['category']?.toString();
      categories = [
        if (raw['uncertain'] == true)
          'uncertain'
        else if (category != null && category.isNotEmpty)
          category,
      ];
    }
    categories = categories.where(_icons.containsKey).toSet().toList();
    if (categories.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: categories
          .map((category) => Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Tooltip(
                  message: _labels[category]!,
                  child: Container(
                    width: 27,
                    height: 27,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.94),
                      shape: BoxShape.circle,
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 3),
                      ],
                    ),
                    child: Icon(_icons[category], size: 18, color: kPrimary),
                  ),
                ),
              ))
          .toList(),
    );
  }
}

bool _isGridImageMessage(Map<String, dynamic> message) {
  final fileUrl = message['fileUrl'] as String?;
  if (fileUrl == null) return false;
  return _normalizeIncomingFileType(
        message['fileType'] as String?,
        fileUrl: fileUrl,
        fileName: message['fileName'] as String?,
      ) ==
      'image';
}

List<Map<String, dynamic>> _conversationImageMessages(
        Iterable<Map<String, dynamic>> messages) =>
    messages.where(_isGridImageMessage).toList();

int _conversationImageIndex(
    List<Map<String, dynamic>> images, Map<String, dynamic> selectedMessage) {
  final selectedId = selectedMessage['id'];
  final index = images.indexWhere((message) =>
      identical(message, selectedMessage) ||
      (selectedId != null && message['id'] == selectedId));
  return index < 0 ? 0 : index;
}

String _imageSentAtLabel(Map<String, dynamic> message) {
  final parsed = DateTime.tryParse(message['createdAt']?.toString() ?? '');
  if (parsed == null) return message['time']?.toString() ?? '';
  final local = parsed.toLocal();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${twoDigits(local.day)}/${twoDigits(local.month)}/${local.year} · '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}

bool _sameImageSequenceSender(
    Map<String, dynamic> first, Map<String, dynamic> second) {
  final firstTime = DateTime.tryParse(first['createdAt']?.toString() ?? '');
  final secondTime = DateTime.tryParse(second['createdAt']?.toString() ?? '');
  if (firstTime != null &&
      secondTime != null &&
      firstTime.difference(secondTime).abs() > const Duration(minutes: 5)) {
    return false;
  }
  if (first.containsKey('from') || second.containsKey('from')) {
    return first['from'] == second['from'];
  }
  return first['isMe'] == second['isMe'] &&
      first['senderName'] == second['senderName'];
}

class _ConsecutiveImageGrid extends StatelessWidget {
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> conversationMessages;
  final bool isMe;
  final VoidCallback? onForwardAll;
  final void Function(Map<String, dynamic>)? onMessageOptions;

  const _ConsecutiveImageGrid({
    required this.messages,
    required this.conversationMessages,
    required this.isMe,
    this.onForwardAll,
    this.onMessageOptions,
  });

  @override
  Widget build(BuildContext context) {
    final maxVisible = kIsWeb ? 8 : 4;
    final visible = messages.take(maxVisible).toList();
    final gridWidth = kIsWeb ? 344.0 : 228.0;
    final tileExtent = (gridWidth - 8 - 3) / 2;
    final rowCount = (visible.length / 2).ceil();
    final gridHeight = rowCount * tileExtent + (rowCount - 1) * 3;
    return GestureDetector(
      onLongPress: onForwardAll == null
          ? null
          : () => showModalBottomSheet<void>(
                context: context,
                builder: (sheetContext) => SafeArea(
                  child: ListTile(
                    leading: const Icon(Icons.forward, color: kPrimary),
                    title: Text('העבר ${messages.length} תמונות'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      onForwardAll!();
                    },
                  ),
                ),
              ),
      child: Align(
        alignment: isMe ? Alignment.centerLeft : Alignment.centerRight,
        child: Container(
          width: gridWidth,
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isMe ? kOutgoing : kIncoming,
            borderRadius: BorderRadius.circular(14),
            border: isMe ? null : Border.all(color: kBorder),
          ),
          child: SizedBox(
            height: gridHeight,
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 3,
                mainAxisSpacing: 3,
              ),
              itemCount: visible.length,
              itemBuilder: (_, index) {
                final message = visible[index];
                final url = message['fileUrl'] as String;
                final hiddenCount = messages.length - (maxVisible - 1);
                final conversationImages =
                    _conversationImageMessages(conversationMessages);
                final selectedIndex =
                    _conversationImageIndex(conversationImages, message);
                return GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ImagePreviewScreen(
                        url: url,
                        filename: message['fileName'] as String?,
                        urls: conversationImages
                            .map((item) => item['fileUrl'] as String)
                            .toList(),
                        filenames: conversationImages
                            .map((item) => item['fileName'] as String?)
                            .toList(),
                        dates: conversationImages
                            .map((item) => _imageSentAtLabel(item))
                            .toList(),
                        messages: conversationImages,
                        onMessageOptions: onMessageOptions,
                        initialIndex: selectedIndex,
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _PersistentMediaImage(
                          url: url,
                          fit: BoxFit.cover,
                          loadingBuilder: (_) => const ColoredBox(
                            color: kBorder,
                            child: Center(
                              child: CircularProgressIndicator(
                                  color: kPrimary, strokeWidth: 2),
                            ),
                          ),
                          errorBuilder: (_) => const ColoredBox(
                            color: kBorder,
                            child: Icon(Icons.broken_image, color: kSubtext),
                          ),
                        ),
                        if (index == maxVisible - 1 &&
                            messages.length > maxVisible) ...[
                          ColoredBox(color: Colors.black.withOpacity(0.48)),
                          Center(
                            child: Text(
                              '+$hiddenCount',
                              textDirection: TextDirection.ltr,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 30,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                        Positioned(
                          left: 5,
                          bottom: 5,
                          child:
                              _ImageStatusBadge(message: message, isMe: isMe),
                        ),
                        Positioned(
                          right: 5,
                          top: 5,
                          child: _ImageClassificationBadges(message: message),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SharedContactCard extends StatelessWidget {
  final Map<String, dynamic> contact;
  const _SharedContactCard(this.contact);

  @override
  Widget build(BuildContext context) {
    final name = contact['name']?.toString() ?? 'איש קשר';
    final phone = contact['phone']?.toString() ?? '';
    final email = contact['email']?.toString() ?? '';
    final uri = Uri.parse('$kServer/contact-vcard').replace(queryParameters: {
      'name': name,
      if (phone.isNotEmpty) 'phone': phone,
      if (email.isNotEmpty) 'email': email,
    });
    return Container(
      width: 250,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: Colors.white.withOpacity(.85),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kBorder)),
      child: Column(children: [
        Row(children: [
          const CircleAvatar(
              backgroundColor: kPrimary,
              child: Icon(Icons.person, color: Colors.white)),
          const SizedBox(width: 10),
          Expanded(
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(name,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            if (phone.isNotEmpty) Text(phone, textDirection: TextDirection.ltr),
            if (email.isNotEmpty)
              Text(email,
                  textDirection: TextDirection.ltr,
                  overflow: TextOverflow.ellipsis),
          ])),
        ]),
        const Divider(),
        SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () =>
                  launchUrl(uri, mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('שמור בטלפון'),
            )),
      ]),
    );
  }
}

class _BetshuvaInvitePreview extends StatelessWidget {
  final String url;
  const _BetshuvaInvitePreview(this.url);

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () =>
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
        child: Container(
          width: 330,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF8AD9C7))),
          child: Column(children: [
            Container(
                height: 145,
                width: double.infinity,
                decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        colors: [Color(0xFF38A8EA), Color(0xFF1678C5)])),
                child:
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Image.asset('icon_source.png', width: 76, height: 76),
                  const SizedBox(width: 18),
                  const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('בתשובה',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.bold)),
                        Text('מסר יהודי מחבר',
                            style:
                                TextStyle(color: Colors.white, fontSize: 15)),
                      ]),
                ])),
            Container(
                width: double.infinity,
                color: const Color(0xFFDDF7D5),
                padding: const EdgeInsets.all(12),
                child: const Column(children: [
                  Text('בתשובה — מסר נקי ויהודי',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: 5),
                  Text('צ׳אטים, קבוצות ומודעות בסביבה מסוננת.'),
                  Text('betshuva.com', style: TextStyle(color: kSubtext)),
                ])),
          ]),
        ),
      );
}

class _MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  final List<Map<String, dynamic>> conversationMessages;
  final bool isMe;
  final String token;
  final Map<String, dynamic>? me;
  final void Function(Map<String, dynamic>)? onMessageOptions;

  const _MessageBubble({
    required this.message,
    required this.conversationMessages,
    required this.isMe,
    required this.token,
    required this.me,
    this.onMessageOptions,
  });

  Widget _statusIcon() {
    if (!isMe) return const SizedBox.shrink();
    switch (message['status'] as String? ?? 'sent') {
      case 'read':
        return const Icon(Icons.done_all, size: 14, color: kReadTick);
      case 'received':
      case 'delivered':
        return const Icon(Icons.done_all, size: 14, color: kPrimaryMid);
      case 'pending_scan':
        return const Tooltip(
          message: 'בהמתנה לבדיקת תוכן לא ראוי',
          child:
              Icon(Icons.hourglass_top, size: 14, color: Colors.orangeAccent),
        );
      case 'awaiting_contact_approval':
        return const Tooltip(
          message: 'ממתין לאישור חברות — הקובץ יישלח לאחר האישור',
          child: Icon(Icons.person_add_alt_1, size: 15, color: Colors.orange),
        );
      case 'failed':
        return const Tooltip(
          message: 'השליחה נכשלה',
          child: Icon(Icons.error_outline, size: 15, color: Colors.red),
        );
      case 'rejected_scan':
        return const Tooltip(
          message: 'התמונה לא נשלחה',
          child: Icon(Icons.error_outline, size: 15, color: Colors.red),
        );
      default:
        return const Icon(Icons.done, size: 14, color: kPrimaryMid);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFile = message['isFile'] == true;
    final fileUrl = message['fileUrl'] as String?;
    final fileName = message['fileName'] as String?;
    final fileType = _normalizeIncomingFileType(
      message['fileType'] as String?,
      fileUrl: fileUrl,
      fileName: fileName,
    );
    final isImageFile = isFile && fileUrl != null && fileType == 'image';
    final isAudioFile = isFile && fileUrl != null && fileType == 'audio';
    final isVideoFile = isFile && fileUrl != null && fileType == 'video';
    final conversationImages = _conversationImageMessages(conversationMessages);
    final selectedImageIndex =
        _conversationImageIndex(conversationImages, message);

    // זיהוי קישור מודעה פנימי: betshuva://listing/{id}
    final rawText = message['text'] as String? ?? '';
    final sharedContact = !isFile ? _sharedContactFromText(rawText) : null;
    final inviteMatch = !isFile
        ? RegExp(
                r'https://betshuva\.com/betshuva-app/invite-v2\.html\?invite=[\w-]+')
            .firstMatch(rawText)
        : null;
    final linkRegex = RegExp(r'betshuva://listing/([\w\-]+)');
    final linkMatch = !isFile ? linkRegex.firstMatch(rawText) : null;
    final listingId = linkMatch?.group(1);
    // טקסט נקי ללא שורת הקישור
    final displayText = sharedContact != null
        ? ''
        : linkMatch != null
            ? rawText
                .replaceAll('\nbetshuva://listing/$listingId', '')
                .replaceAll('betshuva://listing/$listingId', '')
                .trim()
            : rawText;

    const textColor = kTextDark;
    const timeColor = kSubtext;
    final replyBg = kPrimary.withOpacity(0.08);
    const replyBorder = kPrimary;

    return Align(
      alignment: isMe ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: BoxDecoration(
          color: isMe ? kOutgoing : kIncoming,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft:
                isMe ? const Radius.circular(3) : const Radius.circular(14),
            bottomRight:
                isMe ? const Radius.circular(14) : const Radius.circular(3),
          ),
          border: isMe ? null : Border.all(color: kBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message['replyTo'] != null)
              Align(
                alignment: Alignment.centerRight,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: replyBg,
                    borderRadius: BorderRadius.circular(8),
                    border: Border(
                      right: BorderSide(color: replyBorder, width: 3),
                    ),
                  ),
                  child: Text(
                    (message['replyTo'] as Map)['text'] as String,
                    style: TextStyle(fontSize: 12, color: timeColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.rtl,
                    textAlign: TextAlign.right,
                  ),
                ),
              ),

            if (isAudioFile)
              VoiceMessagePlayer(url: fileUrl!, isMe: isMe)
            else if (isVideoFile)
              Stack(children: [
                if (kIsWeb)
                  NativeWebVideoPlayer(
                    key: ValueKey('video-$fileUrl'),
                    url: _absoluteMediaUrl(fileUrl!),
                    onOptions: onMessageOptions == null
                        ? null
                        : () => onMessageOptions!(message),
                  )
                else
                  _ChatVideoPlayer(url: fileUrl!),
                Positioned(
                  right: 7,
                  top: 7,
                  child: _ImageClassificationBadges(message: message),
                ),
                Positioned(
                  left: 7,
                  top: 7,
                  child: _ImageStatusBadge(message: message, isMe: isMe),
                ),
              ])
            else if (isImageFile)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  GestureDetector(
                    onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ImagePreviewScreen(
                            url: fileUrl!,
                            filename: fileName,
                            urls: conversationImages
                                .map((item) => item['fileUrl'] as String)
                                .toList(),
                            filenames: conversationImages
                                .map((item) => item['fileName'] as String?)
                                .toList(),
                            dates: conversationImages
                                .map((item) => _imageSentAtLabel(item))
                                .toList(),
                            messages: conversationImages,
                            onMessageOptions: onMessageOptions,
                            initialIndex: selectedImageIndex,
                          ),
                        )),
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: _PersistentMediaImage(
                            url: fileUrl!,
                            width: 220,
                            fit: BoxFit.cover,
                            loadingBuilder: (_) => Container(
                              width: 220,
                              height: 160,
                              color: kBorder,
                              child: const Center(
                                  child: CircularProgressIndicator(
                                      color: kPrimary, strokeWidth: 2)),
                            ),
                            errorBuilder: (_) => Container(
                              width: 220,
                              height: 120,
                              color: kBorder,
                              child: const Icon(Icons.broken_image,
                                  color: kSubtext, size: 40),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 7,
                          bottom: 7,
                          child:
                              _ImageStatusBadge(message: message, isMe: isMe),
                        ),
                        Positioned(
                          right: 7,
                          top: 7,
                          child: _ImageClassificationBadges(message: message),
                        ),
                      ],
                    ),
                  ),
                  if (displayText.trim().isNotEmpty &&
                      displayText.trim() != (fileName ?? '').trim()) ...[
                    const SizedBox(height: 8),
                    Text(
                      displayText,
                      style: const TextStyle(
                          fontSize: 14, height: 1.45, color: textColor),
                      textDirection: TextDirection.rtl,
                      textAlign: TextAlign.right,
                    ),
                  ],
                ],
              )
            else if (isFile)
              InkWell(
                onTap: fileUrl == null
                    ? null
                    : () => _downloadChatFile(context, fileUrl, fileName),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                          isVideoFile
                              ? Icons.videocam_outlined
                              : Icons.insert_drive_file,
                          size: 20,
                          color: kPrimary),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          fileName ??
                              message['text'] as String? ??
                              (isVideoFile ? 'סרטון וידאו' : 'מסמך'),
                          style: TextStyle(fontSize: 14, color: textColor),
                          textDirection: TextDirection.rtl,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Icon(Icons.download, size: 20, color: kPrimary),
                      const SizedBox(width: 3),
                      const Text('הורדה',
                          style: TextStyle(
                              fontSize: 12,
                              color: kPrimary,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              )
            else if (sharedContact != null)
              _SharedContactCard(sharedContact)
            else
              Text(
                displayText,
                style: TextStyle(
                    fontSize: _looksLikeSticker(displayText) ? 44 : 14,
                    height: 1.45,
                    color: textColor),
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
              ),

            if (inviteMatch != null) ...[
              const SizedBox(height: 8),
              _BetshuvaInvitePreview(inviteMatch.group(0)!),
            ],

            // כרטיסיית קישור למודעה
            if (listingId != null) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => _openListingLink(context, listingId, token, me),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: kPrimary.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: kPrimary.withOpacity(0.35),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.storefront_outlined,
                          size: 16, color: kPrimary),
                      const SizedBox(width: 6),
                      Text(
                        'צפה במודעה',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: kPrimary,
                          decoration: TextDecoration.underline,
                          decorationColor: kPrimary,
                        ),
                        textDirection: TextDirection.rtl,
                      ),
                    ],
                  ),
                ),
              ),
            ],

            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message['isEdited'] == true)
                  Text('נערך · ',
                      style: TextStyle(
                          fontSize: 10,
                          color: timeColor,
                          fontStyle: FontStyle.italic)),
                Text(
                  message['time'] as String? ?? '',
                  style: TextStyle(fontSize: 10, color: timeColor),
                ),
                if (!isImageFile) ...[
                  const SizedBox(width: 3),
                  _statusIcon(),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

const _gifPickerAction = '__pick_gif__';
const _sharedGifUploadAction = '__shared_gif_upload__';
const _personalStickerAction = '__personal_sticker__';
const _sharedGifPrefix = '__shared_gif__:';
const _stickerPrefix = '__sticker__:';
const _originalExpressionPrefix = '__betshuva_expression__:';
const _remoteExpressionPrefix = '__betshuva_remote_expression__:';
const _originalSmileAssets = <String>[
  'assets/expressions/items/expression-01.png',
  'assets/expressions/items/expression-06.png',
  'assets/expressions/items/expression-11.png',
  'assets/expressions/items/expression-16.png',
  'assets/expressions/items/expression-20.png',
];
const _originalStickerAssets = <String>[
  'assets/expressions/items/expression-02.png',
  'assets/expressions/items/expression-03.png',
  'assets/expressions/items/expression-04.png',
  'assets/expressions/items/expression-05.png',
  'assets/expressions/items/expression-07.png',
  'assets/expressions/items/expression-08.png',
  'assets/expressions/items/expression-09.png',
  'assets/expressions/items/expression-10.png',
  'assets/expressions/items/expression-12.png',
  'assets/expressions/items/expression-13.png',
  'assets/expressions/items/expression-14.png',
  'assets/expressions/items/expression-15.png',
  'assets/expressions/items/expression-17.png',
  'assets/expressions/items/expression-18.png',
  'assets/expressions/items/expression-19.png',
];
const _originalGifAssets = <String>[
  'assets/expressions/items/expression-21.gif',
  'assets/expressions/items/expression-22.gif',
  'assets/expressions/items/expression-23.gif',
  'assets/expressions/items/expression-24.gif',
  'assets/expressions/items/expression-25.gif',
];
const _originalSmileLabels = <String>[
  'שמחה',
  'צחוק',
  'אהבה',
  'תודה',
  'ברכה',
  'שלווה',
  'התרגשות',
  'הפתעה',
  'מחשבה',
  'תקווה',
  'תפילה',
  'עידוד',
  'ביטחון',
  'ביישנות',
  'עצב',
  'בכי',
  'דאגה',
  'סליחה',
  'לילה טוב',
  'חגיגה'
];
const _originalStickerLabels = <String>[
  'שבת שלום',
  'שבת מבורכת',
  'שלום בית',
  'שנה טובה',
  'גמר חתימה טובה',
  'חג סוכות שמח',
  'שמחת תורה',
  'חנוכה שמח',
  'נס גדול היה פה',
  'פורים שמח',
  'פסח כשר ושמח',
  'קריעת ים סוף',
  'ל״ג בעומר שמח',
  'חג שבועות שמח',
  'ירושלים',
  'תפילה',
  'צדקה',
  'ברכה והצלחה',
  'שלום ואחדות',
  'בשורות טובות'
];
const _originalFamilyLabels = <String>[
  'שמחה',
  'מודה ושמחה',
  'אמא ותינוק',
  'תינוק שמח',
  'פעוט מוחא כפיים',
  'ילדה שמחה',
  'ילד שמח',
  'אחים אוהבים',
  'רוקדים משמחה',
  'לומדים בשמחה',
  'עוזרים בבית',
  'עוזרים לאבא',
  'משפחה בשבת',
  'הדלקת נרות',
  'ילדים וחלה',
  'חלומות מתוקים',
  'מכל הלב',
  'תודה רבה',
  'חיבוק משפחתי',
  'שמחה משפחתית'
];
const _originalGifLabels = <String>[
  'שמחה מאירה',
  'אהבה זוהרת',
  'מגן דוד מסתובב',
  'שבת שלום',
  'שבת מבורכת',
  'שלום',
  'סביבון',
  'חנוכה מאיר',
  'חג סוכות שמח',
  'שנה טובה',
  'מזל טוב',
  'מחיאות כפיים',
  'תפילה',
  'איזה יופי',
  'תקווה',
  'ירושלים מאירה',
  'תקיעת שופר',
  'חגיגה',
  'יום מאיר',
  'לילה טוב'
];
const _emojiCategories = <String, List<String>>{
  'אחרונים': [],
  'חיוכים': [
    '😀',
    '😃',
    '😄',
    '😁',
    '😆',
    '😅',
    '😂',
    '🤣',
    '😊',
    '😇',
    '🙂',
    '🙃',
    '😉',
    '😌',
    '😍',
    '🥰',
    '😘',
    '😋',
    '😎',
    '🤩',
    '🥳',
    '😏',
    '😢',
    '😭',
    '😡',
    '🤔',
    '🤗',
    '🤭',
    '🫡',
    '😴'
  ],
  'מחוות': [
    '👍',
    '👎',
    '👌',
    '✌️',
    '🤞',
    '🤟',
    '🤘',
    '🤙',
    '👈',
    '👉',
    '👆',
    '👇',
    '☝️',
    '✋',
    '🤚',
    '🖐️',
    '👋',
    '👏',
    '🙌',
    '👐',
    '🤲',
    '🙏',
    '✍️',
    '💪',
    '🤝',
    '🫶'
  ],
  'לבבות': [
    '❤️',
    '🧡',
    '💛',
    '💚',
    '💙',
    '💜',
    '🖤',
    '🤍',
    '🤎',
    '💔',
    '❣️',
    '💕',
    '💞',
    '💓',
    '💗',
    '💖',
    '💘',
    '💝',
    '💟'
  ],
  'חיות': [
    '🐶',
    '🐱',
    '🐭',
    '🐹',
    '🐰',
    '🦊',
    '🐻',
    '🐼',
    '🐨',
    '🐯',
    '🦁',
    '🐮',
    '🐷',
    '🐸',
    '🐵',
    '🐔',
    '🐧',
    '🐦',
    '🦋',
    '🐝',
    '🐞',
    '🐢',
    '🐬',
    '🕊️'
  ],
  'אוכל': [
    '🍎',
    '🍊',
    '🍋',
    '🍉',
    '🍇',
    '🍓',
    '🍒',
    '🥑',
    '🍅',
    '🥕',
    '🌽',
    '🍞',
    '🥐',
    '🧀',
    '🍕',
    '🍔',
    '🍟',
    '🥗',
    '🍰',
    '🍫',
    '☕',
    '🍷'
  ],
  'פעילות': [
    '⚽',
    '🏀',
    '🏈',
    '⚾',
    '🎾',
    '🏐',
    '🏓',
    '🏸',
    '🥊',
    '🏆',
    '🎯',
    '🎮',
    '🎲',
    '🎸',
    '🎤',
    '🎨',
    '🚴',
    '🏃',
    '🏊',
    '🧘'
  ],
  'טבע': [
    '☀️',
    '🌤️',
    '🌧️',
    '⛈️',
    '🌈',
    '⭐',
    '🌟',
    '✨',
    '🔥',
    '💧',
    '🌊',
    '🌸',
    '🌹',
    '🌻',
    '🌳',
    '🍀',
    '🌙',
    '❄️'
  ],
  'סמלים': [
    '✅',
    '❌',
    '❓',
    '❗',
    '⚠️',
    '💯',
    '🎉',
    '🎊',
    '🎁',
    '💡',
    '📌',
    '📞',
    '💬',
    '🔔',
    '🔒',
    '🔑',
    '🛡️',
    '♻️',
    '✡️',
    '🇮🇱'
  ],
};
const _messageStickers = [
  '👍',
  '❤️',
  '🙏',
  '😂',
  '🥳',
  '🎉',
  '🔥',
  '💯',
  '👏',
  '🤝',
  '💪',
  '🌹',
  '⭐',
  '☀️',
  '🕊️',
  '🇮🇱',
  'בוקר טוב ☀️',
  'תודה רבה 🙏',
  'כל הכבוד 👏',
  'מזל טוב 🎉',
  'שבת שלום 🕯️',
  'בהצלחה 💪',
];

Future<String?> _showExpressionPicker(BuildContext context, String token) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => _ExpressionPickerSheet(token: token),
  );
}

Future<Map<String, String>?> _requestSharedGifDetails(
    BuildContext context) async {
  final title = TextEditingController();
  final tags = TextEditingController();
  var rightsConfirmed = false;
  final result = await showDialog<Map<String, String>>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('הוספת GIF לספרייה המשותפת'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: title,
              onChanged: (_) => setDialogState(() {}),
              decoration: const InputDecoration(labelText: 'שם ה-GIF')),
          TextField(
              controller: tags,
              decoration: const InputDecoration(
                  labelText: 'תגיות לחיפוש, מופרדות בפסיקים')),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: rightsConfirmed,
            onChanged: (value) =>
                setDialogState(() => rightsConfirmed = value == true),
            title: const Text(
                'אני מאשר/ת שיש לי זכות לשתף את הקובץ עם כל המשתמשים',
                style: TextStyle(fontSize: 13)),
          ),
          const Text('ה-GIF יפורסם רק לאחר סריקת כל הפריימים.',
              style: TextStyle(fontSize: 12, color: kSubtext)),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('ביטול')),
          ElevatedButton(
            onPressed: rightsConfirmed && title.text.trim().isNotEmpty
                ? () => Navigator.pop(dialogContext, {
                      'title': title.text.trim(),
                      'tags': tags.text.trim(),
                    })
                : null,
            child: const Text('בחר GIF והעלה'),
          ),
        ],
      ),
    ),
  );
  title.dispose();
  tags.dispose();
  return result;
}

class _ExpressionPickerSheet extends StatefulWidget {
  final String token;
  const _ExpressionPickerSheet({required this.token});

  @override
  State<_ExpressionPickerSheet> createState() => _ExpressionPickerSheetState();
}

class _ExpressionPickerSheetState extends State<_ExpressionPickerSheet> {
  String _category = 'חיוכים';
  String _emojiQuery = '';
  final _gifSearch = TextEditingController();
  List<String> _recent = [];
  List<Map<String, dynamic>> _gifs = [];
  List<Map<String, dynamic>>? _remoteExpressionCategories;
  bool _loadingExpressionCatalog = true;
  bool _searchingGifs = false;
  String? _gifError;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() => _recent = prefs.getStringList('recent_emojis') ?? []);
    });
    _loadExpressionCatalog();
  }

  Future<void> _loadExpressionCatalog() async {
    try {
      final response = await http.get(
        Uri.parse('$kApi/expressions/catalog'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode != 200) return;
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final categories = (payload['categories'] as List? ?? const [])
          .whereType<Map>()
          .map((category) => Map<String, dynamic>.from(category))
          .where(
              (category) => (category['items'] as List? ?? const []).isNotEmpty)
          .toList();
      if (mounted && categories.isNotEmpty) {
        setState(() {
          _remoteExpressionCategories = categories;
          _loadingExpressionCatalog = false;
        });
      }
    } catch (_) {
      // The bundled collection remains available as an offline fallback.
    } finally {
      if (mounted && _remoteExpressionCategories == null) {
        setState(() => _loadingExpressionCatalog = false);
      }
    }
  }

  @override
  void dispose() {
    _gifSearch.dispose();
    super.dispose();
  }

  Future<void> _chooseEmoji(String emoji) async {
    final updated =
        [emoji, ..._recent.where((item) => item != emoji)].take(24).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('recent_emojis', updated);
    if (mounted) Navigator.pop(context, emoji);
  }

  Future<void> _searchOnlineGifs() async {
    final query = _gifSearch.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searchingGifs = true;
      _gifError = null;
    });
    try {
      final response = await http.get(
        Uri.parse('$kApi/gifs/search?q=${Uri.encodeQueryComponent(query)}'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200)
        throw Exception(payload['error'] ?? 'החיפוש נכשל');
      if (!mounted) return;
      setState(() => _gifs =
          (payload['results'] as List? ?? []).cast<Map<String, dynamic>>());
    } catch (error) {
      if (mounted)
        setState(
            () => _gifError = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _searchingGifs = false);
    }
  }

  IconData _expressionCategoryIcon(String id) {
    switch (id) {
      case 'family':
        return Icons.family_restroom;
      case 'stickers':
        return Icons.auto_awesome;
      case 'animated':
        return Icons.animation;
      default:
        return Icons.sentiment_satisfied_alt;
    }
  }

  Widget _buildRemoteExpressionPicker(List<Map<String, dynamic>> categories) {
    return SafeArea(
      child: DefaultTabController(
        length: categories.length,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.68,
          child: Column(children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(children: [
                Icon(Icons.cloud_done_outlined, color: kPrimary),
                SizedBox(width: 8),
                Expanded(
                  child: Text('הביטויים של בתשובה — מתעדכנים אוטומטית',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ]),
            ),
            TabBar(
              isScrollable: categories.length > 4,
              labelColor: kPrimary,
              tabs: categories
                  .map((category) => Tab(
                        icon: Icon(_expressionCategoryIcon(
                            category['id']?.toString() ?? '')),
                        text: category['title']?.toString() ?? '',
                      ))
                  .toList(),
            ),
            Expanded(
              child: TabBarView(
                children: categories
                    .map((category) => _RemoteExpressionGrid(
                          items: (category['items'] as List? ?? const [])
                              .whereType<Map>()
                              .map((item) => Map<String, dynamic>.from(item))
                              .toList(),
                        ))
                    .toList(),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Text(
                'הספרייה נטענת מהשרת ונשמרת במטמון — תכנים חדשים יופיעו ללא עדכון אפליקציה',
                style: TextStyle(fontSize: 11, color: kSubtext),
                textAlign: TextAlign.center,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final remoteCategories = _remoteExpressionCategories;
    if (remoteCategories != null && remoteCategories.isNotEmpty) {
      return _buildRemoteExpressionPicker(remoteCategories);
    }
    if (_loadingExpressionCatalog) {
      return const SafeArea(
        child: SizedBox(
          height: 260,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(color: kPrimary),
              SizedBox(height: 14),
              Text('טוען את ספריית הביטויים…'),
            ]),
          ),
        ),
      );
    }
    return _legacyBuild(context);
    /* Offline legacy fallback retained below for reference.
    return SafeArea(
      child: DefaultTabController(
        length: 3,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.68,
          child: Column(children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(children: [
                Icon(Icons.auto_awesome, color: kPrimary),
                SizedBox(width: 8),
                Text('הביטויים המקוריים של בתשובה',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ]),
            ),
            const TabBar(labelColor: kPrimary, tabs: [
              Tab(icon: Icon(Icons.sentiment_satisfied_alt), text: 'סמיילים'),
              Tab(icon: Icon(Icons.auto_awesome), text: 'מדבקות'),
              Tab(icon: Icon(Icons.animation), text: 'מונפשים'),
            ]),
            Expanded(
              child: TabBarView(children: [
                _OriginalExpressionGrid(
                    assets: _originalSmileAssets,
                    labels: _originalSmileLabels,
                    columns: 4),
                _OriginalExpressionGrid(
                    assets: _originalStickerAssets,
                    labels: _originalStickerLabels,
                    columns: 4),
                _OriginalExpressionGrid(
                    assets: _originalGifAssets,
                    labels: _originalGifLabels,
                    columns: 4),
              ]),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Text(
                'איורים מקוריים ונקיים שנוצרו במיוחד עבור קהילת בתשובה',
                style: TextStyle(fontSize: 11, color: kSubtext),
                textAlign: TextAlign.center,
              ),
            ),
          ]),
        ),
      ),
    ); */
  }

  Widget _legacyBuild(BuildContext context) {
    final categoryValues = _category == 'אחרונים'
        ? _recent
        : (_emojiCategories[_category] ?? const <String>[]);
    final query = _emojiQuery.trim();
    final matchingCategories = _emojiCategories.entries
        .where((entry) => entry.key.contains(query))
        .expand((entry) => entry.value);
    final emojis = query.isEmpty
        ? categoryValues
        : <String>{
            ...matchingCategories,
            ..._emojiCategories.values
                .expand((items) => items)
                .where((emoji) => emoji.contains(query)),
          }.toList();
    return SafeArea(
      child: DefaultTabController(
        length: 3,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.68,
          child: Column(children: [
            const TabBar(labelColor: kPrimary, tabs: [
              Tab(icon: Icon(Icons.emoji_emotions_outlined), text: 'אימוג׳י'),
              Tab(icon: Icon(Icons.auto_awesome), text: 'מדבקות'),
              Tab(icon: Icon(Icons.gif_box_outlined), text: 'GIF'),
            ]),
            Expanded(
                child: TabBarView(children: [
              Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: TextField(
                    decoration: const InputDecoration(
                        hintText: 'חיפוש אימוג׳י...',
                        prefixIcon: Icon(Icons.search),
                        isDense: true),
                    onChanged: (value) => setState(() => _emojiQuery = value),
                  ),
                ),
                SizedBox(
                    height: 42,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: _emojiCategories.keys
                          .map((name) => Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 3),
                                child: ChoiceChip(
                                    label: Text(name),
                                    selected: _category == name,
                                    onSelected: (_) =>
                                        setState(() => _category = name)),
                              ))
                          .toList(),
                    )),
                Expanded(
                    child: emojis.isEmpty
                        ? const Center(child: Text('אין אימוג׳ים להצגה'))
                        : GridView.builder(
                            padding: const EdgeInsets.all(12),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 8),
                            itemCount: emojis.length,
                            itemBuilder: (_, index) => InkWell(
                              onTap: () => _chooseEmoji(emojis[index]),
                              child: Center(
                                  child: Text(emojis[index],
                                      style: const TextStyle(fontSize: 28))),
                            ),
                          )),
              ]),
              Column(children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            Navigator.pop(context, _personalStickerAction),
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text('יצירת מדבקה מתמונה — לאחר סריקה'),
                      )),
                ),
                Expanded(
                    child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10),
                  itemCount: _messageStickers.length,
                  itemBuilder: (_, index) => InkWell(
                    onTap: () => Navigator.pop(
                        context, '$_stickerPrefix${_messageStickers[index]}'),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          color: const Color(0xFFF0F6FC),
                          borderRadius: BorderRadius.circular(16)),
                      child: Center(
                          child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(_messageStickers[index],
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize:
                                    _messageStickers[index].runes.length <= 3
                                        ? 42
                                        : 18,
                                fontWeight: FontWeight.w600)),
                      )),
                    ),
                  ),
                )),
              ]),
              Column(children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Expanded(
                        child: TextField(
                            controller: _gifSearch,
                            onSubmitted: (_) => _searchOnlineGifs(),
                            decoration: const InputDecoration(
                                hintText: 'חיפוש GIF בטוח...',
                                prefixIcon: Icon(Icons.search)))),
                    const SizedBox(width: 8),
                    IconButton(
                        onPressed: _searchingGifs ? null : _searchOnlineGifs,
                        icon: _searchingGifs
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.search)),
                  ]),
                ),
                if (_gifError != null)
                  Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(_gifError!,
                          style: const TextStyle(color: Colors.red))),
                Expanded(
                    child: _gifs.isEmpty
                        ? Center(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                const Text('חפשו GIF או בחרו קובץ מהמכשיר'),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                    onPressed: () => Navigator.pop(
                                        context, _gifPickerAction),
                                    icon: const Icon(Icons.folder_open),
                                    label: const Text('בחירה מהמכשיר')),
                                const SizedBox(height: 8),
                                ElevatedButton.icon(
                                    onPressed: () => Navigator.pop(
                                        context, _sharedGifUploadAction),
                                    icon: const Icon(Icons.public),
                                    label: const Text('הוספה לספרייה המשותפת')),
                              ]))
                        : GridView.builder(
                            padding: const EdgeInsets.all(10),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    mainAxisSpacing: 6,
                                    crossAxisSpacing: 6),
                            itemCount: _gifs.length,
                            itemBuilder: (_, index) {
                              final gif = _gifs[index];
                              return InkWell(
                                onTap: () {
                                  final encoded = base64Url
                                      .encode(utf8.encode(jsonEncode(gif)));
                                  Navigator.pop(
                                      context, '$_sharedGifPrefix$encoded');
                                },
                                child: Image.network(
                                    _absoluteMediaUrl(
                                        gif['preview_url'] as String),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const ColoredBox(
                                            color: kBorder,
                                            child: Icon(Icons.broken_image))),
                              );
                            },
                          )),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: () =>
                            Navigator.pop(context, _sharedGifUploadAction),
                        icon: const Icon(Icons.add, size: 17),
                        label: const Text('הוספה לספרייה'),
                      ),
                      const Text('• כל GIF נסרק לפני הפרסום',
                          style: TextStyle(fontSize: 11, color: kSubtext)),
                    ],
                  ),
                ),
              ]),
            ])),
          ]),
        ),
      ),
    );
  }
}

class _RemoteExpressionGrid extends StatelessWidget {
  final List<Map<String, dynamic>> items;

  const _RemoteExpressionGrid({required this.items});

  String _absoluteUrl(String value) => Uri.parse(value).hasScheme
      ? value
      : '${kServerUri.origin}${value.startsWith('/') ? value : '/$value'}';

  @override
  Widget build(BuildContext context) => LayoutBuilder(
      builder: (context, constraints) => GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: constraints.maxWidth < 360 ? 4 : 5,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.9,
            ),
            itemCount: items.length,
            itemBuilder: (_, index) {
              final item = items[index];
              final url = _absoluteUrl(item['url']?.toString() ?? '');
              return Material(
                color: const Color(0xFFF0F6FC),
                borderRadius: BorderRadius.circular(15),
                child: InkWell(
                  borderRadius: BorderRadius.circular(15),
                  onTap: url.isEmpty
                      ? null
                      : () => Navigator.pop(
                          context, '$_remoteExpressionPrefix$url'),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(5, 7, 5, 5),
                    child: Column(children: [
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                                maxWidth: 66, maxHeight: 66),
                            child: Image.network(
                              url,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.medium,
                              errorBuilder: (_, __, ___) => const Icon(
                                  Icons.broken_image_outlined,
                                  color: kSubtext),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        item['label']?.toString() ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: kPrimary,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ]),
                  ),
                ),
              );
            },
          ));
}

class _OriginalExpressionGrid extends StatelessWidget {
  final List<String> assets;
  final List<String> labels;
  final int columns;

  const _OriginalExpressionGrid({
    required this.assets,
    required this.labels,
    required this.columns,
  });

  @override
  Widget build(BuildContext context) => GridView.builder(
        padding: const EdgeInsets.all(14),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.82,
        ),
        itemCount: assets.length,
        itemBuilder: (_, index) => Material(
          color: const Color(0xFFF0F6FC),
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => Navigator.pop(
                context, '$_originalExpressionPrefix${assets[index]}'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 5),
              child: Column(children: [
                Expanded(
                  child: Image.asset(assets[index], fit: BoxFit.contain),
                ),
                const SizedBox(height: 3),
                Text(
                  labels[index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: kPrimary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _AttachOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _AttachOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

// ── Groups Screen ─────────────────────────────────────────────────
class GroupsScreen extends StatefulWidget {
  final String token;
  final Map<String, dynamic>? me;
  final IO.Socket? socket;
  final Map<String, String> groupTypingNames;
  final String? selectedGroupId;
  final void Function(Map<String, dynamic> group, bool openMembers)?
      onGroupSelected;
  const GroupsScreen({
    super.key,
    required this.token,
    required this.me,
    required this.socket,
    required this.groupTypingNames,
    this.selectedGroupId,
    this.onGroupSelected,
  });
  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  List<Map<String, dynamic>> _groups = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadGroups();
    widget.socket?.on('group:message', (data) {
      final gid = data['groupId'];
      if (!mounted) return;
      setState(() {
        final idx = _groups.indexWhere((g) => g['id'] == gid);
        if (idx != -1) _groups[idx]['lastMsg'] = data['text'] as String? ?? '';
      });
    });
    widget.socket?.on('group:invited', (data) {
      if (!mounted) return;
      _loadGroups();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '${data['addedByName']} הוסיף אותך לקבוצה "${data['groupName']}"')),
      );
    });
  }

  @override
  void dispose() {
    widget.socket?.off('group:message');
    widget.socket?.off('group:invited');
    super.dispose();
  }

  Future<void> _loadGroups() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/groups'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        setState(() {
          _groups = data.cast<Map<String, dynamic>>();
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleGroupPin(Map<String, dynamic> group) async {
    final pinned = group['pinned_at'] == null;
    try {
      final response = await http.put(
        Uri.parse('$kApi/pins/group/${group['id']}'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'pinned': pinned}),
      );
      if (response.statusCode == 200 && mounted) {
        await _loadGroups();
      }
    } catch (_) {}
  }

  Future<void> _createGroup() async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('קבוצה חדשה'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(labelText: 'שם הקבוצה'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descCtrl,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(labelText: 'תיאור (אופציונלי)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('צור')),
        ],
      ),
    );
    if (confirmed != true || nameCtrl.text.trim().isEmpty) return;
    try {
      final res = await http.post(
        Uri.parse('$kApi/groups'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'name': nameCtrl.text.trim(),
          'description': descCtrl.text.trim()
        }),
      );
      if (res.statusCode == 200 && mounted) {
        final group = jsonDecode(res.body) as Map<String, dynamic>;
        widget.socket?.emit('group:join', {'groupId': group['id']});
        await _loadGroups();
        if (widget.onGroupSelected != null &&
            MediaQuery.sizeOf(context).width >= 900) {
          widget.onGroupSelected!(group, true);
          return;
        }
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GroupChatScreen(
              group: group,
              me: widget.me,
              token: widget.token,
              socket: widget.socket,
              openAddMembersOnStart: true,
            ),
          ),
        );
        _loadGroups();
      } else if (mounted) {
        var error = 'לא ניתן ליצור את הקבוצה';
        try {
          error = (jsonDecode(res.body) as Map)['error']?.toString() ?? error;
        } catch (_) {}
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('שגיאת תקשורת ביצירת הקבוצה')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        toolbarHeight: 72,
        title: _BrandAppBarTitle(me: widget.me),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add),
            tooltip: 'קבוצה חדשה',
            onPressed: _createGroup,
          ),
          IconButton(icon: const Icon(Icons.search), onPressed: () {}),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth:
                MediaQuery.sizeOf(context).width >= 900 ? 520 : double.infinity,
          ),
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: kPrimary))
              : _groups.isEmpty
                  ? const Center(
                      child: Text('אין קבוצות עדיין',
                          style: TextStyle(color: kSubtext)))
                  : ListView.separated(
                      itemCount: _groups.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 76),
                      itemBuilder: (_, i) {
                        final g = _groups[i];
                        final isAdmin = g['role'] == 'admin';
                        final isPending = g['status'] == 'pending';
                        final memberCount = g['member_count'] ?? 0;
                        final lastMsg = g['lastMsg'] as String? ??
                            g['description'] as String? ??
                            '';
                        return Container(
                          color: widget.selectedGroupId == g['id']
                              ? const Color(0xFFE9EDEF)
                              : (isPending ? const Color(0xFFFFF3CD) : null),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 6),
                            leading: Stack(
                              children: [
                                UserAvatar(
                                  radius: 26,
                                  picUrl: g['profile_pic_url'] as String?,
                                  name: g['name'] as String? ?? 'קבוצה',
                                ),
                                if (isAdmin && !isPending)
                                  Positioned(
                                    left: 0,
                                    bottom: 0,
                                    child: Container(
                                      padding: const EdgeInsets.all(2),
                                      decoration: BoxDecoration(
                                        color: Colors.orange,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Icon(Icons.star,
                                          size: 10, color: Colors.white),
                                    ),
                                  ),
                                if (isPending)
                                  Positioned(
                                    left: 0,
                                    bottom: 0,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 4, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.orange,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text('ממתין',
                                          style: TextStyle(
                                              fontSize: 9,
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold)),
                                    ),
                                  ),
                              ],
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                    child: Text(g['name'] as String,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600))),
                                if (!isPending) ...[
                                  const SizedBox(width: 6),
                                  _AdminBadge(
                                    adminName: isAdmin
                                        ? 'אתה'
                                        : g['admin_name'] as String?,
                                  ),
                                ],
                                if (isPending)
                                  Container(
                                    margin: const EdgeInsets.only(right: 6),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.orange,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: const Text('בהשהייה',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold)),
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              isPending
                                  ? 'ממתין לאישורך'
                                  : (widget.groupTypingNames[g['id']] != null
                                      ? '${widget.groupTypingNames[g['id']]} מקליד...'
                                      : (lastMsg.isNotEmpty
                                          ? lastMsg
                                          : '$memberCount חברים')),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: isPending
                                    ? const Color(0xFF856404)
                                    : widget.groupTypingNames[g['id']] != null
                                        ? const Color(0xFF16A34A)
                                        : kSubtext,
                                fontStyle:
                                    widget.groupTypingNames[g['id']] != null
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: g['pinned_at'] == null
                                      ? 'הצמד קבוצה'
                                      : 'בטל הצמדה',
                                  onPressed: isPending
                                      ? null
                                      : () => _toggleGroupPin(g),
                                  icon: Icon(
                                    g['pinned_at'] == null
                                        ? Icons.push_pin_outlined
                                        : Icons.push_pin,
                                    color: g['pinned_at'] == null
                                        ? kSubtext
                                        : kPrimary,
                                    size: 19,
                                  ),
                                ),
                                const Icon(Icons.chevron_left, color: kSubtext),
                              ],
                            ),
                            onTap: () {
                              if (widget.onGroupSelected != null &&
                                  MediaQuery.sizeOf(context).width >= 900) {
                                widget.onGroupSelected!(g, false);
                              } else {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => GroupChatScreen(
                                      group: g,
                                      me: widget.me,
                                      token: widget.token,
                                      socket: widget.socket,
                                    ),
                                  ),
                                ).then((_) => _loadGroups());
                              }
                            },
                          ),
                        );
                      },
                    ),
        ),
      ),
    );
  }
}

// ── Group Chat Screen ─────────────────────────────────────────────
class GroupChatScreen extends StatefulWidget {
  final Map<String, dynamic> group;
  final Map<String, dynamic>? me;
  final String token;
  final IO.Socket? socket;
  final bool openAddMembersOnStart;
  final bool embedded;
  final VoidCallback? onClose;
  final void Function(int memberCount)? onMembersChanged;
  const GroupChatScreen({
    super.key,
    required this.group,
    required this.me,
    required this.token,
    required this.socket,
    this.openAddMembersOnStart = false,
    this.embedded = false,
    this.onClose,
    this.onMembersChanged,
  });
  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final List<Map<String, dynamic>> _messages = [];
  final _msgCtrl = TextEditingController();
  final _msgFocusNode = FocusNode();
  late final ClipboardImagePasteListener _clipboardImagePasteListener;
  final _scrollCtrl = ScrollController();
  bool _loading = true;
  bool _isAdmin = false;
  bool _isTyping = false;
  String _typingName = '';
  late final void Function(dynamic) _typingSocketHandler;
  late final void Function(dynamic) _scanRejectedSocketHandler;
  late final void Function(dynamic) _educationUpdatedSocketHandler;
  late final void Function(dynamic) _messageRejectedSocketHandler;
  List<Map<String, dynamic>> _members = [];
  String _myStatus = 'member'; // 'member' or 'pending'
  Map<String, dynamic>? _editingMsg;
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  bool _processingInvite = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  String _voiceFileName = 'voice_message.webm';
  Map<String, bool>? _groupReceivingFilter;

  String get _groupId => widget.group['id'] as String;

  @override
  void initState() {
    super.initState();
    _clipboardImagePasteListener = ClipboardImagePasteListener(
      focusNode: _msgFocusNode,
      onImage: (bytes, fileName, mimeType) => _uploadGroupFile(
        XFile.fromData(bytes, name: fileName, mimeType: mimeType),
        fileName,
        'image',
        extraFields: const {'clipboardPaste': 'true'},
      ),
    );
    _isAdmin = widget.group['role'] == 'admin';
    _myStatus = widget.group['status'] as String? ?? 'member';
    _reconcileGroupMembership();
    _setupSocket();
    if (_myStatus == 'member') {
      // A newly-created group is added after the socket connected, so its
      // creator is not yet in the room that was joined during connection.
      widget.socket?.emit('group:join', {'groupId': _groupId});
      widget.socket?.emit('group:viewed', {'groupId': _groupId});
      _loadMessages();
      _loadMembers();
      _loadGroupReceivingFilter();
    } else {
      // Do not reveal cached group content before an invitation is accepted.
      _loading = false;
    }
    if (_isAdmin) {
      if (widget.openAddMembersOnStart) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Future.delayed(const Duration(milliseconds: 250), () {
            if (mounted) _showAddMemberDialog();
          });
        });
      }
    }
  }

  Future<void> _reconcileGroupMembership() async {
    try {
      final response = await http.get(Uri.parse('$kApi/groups'),
          headers: {'Authorization': 'Bearer ${widget.token}'});
      if (!mounted || response.statusCode != 200) return;
      final groups =
          (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
      final currentIndex =
          groups.indexWhere((group) => group['id'] == _groupId);
      if (currentIndex == -1) return;
      final current = groups[currentIndex];
      final serverStatus = current['status']?.toString() ?? 'member';
      if (serverStatus == _myStatus) return;
      setState(() {
        _myStatus = serverStatus;
        widget.group['status'] = serverStatus;
      });
      if (serverStatus == 'member') {
        widget.socket?.emit('group:join', {'groupId': _groupId});
        widget.socket?.emit('group:viewed', {'groupId': _groupId});
        await Future.wait([
          _loadMessages(),
          _loadMembers(),
          _loadGroupReceivingFilter(),
        ]);
      }
    } catch (_) {}
  }

  Future<void> _loadGroupReceivingFilter() async {
    try {
      final response = await http.get(
        Uri.parse('$kApi/groups/$_groupId/filter-settings'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted || response.statusCode != 200) return;
      final body = jsonDecode(response.body);
      final raw = body is Map ? body['filter'] : null;
      if (raw is! Map) return;
      setState(() {
        _groupReceivingFilter = raw.map(
          (key, value) => MapEntry(key.toString(), value == true),
        );
      });
    } catch (_) {}
  }

  Future<void> _loadMembers() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/groups/$_groupId'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final members = (data['members'] as List).cast<Map<String, dynamic>>();
        setState(() {
          _members = members;
          widget.group['member_count'] = members.length;
          widget.group['profile_pic_url'] = data['profile_pic_url'];
        });
        widget.onMembersChanged?.call(members.length);
      }
    } catch (_) {}
  }

  Future<void> _addSelectedMembers(
      List<Map<String, dynamic>> selectedUsers) async {
    var invited = 0;
    for (final user in selectedUsers) {
      try {
        final res = await http.post(
          Uri.parse('$kApi/groups/$_groupId/members'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'userId': user['id']}),
        );
        if (res.statusCode == 200) invited++;
      } catch (_) {}
    }
    if (!mounted) return;
    await _loadMembers();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('נשלחו $invited הזמנות לקבוצה')),
    );
  }

  Map<String, dynamic> _mapMsg(dynamic m) {
    final map = m as Map<String, dynamic>;
    final isMe = map['sender_id'] == widget.me?['id'];
    return {
      'id': map['id'],
      'text': map['body'] ?? '',
      'senderName': map['sender_name'] ?? '',
      'time': _formatTime(map['created_at']),
      'createdAt': map['created_at']?.toString(),
      'isMe': isMe,
      'isUnread': !isMe && map['is_read'] != true && map['is_read'] != 1,
      'fileUrl': map['file_url'],
      'fileName': map['file_name'],
      'fileType': _normalizeIncomingFileType(map['type'] as String?,
          fileUrl: map['file_url'] as String?,
          fileName: map['file_name'] as String?),
      'educationFormId': map['education_form_id'],
      'educationResponseStatus': map['education_response_status'],
      if (map['reply_to_id'] != null)
        'replyTo': {
          'id': map['reply_to_id'],
          'text': map['reply_body'] ?? '',
        },
    };
  }

  Future<void> _acceptPending() async {
    if (_processingInvite) return;
    setState(() => _processingInvite = true);
    try {
      final res = await http.post(
        Uri.parse('$kApi/groups/$_groupId/join'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _myStatus = 'member';
          widget.group['status'] = 'member';
        });
        // Join socket room
        widget.socket?.emit('group:join', {'groupId': _groupId});
        widget.socket?.emit('group:viewed', {'groupId': _groupId});
        // Load missed messages
        final missed = (data['missedMessages'] as List? ?? [])
            .map((m) => _mapMsg(m))
            .toList();
        if (missed.isNotEmpty) {
          setState(() {
            _messages.insertAll(0, missed);
          });
        }
        await _loadMembers();
        await _loadMessages();
        await _loadGroupReceivingFilter();
        _scrollToBottom();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('ההצטרפות לקבוצה אושרה בהצלחה')));
        }
      } else if (mounted) {
        var message = 'אישור ההצטרפות נכשל';
        try {
          final data = jsonDecode(res.body);
          message = data['error']?.toString() ?? message;
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(message), backgroundColor: Colors.red));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('שגיאת חיבור בעת אישור ההצטרפות'),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _processingInvite = false);
    }
  }

  Future<void> _declinePending() async {
    try {
      final response = await http.delete(
        Uri.parse('$kApi/groups/$_groupId/decline'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (mounted && response.statusCode == 200) {
        _closeRemovedGroup();
      }
    } catch (_) {}
  }

  void _closeRemovedGroup() {
    if (!mounted) return;
    if (widget.embedded) {
      widget.onClose?.call();
      return;
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  Future<void> _removeMember(String userId, String userName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('הסרת חבר'),
        content: Text('להסיר את $userName מהקבוצה?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('הסרה'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      final res = await http.delete(
        Uri.parse('$kApi/groups/$_groupId/members/$userId'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        await _loadMembers();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$userName הוסר מהקבוצה')),
        );
      }
    } catch (_) {}
  }

  String _normalizePhone(String p) {
    String d = p.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('972') && d.length > 10) d = '0${d.substring(3)}';
    return d;
  }

  Future<void> _inviteExternalContact(
      String? phone, String? email, String contactName, String delivery) async {
    try {
      final res = await http.post(
        Uri.parse('$kApi/groups/$_groupId/invite-sms'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'phone': phone,
          'email': email,
          'contactName': contactName,
          'delivery': delivery,
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        if (delivery == 'whatsapp' || delivery == 'device_sms') {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          final message = data['message'] as String? ??
              'הצטרף אליי לאפליקציית בתשובה: $_appInviteUrl';
          final opened = delivery == 'whatsapp'
              ? await _openWhatsApp(phone!, message)
              : await launchUrl(_deviceSmsUri(phone!, message),
                  mode: LaunchMode.externalApplication);
          if (!opened) {
            await Clipboard.setData(ClipboardData(text: message));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content:
                    Text('לא ניתן לפתוח את אפליקציית השליחה. ההודעה הועתקה.'),
              ),
            );
          }
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(delivery == 'system_sms'
                  ? 'ההזמנה נשלחה ב־SMS ל$contactName'
                  : 'ההזמנה נשלחה באימייל ל$contactName')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('שגיאה בשליחת ההזמנה')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('שגיאת תקשורת')),
        );
      }
    }
  }

  bool _matchesQuery(Map<String, dynamic> u, String q) {
    if (q.isEmpty) return true;
    final name = (u['name'] as String? ?? '').toLowerCase();
    final phone = _normalizePhone(u['phone'] as String? ?? '');
    final email = (u['email'] as String? ?? '').toLowerCase();
    final normQ = _normalizePhone(q);
    return name.contains(q) ||
        email.contains(q) ||
        (normQ.isNotEmpty && phone.contains(normQ));
  }

  Future<void> _showAddMemberDialog() async {
    // Browser builds cannot read the device contact book, but registered app
    // users must still be available for selection.
    bool granted = false;
    if (!kIsWeb) {
      try {
        granted = await FlutterContacts.requestPermission(readonly: true);
      } catch (_) {
        granted = false;
      }
    }
    if (!mounted) return;

    // All registered users not in group
    List<Map<String, dynamic>> allUsers = [];
    // Unregistered device contacts — { name, phone, email }
    List<Map<String, dynamic>> unregistered = [];
    // IDs of users found via phone contacts (to show badge)
    Set<String> contactUserIds = {};

    // Always fetch all app users
    try {
      final res = await http.get(
        Uri.parse('$kApi/users/directory'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200) {
        allUsers = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {}

    if (granted) {
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      final Map<String, String> phoneToName = {};
      final Map<String, String> emailToName = {};
      for (final c in contacts) {
        for (final p in c.phones) {
          final norm = _normalizePhone(p.number);
          if (norm.length >= 9)
            phoneToName.putIfAbsent(norm, () => c.displayName);
        }
        for (final e in c.emails) {
          final email = e.address.trim().toLowerCase();
          if (email.contains('@')) {
            emailToName.putIfAbsent(email, () => c.displayName);
          }
        }
      }

      if (phoneToName.isNotEmpty || emailToName.isNotEmpty) {
        try {
          final res = await http.post(
            Uri.parse('$kApi/contacts/match'),
            headers: {
              'Authorization': 'Bearer ${widget.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'phones': phoneToName.keys.toList(),
              'emails': emailToName.keys.toList(),
            }),
          );
          if (res.statusCode == 200) {
            final matched =
                (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
            contactUserIds = matched.map((u) => u['id'] as String).toSet();
          }
        } catch (_) {}

        // Unregistered: contacts whose phones don't match any app user
        final appPhones = allUsers
            .map((u) => _normalizePhone(u['phone'] as String? ?? ''))
            .where((p) => p.isNotEmpty)
            .toSet();
        final appEmails = allUsers
            .map((u) => (u['email'] as String? ?? '').trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet();
        final byName = <String, Map<String, dynamic>>{};
        for (final entry in phoneToName.entries) {
          if (!appPhones.contains(entry.key)) {
            byName.putIfAbsent(
                entry.value, () => {'name': entry.value, 'phone': entry.key});
          }
        }
        for (final entry in emailToName.entries) {
          if (!appEmails.contains(entry.key)) {
            byName.putIfAbsent(
                entry.value, () => {'name': entry.value})['email'] = entry.key;
          }
        }
        unregistered = byName.values
            .where((c) => c['phone'] != null || c['email'] != null)
            .toList()
          ..sort(
              (a, b) => (a['name'] as String).compareTo(b['name'] as String));
      }
    }

    final memberIds = _members.map((m) => m['id'] as String).toSet();
    allUsers =
        allUsers.where((u) => !memberIds.contains(u['id'] as String)).toList()
          ..sort((a, b) {
            // contacts first, then alphabetical
            final aC = contactUserIds.contains(a['id']) ? 0 : 1;
            final bC = contactUserIds.contains(b['id']) ? 0 : 1;
            if (aC != bC) return aC - bC;
            return (a['name'] as String).compareTo(b['name'] as String);
          });

    if (!mounted) return;
    final searchCtrl = TextEditingController();
    final selectedIds = <String>{};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final query = searchCtrl.text.toLowerCase();
          final filteredReg =
              allUsers.where((u) => _matchesQuery(u, query)).toList();
          final filteredUnreg =
              unregistered.where((u) => _matchesQuery(u, query)).toList();

          return AlertDialog(
            title: const Text('הזמן לקבוצה'),
            contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: searchCtrl,
                      keyboardType: TextInputType.text,
                      decoration: const InputDecoration(
                        hintText: 'חיפוש לפי שם, טלפון או אימייל...',
                        hintTextDirection: TextDirection.rtl,
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (_) => setS(() {}),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 380),
                    child: (filteredReg.isEmpty && filteredUnreg.isEmpty)
                        ? const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('לא נמצאו אנשי קשר',
                                style: TextStyle(color: kSubtext)),
                          )
                        : ListView(
                            shrinkWrap: true,
                            children: [
                              // ── Registered users ──────────────────
                              if (filteredReg.isNotEmpty) ...[
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 8, 16, 4),
                                  child: Text('בתשובה',
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: kPrimary)),
                                ),
                                ...filteredReg.map((u) {
                                  final userId = u['id'] as String;
                                  final isContact =
                                      contactUserIds.contains(userId);
                                  final isSelected =
                                      selectedIds.contains(userId);
                                  final phone = u['phone'] as String? ?? '';
                                  return ListTile(
                                    selected: isSelected,
                                    selectedTileColor: const Color(0xFFE8F4FD),
                                    leading: UserAvatar(
                                      picUrl: u['profile_pic_url'] as String?,
                                      name: u['name'] as String,
                                    ),
                                    title: Text(u['name'] as String),
                                    subtitle: phone.isNotEmpty
                                        ? Text(phone,
                                            style: const TextStyle(
                                                fontSize: 11, color: kSubtext))
                                        : null,
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (isContact)
                                          const Padding(
                                            padding: EdgeInsets.only(left: 4),
                                            child: Icon(Icons.contacts_outlined,
                                                size: 14, color: kSubtext),
                                          ),
                                        Checkbox(
                                          value: isSelected,
                                          onChanged: (_) => setS(() {
                                            if (isSelected) {
                                              selectedIds.remove(userId);
                                            } else {
                                              selectedIds.add(userId);
                                            }
                                          }),
                                        ),
                                      ],
                                    ),
                                    onTap: () => setS(() {
                                      if (isSelected) {
                                        selectedIds.remove(userId);
                                      } else {
                                        selectedIds.add(userId);
                                      }
                                    }),
                                  );
                                }),
                              ],
                              // ── Unregistered contacts ─────────────
                              if (granted && filteredUnreg.isNotEmpty) ...[
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 12, 16, 4),
                                  child: Text('לא בתשובה',
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.grey[600])),
                                ),
                                ...filteredUnreg.map((c) => ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: Colors.grey[300],
                                        child: Text((c['name'] as String)[0],
                                            style: const TextStyle(
                                                color: Colors.white)),
                                      ),
                                      title: Text(c['name'] as String),
                                      subtitle: const Text('לא רשום בבתשובה',
                                          style: TextStyle(fontSize: 11)),
                                      trailing: TextButton.icon(
                                        icon: Icon(
                                            c['phone'] == null &&
                                                    c['email'] != null
                                                ? Icons.email_outlined
                                                : Icons.chat_outlined,
                                            size: 16),
                                        label: const Text('הזמן'),
                                        style: TextButton.styleFrom(
                                          foregroundColor: kPrimary,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 4),
                                        ),
                                        onPressed: () {
                                          Navigator.pop(ctx);
                                          _confirmAndInvite(
                                              c['phone'] as String?,
                                              c['email'] as String?,
                                              c['name'] as String);
                                        },
                                      ),
                                    )),
                              ],
                            ],
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('ביטול')),
              ElevatedButton.icon(
                onPressed: selectedIds.isEmpty
                    ? null
                    : () {
                        final selected = allUsers
                            .where((u) => selectedIds.contains(u['id']))
                            .toList();
                        Navigator.pop(ctx);
                        _addSelectedMembers(selected);
                      },
                icon: const Icon(Icons.group_add),
                label: Text(selectedIds.isEmpty
                    ? 'בחר חברים'
                    : 'הוסף ${selectedIds.length} נבחרים'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmAndInvite(
      String? phone, String? email, String contactName) async {
    final delivery = await _chooseInviteDelivery(
      context,
      hasPhone: phone?.trim().isNotEmpty == true,
      hasEmail: email?.contains('@') == true,
    );
    if (delivery == null || !mounted) return;
    _inviteExternalContact(phone, email, contactName, delivery);
  }

  void _showMembersDialog() {
    final myId = widget.me?['id'] as String?;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text('חברים בקבוצה (${_members.length})'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 400),
            child: _members.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _members.length,
                    itemBuilder: (_, i) {
                      final m = _members[i];
                      final isMe = m['id'] == myId;
                      final isAdminMember = m['role'] == 'admin';
                      return ListTile(
                        leading: UserAvatar(
                          picUrl: m['profile_pic_url'] as String?,
                          name: m['name'] as String,
                        ),
                        title: Text(m['name'] as String),
                        subtitle: Text(
                          '${isAdminMember ? 'מנהל · ' : ''}${_lastViewedLabel(m['last_viewed_at'])}',
                          style: TextStyle(
                              color: isAdminMember ? kPrimary : kSubtext,
                              fontSize: 12),
                        ),
                        trailing: (!isMe && !isAdminMember)
                            ? IconButton(
                                icon: const Icon(Icons.person_remove,
                                    color: Colors.red),
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _removeMember(
                                      m['id'] as String, m['name'] as String);
                                },
                              )
                            : null,
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('סגור')),
          ],
        ),
      ),
    );
  }

  String _lastViewedLabel(dynamic raw) {
    if (raw == null) return 'טרם צפה בקבוצה';
    final viewed = DateTime.tryParse(raw.toString())?.toLocal();
    if (viewed == null) return 'טרם צפה בקבוצה';
    final now = DateTime.now();
    final difference = now.difference(viewed);
    if (difference.inSeconds < 60) return 'צפה עכשיו';
    if (difference.inMinutes < 60) {
      return 'צפה לפני ${difference.inMinutes} דקות';
    }
    if (difference.inHours < 24 && viewed.day == now.day) {
      return 'צפה היום ב־${viewed.hour.toString().padLeft(2, '0')}:${viewed.minute.toString().padLeft(2, '0')}';
    }
    return 'צפה ב־${viewed.day.toString().padLeft(2, '0')}/${viewed.month.toString().padLeft(2, '0')} ${viewed.hour.toString().padLeft(2, '0')}:${viewed.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _loadMessages() async {
    final cacheKey = 'cache_group_msgs_${widget.me?['id']}_$_groupId';
    // Show cache immediately
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(cacheKey);
      if (cached != null && mounted) {
        final list = (jsonDecode(cached) as List).cast<Map<String, dynamic>>();
        setState(() {
          _messages
            ..clear()
            ..addAll(list);
          _loading = false;
        });
        _scrollToBottom();
      }
    } catch (_) {}
    // Fetch from server and update
    try {
      final res = await http.get(
        Uri.parse('$kApi/groups/$_groupId/messages'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        final normalized = data.map(_normalize).toList();
        _persistRecentImageUrls(normalized).ignore();
        setState(() {
          final pending = _messages
              .where((message) =>
                  message['id']?.toString().startsWith('temp_') == true)
              .toList();
          _messages.clear();
          _messages.addAll(normalized);
          for (final message in pending) {
            if (!_messages.any((saved) =>
                saved['fileUrl'] != null &&
                saved['fileUrl'] == message['fileUrl'])) {
              _messages.add(message);
            }
          }
          _loading = false;
        });
        http.put(
          Uri.parse('$kApi/groups/$_groupId/read'),
          headers: {'Authorization': 'Bearer ${widget.token}'},
        ).ignore();
        _scrollToBottom();
        // Save to cache
        final prefs = await SharedPreferences.getInstance();
        final toCache = normalized.length > 50
            ? normalized.sublist(normalized.length - 50)
            : normalized;
        await prefs.setString(cacheKey, jsonEncode(toCache));
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic> _normalize(dynamic m) {
    final map = m as Map<String, dynamic>;
    final isMe = map['sender_id'] == widget.me?['id'];
    return {
      'id': map['id'],
      'text': map['body'] ?? '',
      'senderName': map['sender_name'] ?? '',
      'time': _formatTime(map['created_at']),
      'createdAt': map['created_at']?.toString(),
      'isMe': isMe,
      'isUnread': !isMe && map['is_read'] != true && map['is_read'] != 1,
      'status': map['message_status'] ?? 'sent',
      if (map['scan_reason'] != null) 'scanReason': map['scan_reason'],
      if (map['image_classification'] != null)
        'classification': map['image_classification'],
      'isEdited': map['is_edited'] == true || map['is_edited'] == 1,
      'fileUrl': map['file_url'],
      'fileName': map['file_name'],
      'fileType': _normalizeIncomingFileType(map['type'] as String?,
          fileUrl: map['file_url'] as String?,
          fileName: map['file_name'] as String?),
      'educationFormId': map['education_form_id'],
      'educationResponseStatus': map['education_response_status'],
      'educationFormStatus': map['education_form_status'],
      if (map['reply_to_id'] != null)
        'replyTo': {
          'id': map['reply_to_id'],
          'text': map['reply_body'] ?? '',
        },
    };
  }

  String _formatTime(dynamic raw) {
    if (raw == null) return '';
    final dt = DateTime.tryParse(raw.toString());
    if (dt == null) return '';
    final l = dt.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  void _setupSocket() {
    widget.socket?.on('group:message', (data) {
      if (data['groupId'] != _groupId || !mounted) return;
      final fileUrl = data['fileUrl'] as String?;
      final fileName = data['fileName'] as String?;
      final fileType = _normalizeIncomingFileType(data['fileType'] as String?,
          fileUrl: fileUrl, fileName: fileName);
      final incoming = <String, dynamic>{
        'id': data['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        'text': data['text'] as String? ?? fileName ?? '',
        'senderName': data['fromName'] as String? ?? '',
        'time': data['createdAt'] != null
            ? _formatTime(data['createdAt'])
            : _nowTime(),
        'createdAt':
            data['createdAt']?.toString() ?? DateTime.now().toIso8601String(),
        'isMe': data['fromUserId'] == widget.me?['id'],
        'isUnread': false,
        'isTyping': false,
        'fileUrl': fileUrl,
        'fileName': fileName,
        'fileType': fileType,
        'educationFormId': data['formId'],
        'educationResponseStatus': data['educationResponseStatus'],
        if (data['classification'] != null)
          'classification': data['classification'],
      };
      setState(() {
        final clientMessageId = data['clientMessageId'] as String?;
        final existingIndex = clientMessageId == null
            ? -1
            : _messages.indexWhere((m) => m['id'] == clientMessageId);
        final pendingIndex = fileUrl == null
            ? -1
            : _messages.indexWhere((m) =>
                m['status'] == 'pending_scan' && m['fileUrl'] == fileUrl);
        if (existingIndex != -1) {
          final savedIndex =
              _messages.indexWhere((m) => m['id'] == incoming['id']);
          if (savedIndex != -1 && savedIndex != existingIndex) {
            _messages.removeAt(existingIndex);
          } else {
            _messages[existingIndex] = incoming;
          }
        } else if (pendingIndex != -1) {
          _messages[pendingIndex] = incoming;
        } else if (!_messages.any((m) => m['id'] == incoming['id'])) {
          _messages.add(incoming);
        }
        _isTyping = false;
      });
      _scrollToBottom();
    });

    _scanRejectedSocketHandler = (data) {
      if (!mounted || data is! Map || data['groupId'] != _groupId) return;
      final fileUrl = data['fileUrl'] as String?;
      if (fileUrl == null) return;
      final index = _messages.indexWhere((message) =>
          message['status'] == 'pending_scan' && message['fileUrl'] == fileUrl);
      if (index == -1) return;
      setState(() {
        _messages[index]['status'] = 'rejected_scan';
        _messages[index]['scanReason'] =
            data['reason']?.toString() ?? 'נדחתה בסריקה';
      });
    };
    widget.socket?.on('scan:rejected', _scanRejectedSocketHandler);
    _educationUpdatedSocketHandler = (data) {
      if (!mounted || data is! Map || data['groupId'] != _groupId) return;
      _loadMessages();
    };
    widget.socket?.on('education:updated', _educationUpdatedSocketHandler);

    _messageRejectedSocketHandler = (data) {
      if (!mounted || data is! Map || data['groupId']?.toString() != _groupId) {
        return;
      }
      final clientMessageId = data['clientMessageId']?.toString();
      if (clientMessageId != null) {
        setState(() => _messages.removeWhere(
            (message) => message['id']?.toString() == clientMessageId));
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(data['reason']?.toString() ?? 'ההודעה נחסמה'),
        backgroundColor: Colors.red.shade700,
      ));
    };
    widget.socket?.on('message:rejected', _messageRejectedSocketHandler);

    _typingSocketHandler = (data) {
      if (data['groupId'] == _groupId && mounted) {
        setState(() {
          _isTyping = true;
          _typingName = data['fromName'] as String? ?? '';
        });
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _isTyping = false);
        });
      }
    };
    widget.socket?.on('group:typing', _typingSocketHandler);

    widget.socket?.on('group:viewed', (data) {
      if (!mounted || data['groupId'] != _groupId) return;
      final memberIndex =
          _members.indexWhere((member) => member['id'] == data['userId']);
      if (memberIndex != -1) {
        setState(() {
          _members[memberIndex]['last_viewed_at'] = data['viewedAt'];
        });
      }
    });

    widget.socket?.on('group:member_joined', (data) {
      if (!mounted || data['groupId'] != _groupId) return;
      _loadMembers();
    });

    widget.socket?.on('message:edited', (data) {
      if (!mounted) return;
      final gid = data['groupId'] as String?;
      if (gid != null && gid != _groupId) return;
      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == data['id']);
        if (idx != -1) {
          _messages[idx]['text'] = data['body'] as String;
          _messages[idx]['isEdited'] = true;
        }
      });
    });

    widget.socket?.on('message:deleted', (data) {
      if (!mounted || data['groupId'] != _groupId) return;
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == data['id']);
        if (index != -1) {
          _messages[index]['text'] = '🚫 הודעה נמחקה';
          _messages[index]['fileUrl'] = null;
          _messages[index]['fileName'] = null;
          _messages[index]['fileType'] = 'text';
        }
      });
    });
  }

  @override
  void dispose() {
    _clipboardImagePasteListener.dispose();
    _recordTimer?.cancel();
    _audioRecorder.dispose();
    widget.socket?.off('group:message');
    widget.socket?.off('scan:rejected', _scanRejectedSocketHandler);
    widget.socket?.off('education:updated', _educationUpdatedSocketHandler);
    widget.socket?.off('message:rejected', _messageRejectedSocketHandler);
    widget.socket?.off('group:typing', _typingSocketHandler);
    widget.socket?.off('group:viewed');
    widget.socket?.off('group:member_joined');
    widget.socket?.off('message:edited');
    widget.socket?.off('message:deleted');
    _msgCtrl.dispose();
    _msgFocusNode.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  String _nowTime() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _toggleVoiceRecording() async {
    try {
      if (_isRecording) {
        _recordTimer?.cancel();
        final path = await _audioRecorder.stop();
        if (mounted) setState(() => _isRecording = false);
        if (path != null) {
          await _uploadGroupFile(XFile(path), _voiceFileName, 'audio');
        }
        return;
      }
      if (!kIsWeb && !await _audioRecorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('יש לאפשר גישה למיקרופון')));
        }
        return;
      }
      final path = kIsWeb
          ? ''
          : '${(await getTemporaryDirectory()).path}/voice_${DateTime.now().millisecondsSinceEpoch}.wav';
      var encoder = AudioEncoder.wav;
      if (kIsWeb) {
        if (!await _audioRecorder.isEncoderSupported(AudioEncoder.wav)) {
          throw Exception('הדפדפן אינו תומך בהקלטת אודיו');
        }
      }
      _voiceFileName = 'voice_message.wav';
      await _audioRecorder.start(
          RecordConfig(
              encoder: encoder,
              numChannels: 1,
              sampleRate: 16000,
              bitRate: 32000),
          path: path);
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _recordSeconds = 0;
      });
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordSeconds++);
      });
    } catch (error) {
      if (mounted) {
        setState(() => _isRecording = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('לא ניתן להפעיל את המיקרופון: $error')));
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.minScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;

    // Edit mode
    if (_editingMsg != null) {
      final msgId = _editingMsg!['id'] as String;
      final oldText = _editingMsg!['text'] as String;
      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == msgId);
        if (idx != -1) {
          _messages[idx]['text'] = text;
          _messages[idx]['isEdited'] = true;
        }
        _editingMsg = null;
        _msgCtrl.clear();
      });
      try {
        final res = await http.patch(
          Uri.parse('$kApi/messages/$msgId'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({'body': text}),
        );
        if (res.statusCode != 200 && mounted) {
          setState(() {
            final idx = _messages.indexWhere((m) => m['id'] == msgId);
            if (idx != -1) {
              _messages[idx]['text'] = oldText;
              _messages[idx]['isEdited'] = false;
            }
          });
        }
      } catch (_) {}
      return;
    }

    // Normal send
    final clientMessageId = 'temp_${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _messages.add({
        'id': clientMessageId,
        'text': text,
        'senderName': widget.me?['name'] as String? ?? '',
        'time': _nowTime(),
        'createdAt': DateTime.now().toIso8601String(),
        'isMe': true,
      });
      _msgCtrl.clear();
    });
    widget.socket?.emit('group:message', {
      'groupId': _groupId,
      'text': text,
      'clientMessageId': clientMessageId,
    });
    _scrollToBottom();
  }

  void _showMessageOptions(Map<String, dynamic> msg) {
    final isMe = msg['isMe'] == true;
    final isText = msg['fileUrl'] == null;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.forward, color: kPrimary),
              title: const Text('העבר'),
              onTap: () {
                Navigator.pop(context);
                _forwardChatMessage(context, widget.token, widget.socket, msg);
              },
            ),
            if (msg['fileType'] == 'image' &&
                msg['fileUrl'] != null &&
                msg['status'] != 'pending_scan' &&
                msg['status'] != 'rejected_scan' &&
                msg['id']?.toString().startsWith('temp_') != true)
              ListTile(
                leading:
                    const Icon(Icons.account_circle_outlined, color: kPrimary),
                title: const Text('הגדר כתמונת פרופיל'),
                onTap: () {
                  Navigator.pop(context);
                  _setMessageImageAsProfile(
                      context, widget.token, msg, widget.me);
                },
              ),
            if (!isMe &&
                msg['id'] != null &&
                msg['id']?.toString().startsWith('temp_') != true)
              ListTile(
                leading: const Icon(Icons.flag_outlined, color: Colors.orange),
                title: const Text('דווח על ההודעה'),
                onTap: () {
                  Navigator.pop(context);
                  _showReportDialog(
                    context: context,
                    token: widget.token,
                    targetType: 'message',
                    targetId: msg['id'].toString(),
                    targetLabel: 'ההודעה בקבוצה',
                  );
                },
              ),
            if (isMe && isText)
              ListTile(
                leading: const Icon(Icons.edit_outlined, color: kPrimary),
                title: const Text('ערוך הודעה'),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _editingMsg = msg;
                    _msgCtrl.text = msg['text'] as String? ?? '';
                  });
                },
              ),
            if (msg['id']?.toString().startsWith('temp_') != true)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('מחק אצלי'),
                onTap: () {
                  Navigator.pop(context);
                  _deleteGroupMessage(msg, forEveryone: false);
                },
              ),
            if (isMe && msg['id']?.toString().startsWith('temp_') != true)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('מחק אצל כולם',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteGroupMessage(msg, forEveryone: true);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteGroupMessage(Map<String, dynamic> message,
      {required bool forEveryone}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('מחיקת הודעה'),
        content: Text(forEveryone
            ? 'למחוק את ההודעה אצל כל חברי הקבוצה?'
            : 'למחוק את ההודעה רק אצלך?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('ביטול'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('מחק'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final response = await http.delete(
        Uri.parse('$kApi/messages/${message['id']}'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'forEveryone': forEveryone}),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() {
          if (forEveryone) {
            message['text'] = '🚫 הודעה נמחקה';
            message['fileUrl'] = null;
            message['fileName'] = null;
            message['fileType'] = 'text';
          } else {
            _messages.removeWhere((item) => item['id'] == message['id']);
          }
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('לא ניתן למחוק את ההודעה')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('שגיאת תקשורת במחיקת ההודעה')),
        );
      }
    }
  }

  Future<void> _showGroupExpressions() async {
    final choice = await _showExpressionPicker(context, widget.token);
    if (choice == null || !mounted) return;
    if (choice.startsWith(_originalExpressionPrefix)) {
      final assetPath = choice.substring(_originalExpressionPrefix.length);
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();
      final extension = assetPath.endsWith('.gif') ? 'gif' : 'png';
      final fileName =
          'betshuva_${assetPath.split('/').last.replaceAll('.$extension', '')}.$extension';
      final file =
          XFile.fromData(bytes, name: fileName, mimeType: 'image/$extension');
      await _uploadGroupFile(file, fileName, 'image', extraFields: const {
        'builtinExpression': 'true',
      });
      return;
    }
    if (choice == _gifPickerAction) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['gif'],
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      await _uploadGroupFile(file.xFile, file.name, 'image');
      return;
    }
    if (choice == _sharedGifUploadAction) {
      final details = await _requestSharedGifDetails(context);
      if (details == null || !mounted) return;
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['gif'],
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      await _uploadGroupFile(file.xFile, file.name, 'image', extraFields: {
        'sharedGif': 'true',
        'rightsConfirmed': 'true',
        'sharedGifTitle': details['title']!,
        'sharedGifTags': details['tags']!,
      });
      return;
    }
    if (choice == _personalStickerAction) {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 90,
      );
      if (picked != null) {
        await _uploadGroupFile(picked, 'sticker_${picked.name}', 'image');
      }
      return;
    }
    if (choice.startsWith(_sharedGifPrefix)) {
      final gif = jsonDecode(utf8.decode(base64Url.decode(
              base64Url.normalize(choice.substring(_sharedGifPrefix.length)))))
          as Map<String, dynamic>;
      await _applyGroupUploadResult(
        _FileUploadResult(_FileUploadOutcome.approved,
            data: {'url': gif['preview_url']}),
        gif['file_name'] as String? ?? '${gif['title']}.gif',
        'image',
        true,
      );
      http.post(Uri.parse('$kApi/gifs/${gif['id']}/use'),
          headers: {'Authorization': 'Bearer ${widget.token}'}).ignore();
      return;
    }
    if (choice.startsWith(_stickerPrefix)) {
      _msgCtrl.text = choice.substring(_stickerPrefix.length);
      await _send();
      return;
    }
    final selection = _msgCtrl.selection;
    final start = selection.isValid ? selection.start : _msgCtrl.text.length;
    final end = selection.isValid ? selection.end : _msgCtrl.text.length;
    final next = _msgCtrl.text.replaceRange(start, end, choice);
    _msgCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + choice.length),
    );
  }

  void _showAttachMenu() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('שיתוף קובץ בקבוצה',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _AttachOption(
                  icon: Icons.image_outlined,
                  label: 'גלריה (עד 10)',
                  color: kPrimary,
                  onTap: () {
                    Navigator.pop(context);
                    _pickFile(ImageSource.gallery);
                  },
                ),
                _AttachOption(
                  icon: Icons.camera_alt_outlined,
                  label: 'מצלמה',
                  color: kPrimaryMid,
                  onTap: () {
                    Navigator.pop(context);
                    _pickFile(ImageSource.camera);
                  },
                ),
                _AttachOption(
                  icon: Icons.picture_as_pdf_outlined,
                  label: 'מסמך',
                  color: Colors.orange,
                  onTap: () {
                    Navigator.pop(context);
                    _pickDocument();
                  },
                ),
              ],
            ),
            const SizedBox(height: 14),
            _AttachOption(
              icon: Icons.contact_phone_outlined,
              label: 'שתף איש קשר',
              color: Colors.teal,
              onTap: () async {
                Navigator.pop(context);
                final contact =
                    await _pickGroupSharedContact(context, _members);
                if (contact == null || !mounted) return;
                _msgCtrl.text = _sharedContactText(contact);
                await _send();
              },
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(children: [
                Icon(Icons.block, color: Colors.red.shade600, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('שליחת סרטוני וידאו אינה נתמכת',
                      style: TextStyle(fontSize: 12, color: Colors.red)),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFile(ImageSource source) async {
    final picker = ImagePicker();
    if (source == ImageSource.gallery) {
      final picked = await picker.pickMultiImage(
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
        limit: _maxBatchImages,
      );
      if (picked.isEmpty) return;
      final selected = picked.take(_maxBatchImages).toList();
      if (picked.length > _maxBatchImages && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('ניתן להעלות עד 20 תמונות בכל פעם',
              textDirection: TextDirection.rtl),
        ));
      }
      await _uploadGroupImageBatch(selected);
      return;
    }

    final picked = await picker.pickImage(
        source: source, maxWidth: 1920, maxHeight: 1920, imageQuality: 85);
    if (picked != null) {
      await _uploadGroupFile(picked, picked.name, 'image');
    }
  }

  Future<void> _uploadGroupImageBatch(List<XFile> files) async {
    if (!mounted || files.isEmpty) return;
    final completed = ValueNotifier<int>(0);
    await _runImageUploadQueue(
      files,
      (file) => _uploadFileRequest(
        file: file,
        fileName: file.name,
        token: widget.token,
        fields: {'groupId': _groupId},
      ),
      completed,
      onResult: (index, file, result) =>
          _applyGroupUploadResult(result, file.name, 'image', false),
    );
    completed.dispose();
    if (!mounted) return;
  }

  Future<void> _pickDocument() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'docx']);
    if (result == null) return;
    final f = result.files.single;
    await _uploadGroupFile(f, f.name, 'document');
  }

  Future<void> _uploadGroupFile(dynamic file, String fileName, String fileType,
      {Map<String, String> extraFields = const {}}) async {
    if (!mounted) return;
    final isClipboardPaste = extraFields['clipboardPaste'] == 'true';
    final showProgress = fileType != 'image' || isClipboardPaste;
    final navigator =
        showProgress ? Navigator.of(context, rootNavigator: true) : null;
    final dialogFuture = showProgress
        ? showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => PopScope(
              canPop: false,
              child: AlertDialog(
                title: const Row(children: [
                  Icon(Icons.security, color: kPrimary),
                  SizedBox(width: 8),
                  Text('סריקה והעלאה'),
                ]),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(color: kPrimary),
                  const SizedBox(height: 16),
                  Text('$fileName\nעובר בדיקת תוכן לא ראוי והעלאה...'),
                ]),
              ),
            ),
          )
        : null;
    final result = await _uploadFileRequest(
      file: file,
      fileName: fileName,
      token: widget.token,
      fields: {'groupId': _groupId, ...extraFields},
    );
    if (navigator != null && navigator.mounted && navigator.canPop()) {
      navigator.pop();
    }
    if (dialogFuture != null) await dialogFuture;
    if (!mounted) return;
    await _applyGroupUploadResult(
        result, fileName, fileType, fileType != 'image' || isClipboardPaste);
  }

  Future<void> _applyGroupUploadResult(_FileUploadResult result,
      String fileName, String fileType, bool showNotice) async {
    final data = result.data;
    final fileUrl = data['url'] as String?;
    switch (result.outcome) {
      case _FileUploadOutcome.failed:
        if (showNotice) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(result.error ?? 'שגיאה בהעלאה'),
              backgroundColor: Colors.red));
        }
        return;
      case _FileUploadOutcome.rejected:
        setState(() {
          final existingIndex = fileUrl == null
              ? -1
              : _messages
                  .indexWhere((message) => message['fileUrl'] == fileUrl);
          if (existingIndex != -1) {
            _messages[existingIndex]['status'] = 'rejected_scan';
            _messages[existingIndex]['scanReason'] = data['reason'];
          } else {
            _messages.add({
              'id': _newUploadMessageId('temp_group_file_'),
              'text': fileName,
              'senderName': widget.me?['name'] as String? ?? '',
              'time': _nowTime(),
              'createdAt': DateTime.now().toIso8601String(),
              'isMe': true,
              'status': 'rejected_scan',
              'scanReason': data['reason'],
              if (data['classification'] != null)
                'classification': data['classification'],
              'fileType': fileType,
              'fileUrl': fileUrl,
              'fileName': fileName,
              if (data['classification'] != null)
                'classification': data['classification'],
            });
          }
        });
        _scrollToBottom();
        if (showNotice) {
          _showGroupBlockedDialog(
              data['reason'] as String? ?? 'התמונה לא נשלחה');
        }
        return;
      case _FileUploadOutcome.pending:
        setState(() {
          final existingIndex = fileUrl == null
              ? -1
              : _messages
                  .indexWhere((message) => message['fileUrl'] == fileUrl);
          if (existingIndex != -1) {
            _messages[existingIndex]['status'] = 'pending_scan';
          } else {
            _messages.add({
              'id': _newUploadMessageId('temp_group_file_'),
              'text': fileName,
              'senderName': widget.me?['name'] as String? ?? '',
              'time': _nowTime(),
              'createdAt': DateTime.now().toIso8601String(),
              'isMe': true,
              'status': 'pending_scan',
              'fileType': fileType,
              'fileUrl': fileUrl,
              'fileName': fileName,
              if (data['classification'] != null)
                'classification': data['classification'],
            });
          }
        });
        _scrollToBottom();
        if (showNotice) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'הקובץ בהמתנה לסריקה — יישלח לקבוצה אוטומטית לאחר אישור',
                textDirection: TextDirection.rtl),
            backgroundColor: Colors.orange,
          ));
        }
        return;
      case _FileUploadOutcome.scanBot:
      case _FileUploadOutcome.approved:
        Map<String, dynamic> sendData = const <String, dynamic>{};
        try {
          final response = await http
              .post(
                Uri.parse('$kApi/groups/$_groupId/messages'),
                headers: {
                  'Authorization': 'Bearer ${widget.token}',
                  'Content-Type': 'application/json',
                },
                body: jsonEncode({
                  'fileUrl': fileUrl,
                  'fileName': fileName,
                  'fileType': fileType,
                }),
              )
              .timeout(const Duration(seconds: 30));
          try {
            final decoded = jsonDecode(response.body);
            if (decoded is Map<String, dynamic>) sendData = decoded;
          } catch (_) {}
          if (response.statusCode != 200) {
            result.outcome = _FileUploadOutcome.failed;
            result.error =
                sendData['error']?.toString() ?? 'הקובץ הועלה אך לא נשלח';
            if (showNotice && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(result.error!), backgroundColor: Colors.red));
            }
            return;
          }
        } catch (error) {
          result.outcome = _FileUploadOutcome.failed;
          result.error = 'הקובץ הועלה אך לא נשלח: $error';
          if (showNotice && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(result.error!), backgroundColor: Colors.red));
          }
          return;
        }
        if (!mounted) return;
        final messageId =
            sendData['id'] ?? _newUploadMessageId('temp_group_file_');
        setState(() {
          _messages.removeWhere((message) =>
              message['fileUrl'] == fileUrl &&
              message['status'] == 'pending_scan' &&
              message['id'] != messageId);
          if (!_messages.any((message) => message['id'] == messageId)) {
            _messages.add({
              'id': messageId,
              'text': fileName,
              'senderName': widget.me?['name'] as String? ?? '',
              'time': _nowTime(),
              'createdAt': sendData['createdAt']?.toString() ??
                  DateTime.now().toIso8601String(),
              'isMe': true,
              'status': sendData['status'] ?? 'sent',
              'fileType': fileType,
              'fileUrl': fileUrl,
              'fileName': fileName,
              if (data['classification'] != null)
                'classification': data['classification'],
            });
          }
        });
        _scrollToBottom();
        return;
    }
  }

  void _showGroupBlockedDialog(String reason) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                    color: Color(0xFFFFE8E8), shape: BoxShape.circle),
                child: const Icon(Icons.shield,
                    size: 38, color: Color(0xFFB91C1C)),
              ),
              const SizedBox(height: 16),
              const Text('התמונה נחסמה',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0D2137))),
              const SizedBox(height: 10),
              Text(reason,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 14, color: Color(0xFF4B5563), height: 1.5)),
              const SizedBox(height: 8),
              const Text('אנא בחר תמונה אחרת',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Color(0xFF8AAFC9))),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(_),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kPrimary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('הבנתי',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _leaveGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('יציאה מקבוצה'),
        content: Text('האם לצאת מ"${widget.group['name']}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('יציאה'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final response = await http.delete(
        Uri.parse('$kApi/groups/$_groupId/leave'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        _closeRemovedGroup();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('לא ניתן לצאת מהקבוצה')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('שגיאת תקשורת ביציאה מהקבוצה')),
        );
      }
    }
  }

  Future<void> _deleteGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('מחיקת קבוצה'),
        content: Text(
          'למחוק לצמיתות את "${widget.group['name']}"?\nכל ההודעות והחברים בקבוצה יימחקו.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('ביטול'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('מחק קבוצה'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      final response = await http.delete(
        Uri.parse('$kApi/groups/$_groupId'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('הקבוצה נמחקה')),
        );
        _closeRemovedGroup();
        return;
      }

      var message = 'לא ניתן למחוק את הקבוצה';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] != null) {
          message = body['error'].toString();
        }
      } catch (_) {}
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('שגיאת תקשורת במחיקת הקבוצה')),
        );
      }
    }
  }

  Future<void> _changeGroupPhoto() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(
            title: Text('תמונת קבוצה',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined, color: kPrimary),
            title: const Text('בחר מהגלריה'),
            subtitle: const Text('התמונה תעבור סריקת תוכן'),
            onTap: () => Navigator.pop(context, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.emoji_nature_outlined, color: kPrimary),
            title: const Text('בחר מאוסף אווטארים'),
            onTap: () => Navigator.pop(context, 'collection'),
          ),
          if (widget.group['profile_pic_url'] != null)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('הסר תמונה'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;

    String? newUrl;
    if (choice == 'collection') {
      newUrl = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (_) => const AvatarPickerSheet(),
      );
      if (newUrl == null) return;
    } else if (choice == 'gallery') {
      final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 512,
          maxHeight: 512,
          imageQuality: 80);
      if (picked == null || !mounted) return;
      try {
        final bytes = await picked.readAsBytes();
        final request = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
          ..headers['Authorization'] = 'Bearer ${widget.token}'
          ..fields['groupId'] = _groupId
          ..files.add(http.MultipartFile.fromBytes('file', bytes,
              filename: picked.name,
              contentType: _mimeFromFileName(picked.name)));
        final streamed =
            await request.send().timeout(const Duration(seconds: 60));
        final body = await streamed.stream.bytesToString();
        if (!mounted) return;
        if (streamed.statusCode != 200) {
          Map<String, dynamic>? data;
          try {
            data = jsonDecode(body) as Map<String, dynamic>;
          } catch (_) {}
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(data?['error']?.toString() ?? 'התמונה לא אושרה')));
          return;
        }
        final data = jsonDecode(body) as Map<String, dynamic>;
        if (data['status'] == 'pending') {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('התמונה ממתינה לאישור הסריקה')));
          return;
        }
        newUrl = data['url'] as String?;
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('שגיאה בהעלאת התמונה. נא לנסות שוב')));
        }
        return;
      }
    }

    final response = await http.put(
      Uri.parse('$kApi/groups/$_groupId/photo'),
      headers: {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'profile_pic_url': newUrl}),
    );
    if (response.statusCode == 200 && mounted) {
      setState(() => widget.group['profile_pic_url'] = newUrl);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('תמונת הקבוצה עודכנה')));
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('לא ניתן היה לשמור את תמונת הקבוצה')));
    }
  }

  Future<void> _renameGroup() async {
    final controller =
        TextEditingController(text: widget.group['name']?.toString() ?? '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('שינוי שם הקבוצה'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          textDirection: TextDirection.rtl,
          decoration: const InputDecoration(labelText: 'שם חדש'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('ביטול')),
          ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('שמור')),
        ],
      ),
    );
    final name = controller.text.trim();
    controller.dispose();
    if (confirmed != true || name.length < 2 || !mounted) return;
    final response = await http.patch(
      Uri.parse('$kApi/groups/$_groupId/name'),
      headers: {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'name': name}),
    );
    if (!mounted) return;
    if (response.statusCode == 200) {
      setState(() => widget.group['name'] = name);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('שם הקבוצה עודכן')));
      return;
    }
    var error = 'לא ניתן לשנות את שם הקבוצה';
    try {
      error = (jsonDecode(response.body) as Map)['error']?.toString() ?? error;
    } catch (_) {}
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  void _showAdminPanel() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ניהול: ${widget.group['name']}',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_isAdmin)
              ListTile(
                leading: const Icon(Icons.edit_outlined, color: kPrimary),
                title: const Text('שינוי שם הקבוצה'),
                onTap: () {
                  Navigator.pop(context);
                  _renameGroup();
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline, color: kPrimary),
              title: const Text('פרטי הקבוצה'),
              subtitle: Text('${_members.length} חברים'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ContentFilterSettingsScreen(
                      token: widget.token,
                      groupId: _groupId,
                      groupName: widget.group['name'] as String?,
                      groupPhotoUrl: widget.group['profile_pic_url'] as String?,
                      groupMembers: _members,
                      onAddGroupMember: _isAdmin ? _showAddMemberDialog : null,
                      onManageGroupMembers: _showMembersDialog,
                      onChangeGroupPhoto: _isAdmin ? _changeGroupPhoto : null,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.search, color: kPrimary),
              title: const Text('חיפוש בהודעות'),
              onTap: () {
                Navigator.pop(context);
                _searchGroupMessages();
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.notifications_off_outlined, color: kPrimary),
              title: const Text('השתקת התראות'),
              onTap: () async {
                Navigator.pop(context);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('muted_group_$_groupId', true);
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('התראות הקבוצה הושתקו')),
                  );
              },
            ),
            if (_isAdmin) ...[
              ListTile(
                leading:
                    const Icon(Icons.add_a_photo_outlined, color: kPrimary),
                title: const Text('שינוי תמונת הקבוצה'),
                subtitle: const Text('כל תמונה נסרקת לפני הצגתה'),
                onTap: () {
                  Navigator.pop(context);
                  _changeGroupPhoto();
                },
              ),
              ListTile(
                leading: const Icon(Icons.person_add_outlined, color: kPrimary),
                title: const Text('הוסף חבר'),
                onTap: () {
                  Navigator.pop(context);
                  _showAddMemberDialog();
                },
              ),
              ListTile(
                leading: const Icon(Icons.group_outlined, color: kPrimary),
                title: const Text('ניהול חברים'),
                subtitle: Text('${_members.length} חברים'),
                onTap: () {
                  Navigator.pop(context);
                  _showMembersDialog();
                },
              ),
              ListTile(
                leading: const Icon(Icons.tune, color: kPrimary),
                title: const Text('הגדרות שליחה'),
                subtitle: Text(widget.group['send_permission'] == 'admin'
                    ? 'מנהלים בלבד'
                    : 'כולם יכולים לשלוח'),
                onTap: () => Navigator.pop(context),
              ),
              ListTile(
                leading:
                    const Icon(Icons.campaign_outlined, color: Colors.orange),
                title: const Text('מצב ברודקסט'),
                subtitle: Text(
                    widget.group['is_broadcast'] == true ? 'פעיל' : 'לא פעיל'),
                onTap: () => Navigator.pop(context),
              ),
              ListTile(
                leading: const Icon(Icons.shield_outlined, color: kPrimary),
                title: const Text('רמת סינון תוכן'),
                subtitle: Text(widget.group['filter_level'] == 'strict'
                    ? 'מחמיר'
                    : 'רגיל'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ContentFilterSettingsScreen(
                        token: widget.token,
                        groupId: _groupId,
                        groupName: widget.group['name'] as String?,
                        groupPhotoUrl:
                            widget.group['profile_pic_url'] as String?,
                        groupMembers: _members,
                        onAddGroupMember: _showAddMemberDialog,
                        onManageGroupMembers: _showMembersDialog,
                        onChangeGroupPhoto: _changeGroupPhoto,
                      ),
                    ),
                  );
                },
              ),
              const Divider(),
            ],
            ListTile(
              leading: const Icon(Icons.exit_to_app, color: Colors.red),
              title: const Text('יציאה מקבוצה',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _leaveGroup();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showGroupDetailsPanel() async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'סגירת פרטי הקבוצה',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dialogContext, _, __) => Directionality(
        textDirection: TextDirection.rtl,
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: math.min(470, MediaQuery.sizeOf(context).width * .94),
            height: MediaQuery.sizeOf(context).height,
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(22),
                bottomRight: Radius.circular(22),
              ),
              child: Material(
                color: Colors.white,
                child: ContentFilterSettingsScreen(
                  token: widget.token,
                  groupId: _groupId,
                  groupName: widget.group['name'] as String?,
                  groupPhotoUrl: widget.group['profile_pic_url'] as String?,
                  groupMembers: _members,
                  onAddGroupMember: _isAdmin ? _showAddMemberDialog : null,
                  onManageGroupMembers: _showMembersDialog,
                  onChangeGroupPhoto: _isAdmin ? _changeGroupPhoto : null,
                  onGroupRenamed: _isAdmin
                      ? (name) => setState(() => widget.group['name'] = name)
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (_, animation, __, child) => SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(-1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
        child: child,
      ),
    );
    if (mounted) await _loadGroupReceivingFilter();
  }

  Future<void> _handleGroupMenuAction(String action) async {
    switch (action) {
      case 'info':
        await _showGroupDetailsPanel();
        break;
      case 'members':
        _showMembersDialog();
        break;
      case 'education':
        await _openEducationForms();
        break;
      case 'filter':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ContentFilterSettingsScreen(
              token: widget.token,
              groupId: _groupId,
              groupName: widget.group['name'] as String?,
              groupPhotoUrl: widget.group['profile_pic_url'] as String?,
              groupMembers: _members,
              onAddGroupMember: _isAdmin ? _showAddMemberDialog : null,
              onManageGroupMembers: _showMembersDialog,
              onChangeGroupPhoto: _isAdmin ? _changeGroupPhoto : null,
            ),
          ),
        );
        await _loadGroupReceivingFilter();
        break;
      case 'search':
        _searchGroupMessages();
        break;
      case 'mute':
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('muted_group_$_groupId', true);
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('התראות הקבוצה הושתקו')),
          );
        break;
      case 'add':
        _showAddMemberDialog();
        break;
      case 'photo':
        _changeGroupPhoto();
        break;
      case 'delete':
        _deleteGroup();
        break;
      case 'report':
        await _showReportDialog(
          context: context,
          token: widget.token,
          targetType: 'group',
          targetId: _groupId,
          targetLabel: 'הקבוצה ${widget.group['name'] as String? ?? ''}',
        );
        break;
      case 'leave':
        _leaveGroup();
        break;
    }
  }

  Future<void> _openEducationForms() => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EducationFormsScreen(
            token: widget.token,
            groupId: _groupId,
            groupName: widget.group['name'] as String? ?? 'קבוצה',
            isAdmin: _isAdmin,
            socket: widget.socket,
          ),
        ),
      );

  Future<void> _openEducationAnnouncement(Map<String, dynamic> message) async {
    final directFormId = message['educationFormId']?.toString();
    if (directFormId != null && directFormId.isNotEmpty) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EducationFormDetailsScreen(
            token: widget.token,
            formId: directFormId,
            isAdmin: _isAdmin,
            socket: widget.socket,
          ),
        ),
      );
      if (mounted) await _loadMessages();
      return;
    }
    final text = message['text']?.toString() ?? '';
    final firstLine = text.split('\n').first;
    final separator = firstLine.indexOf(':');
    final title =
        separator == -1 ? '' : firstLine.substring(separator + 1).trim();
    if (title.isEmpty) {
      await _openEducationForms();
      return;
    }
    try {
      final response = await http.get(
        Uri.parse('$kApi/groups/$_groupId/education-forms'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (response.statusCode != 200) throw Exception();
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final forms = (data['forms'] as List).cast<Map<String, dynamic>>();
      final matchIndex =
          forms.indexWhere((form) => form['title']?.toString().trim() == title);
      if (matchIndex == -1) throw Exception();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EducationFormDetailsScreen(
            token: widget.token,
            formId: forms[matchIndex]['id'] as String,
            isAdmin: _isAdmin,
            socket: widget.socket,
          ),
        ),
      );
      if (mounted) await _loadMessages();
    } catch (_) {
      if (mounted) await _openEducationForms();
    }
  }

  Future<void> _searchGroupMessages() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final query = controller.text.trim().toLowerCase();
          final matches = query.isEmpty
              ? <Map<String, dynamic>>[]
              : _messages
                  .where((m) => (m['text'] as String? ?? '')
                      .toLowerCase()
                      .contains(query))
                  .toList();
          return AlertDialog(
            title: const Text('חיפוש בהודעות הקבוצה'),
            content: SizedBox(
              width: 420,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(
                    hintText: 'הקלד טקסט לחיפוש...',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: query.isEmpty
                      ? const Text('')
                      : matches.isEmpty
                          ? const Text('לא נמצאו הודעות')
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: matches.length,
                              itemBuilder: (_, i) => ListTile(
                                dense: true,
                                title:
                                    Text(matches[i]['text'] as String? ?? ''),
                                subtitle: Text(
                                    matches[i]['senderName'] as String? ?? ''),
                                trailing:
                                    Text(matches[i]['time'] as String? ?? ''),
                              ),
                            ),
                ),
              ]),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('סגור'),
              )
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chat = Scaffold(
      backgroundColor: kChatBg,
      appBar: AppBar(
        backgroundColor: kPrimary,
        leading: BackButton(
            color: Colors.white,
            onPressed: widget.onClose ?? () => Navigator.pop(context)),
        title: Row(
          children: [
            Semantics(
              button: true,
              label: 'פתיחת פרטי הקבוצה',
              child: GestureDetector(
                onTap: () => _handleGroupMenuAction('info'),
                child: Tooltip(
                  message: 'פרטי הקבוצה',
                  child: UserAvatar(
                    radius: 19,
                    picUrl: widget.group['profile_pic_url'] as String?,
                    name: widget.group['name'] as String? ?? 'קבוצה',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.group['name'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      _AllowedReceivingFilterIcons(
                        filter: _groupReceivingFilter,
                        forGroup: true,
                      ),
                    ],
                  ),
                  Text(
                      _isTyping
                          ? '$_typingName מקליד...'
                          : '${widget.group['member_count'] ?? ''} חברים',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white70)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'אפשרויות קבוצה',
            position: PopupMenuPosition.under,
            constraints: const BoxConstraints(minWidth: 210, maxWidth: 250),
            onSelected: _handleGroupMenuAction,
            itemBuilder: (_) => [
              const PopupMenuItem(
                  value: 'info',
                  height: 40,
                  child: _CompactMenuItem(Icons.info_outline, 'פרטי הקבוצה')),
              const PopupMenuItem(
                  value: 'search',
                  height: 40,
                  child: _CompactMenuItem(Icons.search, 'חיפוש בהודעות')),
              const PopupMenuItem(
                  value: 'education',
                  height: 40,
                  child: _CompactMenuItem(
                      Icons.fact_check_outlined, 'אישורים, חתימות וסקרים')),
              const PopupMenuItem(
                  value: 'mute',
                  height: 40,
                  child: _CompactMenuItem(
                      Icons.notifications_off_outlined, 'השתקת התראות')),
              if (_isAdmin)
                const PopupMenuItem(
                    value: 'photo',
                    height: 40,
                    child: _CompactMenuItem(
                        Icons.add_a_photo_outlined, 'תמונת הקבוצה')),
              if (_isAdmin)
                const PopupMenuItem(
                    value: 'add',
                    height: 40,
                    child: _CompactMenuItem(
                        Icons.person_add_outlined, 'הוסף חברים')),
              if (_isAdmin)
                const PopupMenuItem(
                    value: 'members',
                    height: 40,
                    child:
                        _CompactMenuItem(Icons.groups_outlined, 'ניהול חברים')),
              if (_isAdmin)
                const PopupMenuItem(
                    value: 'filter',
                    height: 40,
                    child: _CompactMenuItem(
                        Icons.shield_outlined, 'הגדרות סינון')),
              const PopupMenuDivider(height: 8),
              if (!_isAdmin)
                const PopupMenuItem(
                    value: 'report',
                    height: 40,
                    child: _CompactMenuItem(
                        Icons.flag_outlined, 'דיווח על הקבוצה',
                        color: Colors.orange)),
              if (_isAdmin)
                const PopupMenuItem(
                    value: 'delete',
                    height: 40,
                    child: _CompactMenuItem(
                        Icons.delete_outline, 'מחיקת הקבוצה',
                        color: Colors.red)),
              const PopupMenuItem(
                  value: 'leave',
                  height: 40,
                  child: _CompactMenuItem(Icons.exit_to_app, 'יציאה מהקבוצה',
                      color: Colors.red)),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Pending banner ──────────────────────────────────────────
          if (_myStatus == 'pending')
            Container(
              width: double.infinity,
              color: const Color(0xFFFFF3CD),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'הוזמנת להצטרף לקבוצה זו',
                    style: const TextStyle(
                      color: Color(0xFF856404),
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    textDirection: TextDirection.rtl,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _declinePending,
                        style:
                            TextButton.styleFrom(foregroundColor: Colors.red),
                        child: const Text('דחה'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _processingInvite ? null : _acceptPending,
                        style:
                            ElevatedButton.styleFrom(backgroundColor: kPrimary),
                        child: _processingInvite
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Text('אשר הצטרפות',
                                style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: kPrimary))
                : _messages.isEmpty
                    ? const Center(
                        child: Text('אין הודעות עדיין',
                            style: TextStyle(color: kSubtext)))
                    : ListView.builder(
                        controller: _scrollCtrl,
                        reverse: true,
                        padding: const EdgeInsets.all(10),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) {
                          final messageIndex = _messages.length - 1 - i;
                          final msg = _messages[messageIndex];
                          final isMe = msg['isMe'] == true;
                          final groupText = msg['text'] as String? ?? '';
                          final sharedContact = msg['fileUrl'] == null
                              ? _sharedContactFromText(groupText)
                              : null;
                          final inviteLink = msg['fileUrl'] == null
                              ? RegExp(
                                      r'https://betshuva\.com/betshuva-app/invite-v2\.html\?invite=[\w-]+')
                                  .firstMatch(groupText)
                                  ?.group(0)
                              : null;
                          final isEducationAnnouncement =
                              (msg['text'] as String? ?? '').startsWith('📋 ');
                          final educationStatus =
                              msg['educationResponseStatus']?.toString();
                          final educationFormClosed =
                              msg['educationFormStatus'] == 'closed';
                          final educationStatusLabel = educationFormClosed
                              ? 'הטופס נסגר'
                              : _isAdmin
                                  ? 'ניהול מסמך'
                                  : educationStatus == 'declined'
                                      ? 'לא אושר'
                                      : educationStatus == 'approved' ||
                                              educationStatus == 'completed'
                                          ? 'בוצע'
                                          : 'ממתין לפעולה';
                          final educationStatusColor = educationFormClosed
                              ? Colors.blueGrey.shade700
                              : _isAdmin
                                  ? kPrimary
                                  : educationStatus == 'declined'
                                      ? Colors.red.shade700
                                      : educationStatus == 'approved' ||
                                              educationStatus == 'completed'
                                          ? Colors.green.shade700
                                          : Colors.orange.shade800;
                          var imageRunStart = messageIndex;
                          var imageRunEnd = messageIndex;
                          if (_isGridImageMessage(msg)) {
                            while (imageRunStart > 0 &&
                                _isGridImageMessage(
                                    _messages[imageRunStart - 1]) &&
                                _sameImageSequenceSender(
                                    msg, _messages[imageRunStart - 1])) {
                              imageRunStart--;
                            }
                            while (imageRunEnd + 1 < _messages.length &&
                                _isGridImageMessage(
                                    _messages[imageRunEnd + 1]) &&
                                _sameImageSequenceSender(
                                    msg, _messages[imageRunEnd + 1])) {
                              imageRunEnd++;
                            }
                            if (imageRunStart != imageRunEnd &&
                                messageIndex != imageRunEnd) {
                              return const SizedBox.shrink();
                            }
                          }
                          final imageSequence = imageRunEnd > imageRunStart
                              ? _messages.sublist(
                                  imageRunStart, imageRunEnd + 1)
                              : const <Map<String, dynamic>>[];
                          final firstUnreadIndex = _messages.indexWhere(
                              (message) => message['isUnread'] == true);
                          final dateIndex = imageSequence.isNotEmpty
                              ? imageRunStart
                              : messageIndex;
                          final showDate = dateIndex == 0 ||
                              !_sameMessageDay(_messages[dateIndex],
                                  _messages[dateIndex - 1]);
                          return Column(
                            crossAxisAlignment: isMe
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              if (showDate)
                                _DateDivider(label: _messageDateLabel(msg)),
                              if (firstUnreadIndex >= imageRunStart &&
                                  firstUnreadIndex <= imageRunEnd)
                                const _UnreadMessagesDivider(),
                              if (!isMe)
                                Padding(
                                  padding: const EdgeInsets.only(
                                      right: 8, bottom: 2),
                                  child: Text(
                                    msg['senderName'] as String? ?? '',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: kPrimary,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              if (imageSequence.isNotEmpty)
                                _ConsecutiveImageGrid(
                                    messages: imageSequence,
                                    conversationMessages: _messages,
                                    isMe: isMe,
                                    onForwardAll: () => _forwardChatMessages(
                                        context,
                                        widget.token,
                                        widget.socket,
                                        imageSequence),
                                    onMessageOptions: _showMessageOptions)
                              else
                                GestureDetector(
                                  onTap: isEducationAnnouncement
                                      ? () => _openEducationAnnouncement(msg)
                                      : !kIsWeb && msg['fileUrl'] == null
                                          ? () => _copyMessageText(context, msg)
                                          : null,
                                  onDoubleTap: !isEducationAnnouncement &&
                                          kIsWeb &&
                                          msg['fileUrl'] == null
                                      ? () => _copyMessageText(context, msg)
                                      : null,
                                  onLongPress: () => _showMessageOptions(msg),
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                    constraints: BoxConstraints(
                                        maxWidth:
                                            MediaQuery.of(context).size.width *
                                                0.75),
                                    decoration: BoxDecoration(
                                      color: isMe ? kGroupOutgoing : kIncoming,
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.05),
                                          blurRadius: 3,
                                        )
                                      ],
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        if (msg['fileUrl'] != null &&
                                            _normalizeIncomingFileType(
                                                    msg['fileType'] as String?,
                                                    fileUrl: msg['fileUrl']
                                                        as String?,
                                                    fileName: msg['fileName']
                                                        as String?) ==
                                                'audio')
                                          VoiceMessagePlayer(
                                              url: msg['fileUrl'] as String,
                                              isMe: isMe)
                                        else if (msg['fileUrl'] != null &&
                                            _normalizeIncomingFileType(
                                                    msg['fileType'] as String?,
                                                    fileUrl: msg['fileUrl']
                                                        as String?,
                                                    fileName: msg['fileName']
                                                        as String?) ==
                                                'image')
                                          GestureDetector(
                                            onTap: () => Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                    builder: (_) => ImagePreviewScreen(
                                                        url: msg['fileUrl']
                                                            as String,
                                                        filename:
                                                            msg['fileName']
                                                                as String?,
                                                        urls: _conversationImageMessages(_messages)
                                                            .map((item) =>
                                                                item['fileUrl']
                                                                    as String)
                                                            .toList(),
                                                        filenames:
                                                            _conversationImageMessages(_messages)
                                                                .map((item) =>
                                                                    item['fileName'] as String?)
                                                                .toList(),
                                                        dates: _conversationImageMessages(_messages).map((item) => _imageSentAtLabel(item)).toList(),
                                                        messages: _conversationImageMessages(_messages),
                                                        onMessageOptions: _showMessageOptions,
                                                        initialIndex: _conversationImageIndex(_conversationImageMessages(_messages), msg)))),
                                            child: Stack(
                                              children: [
                                                ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  child: _PersistentMediaImage(
                                                    url: msg['fileUrl']
                                                        as String,
                                                    width: 200,
                                                    fit: BoxFit.cover,
                                                    loadingBuilder: (_) => Container(
                                                        width: 200,
                                                        height: 140,
                                                        color: kBorder,
                                                        child: const Center(
                                                            child:
                                                                CircularProgressIndicator(
                                                                    color:
                                                                        kPrimary,
                                                                    strokeWidth:
                                                                        2))),
                                                    errorBuilder: (_) =>
                                                        Container(
                                                            width: 200,
                                                            height: 100,
                                                            color: kBorder,
                                                            child: const Icon(
                                                                Icons
                                                                    .broken_image,
                                                                color:
                                                                    kSubtext)),
                                                  ),
                                                ),
                                                Positioned(
                                                  left: 7,
                                                  bottom: 7,
                                                  child: _ImageStatusBadge(
                                                      message: msg, isMe: isMe),
                                                ),
                                              ],
                                            ),
                                          )
                                        else if (msg['fileUrl'] != null)
                                          InkWell(
                                            onTap: () => _downloadChatFile(
                                                context,
                                                msg['fileUrl'] as String,
                                                msg['fileName'] as String?),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      vertical: 4),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                      Icons.insert_drive_file,
                                                      size: 16,
                                                      color: kSubtext),
                                                  const SizedBox(width: 4),
                                                  Flexible(
                                                      child: Text(
                                                          msg['fileName']
                                                                  as String? ??
                                                              msg['text']
                                                                  as String? ??
                                                              '',
                                                          style:
                                                              const TextStyle(
                                                                  fontSize:
                                                                      13))),
                                                  const SizedBox(width: 10),
                                                  const Icon(Icons.download,
                                                      size: 19,
                                                      color: kPrimary),
                                                  const SizedBox(width: 3),
                                                  const Text('הורדה',
                                                      style: TextStyle(
                                                          fontSize: 12,
                                                          color: kPrimary,
                                                          fontWeight:
                                                              FontWeight.w600)),
                                                ],
                                              ),
                                            ),
                                          )
                                        else if (isEducationAnnouncement)
                                          InkWell(
                                            onTap: () =>
                                                _openEducationAnnouncement(msg),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      vertical: 4),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                children: [
                                                  Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      const Icon(
                                                          Icons
                                                              .fact_check_outlined,
                                                          color: kPrimary),
                                                      const SizedBox(width: 8),
                                                      Flexible(
                                                        child: Text(
                                                          msg['text']
                                                                  as String? ??
                                                              '',
                                                          style: const TextStyle(
                                                              fontSize: 15,
                                                              height: 1.4,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600),
                                                          textDirection:
                                                              TextDirection.rtl,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      const Icon(
                                                          Icons.touch_app,
                                                          size: 17,
                                                          color: kPrimary),
                                                      const SizedBox(width: 4),
                                                      const Text(
                                                          'לחץ לפתיחת המסמך',
                                                          style: TextStyle(
                                                              color: kPrimary,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold)),
                                                      const SizedBox(width: 12),
                                                      Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                                horizontal: 9,
                                                                vertical: 3),
                                                        decoration:
                                                            BoxDecoration(
                                                          color:
                                                              educationStatusColor
                                                                  .withOpacity(
                                                                      .12),
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(14),
                                                        ),
                                                        child: Text(
                                                          educationStatusLabel,
                                                          style: TextStyle(
                                                            color:
                                                                educationStatusColor,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            fontSize: 12,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                          )
                                        else if (sharedContact != null)
                                          _SharedContactCard(sharedContact)
                                        else
                                          Text(
                                            msg['text'] as String? ?? '',
                                            style: TextStyle(
                                                fontSize: _looksLikeSticker(
                                                        msg['text']
                                                                as String? ??
                                                            '')
                                                    ? 44
                                                    : 15,
                                                height: 1.4),
                                            textDirection: TextDirection.rtl,
                                          ),
                                        if (inviteLink != null) ...[
                                          const SizedBox(height: 8),
                                          _BetshuvaInvitePreview(inviteLink),
                                        ],
                                        const SizedBox(height: 4),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (msg['isEdited'] == true)
                                              const Text('נערך · ',
                                                  style: TextStyle(
                                                      fontSize: 10,
                                                      color: kSubtext,
                                                      fontStyle:
                                                          FontStyle.italic)),
                                            Text(msg['time'] as String? ?? '',
                                                style: const TextStyle(
                                                    fontSize: 11,
                                                    color: kSubtext)),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ), // GestureDetector
                            ],
                          );
                        },
                      ),
          ),
          // Edit mode bar (group)
          if (_editingMsg != null)
            Container(
              color: const Color(0xFFFFF8E1),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Container(
                      width: 3,
                      height: 36,
                      color: Colors.orange,
                      margin: const EdgeInsets.only(left: 8)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('עריכת הודעה',
                            style: TextStyle(
                                color: Colors.orange,
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                        Text(_editingMsg!['text'] as String? ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontSize: 13, color: kSubtext)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() {
                      _editingMsg = null;
                      _msgCtrl.clear();
                    }),
                  ),
                ],
              ),
            ),
          if (_isTyping && _myStatus == 'member')
            Container(
              width: double.infinity,
              color: kBg,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('$_typingName מקליד...',
                  style: const TextStyle(
                      fontSize: 12,
                      color: kSubtext,
                      fontStyle: FontStyle.italic),
                  textDirection: TextDirection.rtl),
            ),
          if (_myStatus == 'member')
            Container(
              color: kCard,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'סמיילים ומדבקות של בתשובה',
                    icon: const Icon(Icons.emoji_emotions_outlined,
                        color: kPrimary),
                    onPressed: _showGroupExpressions,
                  ),
                  IconButton(
                    icon: const Icon(Icons.attach_file, color: kSubtext),
                    onPressed: _showAttachMenu,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      focusNode: _msgFocusNode,
                      textDirection: TextDirection.rtl,
                      decoration: InputDecoration(
                        hintText: 'הודעה לקבוצה...',
                        hintTextDirection: TextDirection.rtl,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: kBg,
                      ),
                      onChanged: (_) => widget.socket
                          ?.emit('group:typing', {'groupId': _groupId}),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (_isRecording)
                    Text(
                      '${(_recordSeconds ~/ 60).toString().padLeft(2, '0')}:${(_recordSeconds % 60).toString().padLeft(2, '0')}',
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  IconButton(
                    tooltip: _isRecording ? 'סיים ושלח' : 'הקלט הודעה קולית',
                    onPressed: _toggleVoiceRecording,
                    icon: Icon(_isRecording ? Icons.stop_circle : Icons.mic,
                        color: _isRecording ? Colors.red : kPrimary),
                  ),
                  GestureDetector(
                    onTap: _send,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: kPrimary,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child:
                          const Icon(Icons.send, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 900 && !widget.embedded) {
      return ColoredBox(
        color: const Color(0xFFD9DBD5),
        child: Center(
          child: SizedBox(
            width: math.min(1000, width - 64),
            height: MediaQuery.sizeOf(context).height,
            child: chat,
          ),
        ),
      );
    }
    return chat;
  }
}

// ── Content filter settings ───────────────────────────────────────
class ContentFilterSettingsScreen extends StatefulWidget {
  final String token;
  final String? contactId;
  final String? contactName;
  final String? groupId;
  final String? groupName;
  final String? groupPhotoUrl;
  final List<Map<String, dynamic>> groupMembers;
  final VoidCallback? onAddGroupMember;
  final VoidCallback? onManageGroupMembers;
  final VoidCallback? onChangeGroupPhoto;
  final ValueChanged<String>? onGroupRenamed;
  final bool requireSave;
  const ContentFilterSettingsScreen(
      {super.key,
      required this.token,
      this.contactId,
      this.contactName,
      this.groupId,
      this.groupName,
      this.groupPhotoUrl,
      this.groupMembers = const [],
      this.onAddGroupMember,
      this.onManageGroupMembers,
      this.onChangeGroupPhoto,
      this.onGroupRenamed,
      this.requireSave = false});

  @override
  State<ContentFilterSettingsScreen> createState() =>
      _ContentFilterSettingsScreenState();
}

class _ContentFilterSettingsScreenState
    extends State<ContentFilterSettingsScreen> {
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;
  bool _inherit = true;
  late String _groupName = widget.groupName ?? 'קבוצה';
  Map<String, bool> _filter = {
    'text': true,
    'video': true,
    'nonHumanImages': true,
    'men': true,
    'women': true,
    'children': true,
  };

  bool get _isContact => widget.contactId != null;
  bool get _isGroup => widget.groupId != null;

  Future<void> _renameGroup() async {
    final controller = TextEditingController(text: _groupName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('שינוי שם הקבוצה'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          textDirection: TextDirection.rtl,
          decoration: const InputDecoration(
            labelText: 'שם הקבוצה',
            prefixIcon: Icon(Icons.groups_outlined),
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('ביטול'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('שמור'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name == _groupName) return;
    if (name.length < 2 || name.length > 80) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('שם הקבוצה חייב להכיל 2 עד 80 תווים')));
      }
      return;
    }
    try {
      final response = await http.patch(
        Uri.parse('$kApi/groups/${widget.groupId}/name'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'name': name}),
      );
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw Exception(data['error'] ?? 'שינוי השם נכשל');
      }
      if (!mounted) return;
      setState(() => _groupName = data['name']?.toString() ?? name);
      widget.onGroupRenamed?.call(_groupName);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('שם הקבוצה עודכן בהצלחה')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(error.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final path = _isGroup
          ? '/groups/${widget.groupId}/filter-settings'
          : _isContact
              ? '/contacts/${widget.contactId}/filter-settings'
              : '/filter-settings';
      final response = await http.get(Uri.parse('$kApi$path'),
          headers: {'Authorization': 'Bearer ${widget.token}'});
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) throw Exception(data['error'] ?? 'שגיאה');
      final raw = ((_isContact || _isGroup) ? data['filter'] : data)
          as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _inherit = _isContact ? data['inherited'] == true : false;
        for (final key in _filter.keys) {
          _filter[key] = raw[key] == true;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('טעינת ההגדרות נכשלה: $e')),
      );
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final path = _isGroup
          ? '/groups/${widget.groupId}/filter-settings'
          : _isContact
              ? '/contacts/${widget.contactId}/filter-settings'
              : '/filter-settings';
      final body = _isGroup
          ? {'filter': _filter}
          : _isContact
              ? (_inherit ? {'inherit': true} : {'filter': _filter})
              : _filter;
      final response = await http.put(Uri.parse('$kApi$path'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode(body));
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) throw Exception(data['error'] ?? 'שגיאה');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('הגדרות הסינון נשמרו')),
      );
      _saved = true;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, true);
      });
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שמירת ההגדרות נכשלה: $e')),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _filterSwitch({
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final enabled = onChanged != null;
    return Semantics(
      checked: value,
      enabled: enabled,
      button: true,
      child: InkWell(
        onTap: enabled ? () => onChanged(!value) : null,
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: value
                ? (enabled ? kPrimary : kPrimary.withValues(alpha: 0.42))
                : (enabled ? Colors.white : const Color(0xFFF0F3F6)),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: value
                  ? (enabled ? kPrimary : kPrimary.withValues(alpha: 0.38))
                  : const Color(0xFFABC3D5),
              width: 2,
            ),
            boxShadow: value && enabled
                ? const [
                    BoxShadow(
                      color: Color(0x351B6CA8),
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 180),
            scale: value ? 1 : 0,
            curve: Curves.easeOutBack,
            child: const Icon(Icons.check_rounded,
                color: Colors.white, size: 23, weight: 700),
          ),
        ),
      ),
    );
  }

  Widget _option(String key, String title, String subtitle, IconData icon) {
    final enabled = _filter[key] == true;
    final canChange = !_inherit;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Material(
        color: canChange ? kCard : const Color(0xFFF5F7F9),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap:
              canChange ? () => setState(() => _filter[key] = !enabled) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: enabled && canChange
                    ? kPrimary.withValues(alpha: 0.32)
                    : kBorder,
              ),
              boxShadow: canChange
                  ? const [
                      BoxShadow(
                        color: Color(0x0D0D5D91),
                        blurRadius: 12,
                        offset: Offset(0, 3),
                      )
                    ]
                  : null,
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: enabled
                        ? kPrimary.withValues(alpha: 0.12)
                        : const Color(0xFFF0F3F6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon,
                      color: enabled ? kPrimary : kSubtext, size: 23),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style:
                              const TextStyle(color: kSubtext, fontSize: 12.5)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: enabled
                        ? kPrimary.withValues(alpha: 0.10)
                        : const Color(0xFFF0F3F6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(enabled ? 'מותר' : 'חסום',
                      style: TextStyle(
                          color: enabled ? kPrimary : kSubtext,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 6),
                _filterSwitch(
                  value: enabled,
                  onChanged: canChange
                      ? (value) => setState(() => _filter[key] = value)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _groupOverview() {
    final members = widget.groupMembers.take(6).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: kBorder),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x120D5D91),
                  blurRadius: 14,
                  offset: Offset(0, 4)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('מאפייני הקבוצה',
                  style: TextStyle(
                      color: kPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              Row(children: [
                Stack(children: [
                  UserAvatar(
                    radius: 28,
                    picUrl: widget.groupPhotoUrl,
                    name: _groupName,
                  ),
                  if (widget.onChangeGroupPhoto != null)
                    Positioned(
                      left: 0,
                      bottom: 0,
                      child: InkWell(
                        onTap: widget.onChangeGroupPhoto,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: const BoxDecoration(
                              color: kPrimary, shape: BoxShape.circle),
                          child: const Icon(Icons.camera_alt_outlined,
                              size: 13, color: Colors.white),
                        ),
                      ),
                    ),
                ]),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(_groupName,
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w800)),
                        ),
                        if (widget.onGroupRenamed != null)
                          IconButton(
                            tooltip: 'שינוי שם הקבוצה',
                            onPressed: _renameGroup,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.edit_outlined,
                                color: kPrimary, size: 20),
                          ),
                      ]),
                      Text('${widget.groupMembers.length} חברים',
                          style:
                              const TextStyle(color: kSubtext, fontSize: 12)),
                    ],
                  ),
                ),
                if (widget.onChangeGroupPhoto != null)
                  IconButton(
                    tooltip: 'עריכת תמונת הקבוצה',
                    onPressed: widget.onChangeGroupPhoto,
                    icon: const Icon(Icons.edit_outlined,
                        color: kSubtext, size: 20),
                  ),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: kBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Expanded(
                  child: Text('חברי הקבוצה',
                      style: TextStyle(
                          color: kPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w800)),
                ),
                if (widget.onManageGroupMembers != null)
                  TextButton(
                    onPressed: widget.onManageGroupMembers,
                    child: const Text('ניהול'),
                  ),
              ]),
              const SizedBox(height: 8),
              SizedBox(
                height: 58,
                child: Row(children: [
                  if (widget.onAddGroupMember != null) ...[
                    InkWell(
                      onTap: widget.onAddGroupMember,
                      borderRadius: BorderRadius.circular(25),
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F3FA),
                          shape: BoxShape.circle,
                          border: Border.all(color: kBorder),
                        ),
                        child: const Icon(Icons.add, color: kPrimary),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: members.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (_, index) {
                        final member = members[index];
                        return UserAvatar(
                          radius: 24,
                          picUrl: member['profile_pic_url'] as String?,
                          name: member['name']?.toString() ?? 'חבר',
                        );
                      },
                    ),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.requireSave || _saved,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.requireSave) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(
                content: Text('יש לבחור ולשמור את סינון הקבוצה')));
        }
      },
      child: Scaffold(
        appBar: AppBar(
            title: Text(_isGroup
                ? 'הגדרות הקבוצה'
                : _isContact
                    ? 'סינון עבור ${widget.contactName ?? 'איש קשר'}'
                    : 'סינון תוכן כללי')),
        backgroundColor: kBg,
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(children: [
                  if (_isGroup) _groupOverview(),
                  if (_isContact) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                      child: Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: kBorder),
                        ),
                        child: ListTile(
                          leading:
                              const Icon(Icons.sync_rounded, color: kPrimary),
                          title: const Text('השתמש בהגדרות הכלליות',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: const Text(
                              'שינויים עתידיים בהגדרה הכללית יחולו גם כאן'),
                          trailing: _filterSwitch(
                            value: _inherit,
                            onChanged: (value) =>
                                setState(() => _inherit = value),
                          ),
                          onTap: () => setState(() => _inherit = !_inherit),
                        ),
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
                    child: Row(children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: kPrimary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child:
                            const Icon(Icons.shield_outlined, color: kPrimary),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('סוגי תוכן מותרים',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16)),
                            Text('גלול למטה כדי לראות את כל האפשרויות',
                                style:
                                    TextStyle(color: kSubtext, fontSize: 12)),
                          ],
                        ),
                      ),
                    ]),
                  ),
                  if (_isGroup)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(18, 8, 18, 12),
                      child: Text(
                        'הגדרת הקבוצה קובעת מה ניתן לשלוח לכל הקבוצה. בנוסף, כל חבר ממשיך להיות מוגן לפי הסינון האישי שלו; ההגדרה המחמירה מביניהן היא שקובעת.',
                        style: TextStyle(color: kSubtext),
                      ),
                    ),
                  _option(
                      'text', 'טקסט', 'הודעות טקסט רגילות', Icons.text_fields),
                  _option('nonHumanImages', 'תמונות נוף או חפצים',
                      'חפצים, נוף, צמחים ובעלי חיים', Icons.landscape_outlined),
                  _option(
                      'men', 'גברים', 'תמונות שסווגו כתמונות גברים', Icons.man),
                  _option('women', 'נשים', 'תמונות שסווגו כתמונות נשים',
                      Icons.woman),
                  _option('children', 'ילדים', 'תמונות שסווגו כתמונות ילדים',
                      Icons.child_care),
                  _option('video', 'וידאו', 'סרטונים שעברו סריקה וסיווג',
                      Icons.videocam_outlined),
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: Text(
                        'כל התמונות עוברות בדיקת תוכן לא ראוי תמיד, ללא קשר לבחירות כאן.',
                        style: TextStyle(color: kSubtext)),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(18),
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15)),
                        textStyle: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      icon: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.save),
                      label: const Text('שמור הגדרות'),
                    ),
                  ),
                ]),
              )),
      ),
    );
  }
}

// ── Settings Screen ───────────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  final Map<String, dynamic>? me;
  final String token;
  final VoidCallback onBack;
  final VoidCallback onLogout;
  final Future<void> Function() onAccountDeleted;
  final Future<void> Function() onProfileChanged;
  final String? adminPerm;
  const SettingsScreen(
      {super.key,
      required this.me,
      required this.token,
      required this.onBack,
      required this.onLogout,
      required this.onAccountDeleted,
      required this.onProfileChanged,
      this.adminPerm});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _notifications = true;
  bool _readReceipts = true;
  bool _savingPreferences = false;

  @override
  void initState() {
    super.initState();
    _notifications = widget.me?['notifications_enabled'] as bool? ?? true;
    _readReceipts = widget.me?['read_receipts_enabled'] as bool? ?? true;
  }

  Future<void> _savePreferences({
    bool? notificationsEnabled,
    bool? readReceiptsEnabled,
  }) async {
    if (_savingPreferences) return;
    final previousNotifications = _notifications;
    final previousReceipts = _readReceipts;
    setState(() {
      _savingPreferences = true;
      if (notificationsEnabled != null) _notifications = notificationsEnabled;
      if (readReceiptsEnabled != null) _readReceipts = readReceiptsEnabled;
    });
    try {
      final response = await http.patch(
        Uri.parse('$kApi/profile/preferences'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          if (notificationsEnabled != null)
            'notificationsEnabled': notificationsEnabled,
          if (readReceiptsEnabled != null)
            'readReceiptsEnabled': readReceiptsEnabled,
        }),
      );
      if (response.statusCode != 200) throw Exception('שמירת ההגדרה נכשלה');
      final saved = jsonDecode(response.body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _notifications =
            saved['notifications_enabled'] as bool? ?? _notifications;
        _readReceipts =
            saved['read_receipts_enabled'] as bool? ?? _readReceipts;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('ההגדרה נשמרה')));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notifications = previousNotifications;
        _readReceipts = previousReceipts;
      });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('לא ניתן לשמור את ההגדרה')));
    } finally {
      if (mounted) setState(() => _savingPreferences = false);
    }
  }

  Future<void> _shareLocation() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('שיתוף מיקום מדויק'),
        content: const Text(
            'אם תאשר/י, המיקום המדויק יישמר בשרת וישמש לחיפוש משתמשים ומודעות בקרבתך. משתמשים אחרים יקבלו עיר ומרחק משוער בלבד. ניתן למחוק את המיקום בכל עת.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('אישור ושיתוף')),
        ],
      ),
    );
    if (approved != true) return;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('לא ניתנה הרשאת מיקום');
      }
      final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 10)));
      final response = await http.put(Uri.parse('$kApi/location'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'latitude': position.latitude,
            'longitude': position.longitude,
          }));
      if (response.statusCode != 200) throw Exception('שמירת המיקום נכשלה');
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('המיקום נשמר')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(error.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> _clearLocation() async {
    final response = await http.delete(Uri.parse('$kApi/location'),
        headers: {'Authorization': 'Bearer ${widget.token}'});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(response.statusCode == 200
            ? 'המיקום נמחק'
            : 'מחיקת המיקום נכשלה')));
  }

  Future<void> _deleteAccount() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('מה ברצונך למחוק?'),
        content: const Text(
            'מחיקת הפרופיל והחשבון תחזיר למסך ההרשמה. איפוס נתונים ישאיר את חשבון ההתחברות פעיל.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('ביטול')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'data'),
              child: const Text('איפוס נתונים — החשבון נשאר')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'account'),
              child: const Text('מחיקת הפרופיל והחשבון → הרשמה',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (choice == null) return;
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(choice == 'account'
            ? 'מחיקת הפרופיל והחשבון לצמיתות'
            : 'איפוס נתונים'),
        content: Text(choice == 'account'
            ? 'כל הנתונים והחשבון יימחקו, תתבצע יציאה ותועבר/י למסך הרשמה חדשה.'
            : 'ההודעות, הקבצים, המיקום ופרטי הפרופיל יאופסו. האימייל, הטלפון וחשבון ההתחברות יישארו פעילים, ולאחר הפעולה תישאר/י מחובר/ת.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
                choice == 'account' ? 'מחק והעבר להרשמה' : 'אישור איפוס',
                style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final deletingAccount = choice == 'account';
      final response = await http.delete(
          Uri.parse(deletingAccount ? '$kApi/account' : '$kApi/account/data'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(
              {'confirmation': deletingAccount ? 'DELETE' : 'DELETE_DATA'}));
      if (!mounted) return;
      if (response.statusCode == 200) {
        var filesPending = 0;
        try {
          filesPending = jsonDecode(response.body)['filesPending'] as int? ?? 0;
        } catch (_) {}
        if (deletingAccount) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove('token');
          if (filesPending > 0 && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(
                    'החשבון נמחק. $filesPending קבצים ממתינים להשלמת מחיקה.')));
          }
          await widget.onAccountDeleted();
        } else {
          await widget.onProfileChanged();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(filesPending > 0
                    ? 'התוכן ופרטי הפרופיל נמחקו. $filesPending קבצים ממתינים להשלמת מחיקה.'
                    : 'התוכן ופרטי הפרופיל נמחקו בהצלחה')));
          }
        }
      } else {
        var message =
            deletingAccount ? 'מחיקת החשבון נכשלה' : 'מחיקת הנתונים נכשלה';
        try {
          message = jsonDecode(response.body)['error'] ?? message;
        } catch (_) {}
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('לא ניתן להתחבר לשרת. נסו שוב.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.me?['name'] as String? ?? 'משתמש';
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'חזרה',
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('הגדרות',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            if (name.isNotEmpty)
              Text(name,
                  style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
      ),
      body: Align(
        alignment: Alignment.topRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 410),
          child: Material(
            color: kBg,
            child: ListView(
              children: [
                // Profile header
                InkWell(
                  onTap: () async {
                    final changed = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                          builder: (_) => ProfileScreen(
                              me: widget.me, token: widget.token)),
                    );
                    if (changed == true) await widget.onProfileChanged();
                  },
                  child: Container(
                    color: kCard,
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        UserAvatar(
                          radius: 32,
                          picUrl: widget.me?['profile_pic_url'] as String?,
                          name: name,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(name,
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold)),
                              const Text('ערוך פרופיל',
                                  style:
                                      TextStyle(color: kSubtext, fontSize: 13)),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_left, color: kSubtext),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                // Modesty settings
                const _SectionHeader(title: 'הגדרות תוכן לא ראוי'),
                Container(
                  color: kCard,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.tune, color: kPrimary),
                        title: const Text('סוגי תוכן מותרים'),
                        subtitle: const Text(
                            'טקסט, תמונות, גברים, נשים, ילדים ווידאו'),
                        trailing: const Icon(Icons.chevron_left),
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ContentFilterSettingsScreen(
                                token: widget.token,
                              ),
                            )),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // Notifications
                const _SectionHeader(title: 'התראות'),
                Container(
                  color: kCard,
                  child: Column(
                    children: [
                      SwitchListTile(
                        activeColor: kPrimary,
                        title: const Text('התראות Push'),
                        value: _notifications,
                        onChanged: _savingPreferences
                            ? null
                            : (v) => _savePreferences(notificationsEnabled: v),
                      ),
                      const Divider(height: 1, indent: 16),
                      SwitchListTile(
                        activeColor: kPrimary,
                        title: const Text('אישורי קריאה'),
                        subtitle: const Text('שלח אישור כשנקראת הודעה'),
                        value: _readReceipts,
                        onChanged: _savingPreferences
                            ? null
                            : (v) => _savePreferences(readReceiptsEnabled: v),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // Privacy
                const _SectionHeader(title: 'פרטיות'),
                Container(
                  color: kCard,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.block, color: kSubtext),
                        title: const Text('משתמשים חסומים'),
                        trailing:
                            const Icon(Icons.chevron_left, color: kSubtext),
                        onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    BlockedUsersScreen(token: widget.token))),
                      ),
                      const Divider(height: 1, indent: 16),
                      ListTile(
                        leading:
                            const Icon(Icons.lock_outline, color: kSubtext),
                        title: const Text('מדיניות פרטיות'),
                        trailing:
                            const Icon(Icons.chevron_left, color: kSubtext),
                        onTap: () => launchUrl(Uri.parse('$kServer/privacy'),
                            mode: LaunchMode.externalApplication),
                      ),
                      const Divider(height: 1, indent: 16),
                      ListTile(
                        leading: const Icon(Icons.location_on_outlined,
                            color: kPrimary),
                        title: const Text('שיתוף מיקום'),
                        subtitle:
                            const Text('כבוי כברירת מחדל; נדרש אישור מפורש'),
                        trailing:
                            const Icon(Icons.chevron_left, color: kSubtext),
                        onTap: _shareLocation,
                      ),
                      ListTile(
                        leading: const Icon(Icons.location_off_outlined,
                            color: kSubtext),
                        title: const Text('מחיקת מיקום שמור'),
                        onTap: _clearLocation,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // About
                const _SectionHeader(title: 'אודות'),
                Container(
                  color: kCard,
                  child: Column(
                    children: [
                      const ListTile(
                        leading: Icon(Icons.info_outline, color: kSubtext),
                        title: Text('גרסה'),
                        trailing:
                            Text(kVersion, style: TextStyle(color: kSubtext)),
                      ),
                      const Divider(height: 1, indent: 16),
                      const ListTile(
                        leading: Icon(Icons.verified_outlined, color: kAccent),
                        title: Text('בתשובה Messenger'),
                        subtitle: Text('מסרים לקהילה הישראלית'),
                      ),
                      const Divider(height: 1, indent: 16),
                      ListTile(
                        leading: const Icon(Icons.description_outlined,
                            color: kSubtext),
                        title: const Text('רישיונות קוד פתוח'),
                        subtitle: const Text('Flutter וספריות צד שלישי'),
                        trailing:
                            const Icon(Icons.chevron_left, color: kSubtext),
                        onTap: () => showLicensePage(
                          context: context,
                          applicationName: 'בתשובה',
                          applicationVersion: kVersion,
                          applicationIcon: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Image.asset('icon_source.png',
                                width: 64, height: 64),
                          ),
                          applicationLegalese: '© 2026 בתשובה',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // Admin Panel (visible only to admins)
                if (widget.adminPerm != null) ...[
                  const _SectionHeader(title: 'ניהול'),
                  Container(
                    color: kCard,
                    child: ListTile(
                      leading: const Icon(Icons.admin_panel_settings,
                          color: kPrimary),
                      title: const Text('לוח ניהול'),
                      subtitle: Text(
                          widget.adminPerm == 'edit'
                              ? 'הרשאת עריכה'
                              : 'הרשאת צפייה',
                          style: const TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_left, color: kSubtext),
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => AdminScreen(
                                  token: widget.token,
                                  perm: widget.adminPerm!))),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],

                const SizedBox(height: 8),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextButton.icon(
                    onPressed: _deleteAccount,
                    icon: const Icon(Icons.delete_forever, color: Colors.red),
                    label: const Text('איפוס נתונים או מחיקת פרופיל וחשבון',
                        style: TextStyle(color: Colors.red)),
                  ),
                ),

                // Logout
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: OutlinedButton.icon(
                    onPressed: widget.onLogout,
                    icon: const Icon(Icons.logout, color: Colors.red),
                    label: const Text('יציאה',
                        style: TextStyle(color: Colors.red, fontSize: 16)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          color: kPrimary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

// ── Profile Screen ────────────────────────────────────────────────
class ProfileScreen extends StatefulWidget {
  final Map<String, dynamic>? me;
  final String token;
  const ProfileScreen({super.key, required this.me, required this.token});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _nameCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _countryCtrl = TextEditingController(text: 'ישראל');
  final _streetCtrl = TextEditingController();
  final _houseCtrl = TextEditingController();
  final _apartmentCtrl = TextEditingController();
  String _privacyPic = 'all';
  String? _picUrl;
  String? _email;
  String? _phone;
  bool _emailVerified = false;
  bool _phoneVerified = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cityCtrl.dispose();
    _countryCtrl.dispose();
    _streetCtrl.dispose();
    _houseCtrl.dispose();
    _apartmentCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/profile'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _nameCtrl.text = data['name'] as String? ?? '';
          _cityCtrl.text = data['city'] as String? ?? '';
          _countryCtrl.text = data['country'] as String? ?? 'ישראל';
          _streetCtrl.text = data['street'] as String? ?? '';
          _houseCtrl.text = data['house_number'] as String? ?? '';
          _apartmentCtrl.text = data['apartment'] as String? ?? '';
          _privacyPic = data['privacy_pic'] as String? ?? 'all';
          _picUrl = data['profile_pic_url'] as String?;
          _email = data['email'] as String?;
          _phone = data['phone'] as String?;
          _emailVerified =
              data['email_verified'] == true || data['email_verified'] == 1;
          _phoneVerified =
              data['phone_verified'] == true || data['phone_verified'] == 1;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'נא להזין שם');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final res = await http.put(
        Uri.parse('$kApi/profile'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'name': _nameCtrl.text.trim(),
          'city': _cityCtrl.text.trim(),
          'country': _countryCtrl.text.trim().isEmpty
              ? 'ישראל'
              : _countryCtrl.text.trim(),
          'street': _streetCtrl.text.trim(),
          'house_number': _houseCtrl.text.trim(),
          'apartment': _apartmentCtrl.text.trim(),
          'privacy_pic': _privacyPic,
          'profile_pic_url': _picUrl,
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        Navigator.pop(context, true);
      } else {
        final data = jsonDecode(res.body);
        setState(() {
          _error = data['error'] ?? 'שגיאה';
          _saving = false;
        });
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _error = 'שגיאת חיבור';
          _saving = false;
        });
    }
  }

  Future<void> _changePhoto() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: kBorder, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 8),
          ListTile(
            leading: const CircleAvatar(
                backgroundColor: kFilterBg,
                child: Icon(Icons.photo_library_outlined, color: kPrimary)),
            title: const Text('בחר מהגלריה'),
            onTap: () => Navigator.pop(context, 'gallery'),
          ),
          ListTile(
            leading: const CircleAvatar(
                backgroundColor: kFilterBg,
                child: Icon(Icons.emoji_nature_outlined, color: kPrimary)),
            title: const Text('בחר מאוסף אווטאר'),
            subtitle: const Text('פרחים • חיות • עצים',
                style: TextStyle(fontSize: 12, color: kSubtext)),
            onTap: () => Navigator.pop(context, 'collection'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (choice == null || !mounted) return;

    if (choice == 'collection') {
      final emoji = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (_) => const AvatarPickerSheet(),
      );
      if (emoji != null && mounted) setState(() => _picUrl = emoji);
      return;
    }

    // gallery
    final picker = ImagePicker();
    final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80);
    if (picked == null || !mounted) return;

    setState(() => _saving = true);
    try {
      final bytes = await picked.readAsBytes();
      final request = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
        ..headers['Authorization'] = 'Bearer ${widget.token}'
        ..files.add(http.MultipartFile.fromBytes('file', bytes,
            filename: picked.name,
            contentType: _mimeFromFileName(picked.name)));
      final streamed =
          await request.send().timeout(const Duration(seconds: 60));
      final body = await streamed.stream.bytesToString();
      if (!mounted) return;
      if (streamed.statusCode == 200) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        if (data['status'] == 'rejected' || data['status'] == 'pending') {
          setState(() {
            _error = data['reason']?.toString() ??
                (data['status'] == 'pending'
                    ? 'התמונה ממתינה לאישור הסריקה'
                    : 'התמונה לא אושרה');
            _saving = false;
          });
          return;
        }
        final url = data['url'] as String;
        setState(() {
          _picUrl = url;
          _saving = false;
          _error = null;
        });
      } else {
        Map<String, dynamic>? data;
        try {
          data = jsonDecode(body) as Map<String, dynamic>;
        } catch (_) {}
        setState(() {
          _error = data?['error']?.toString() ?? 'שגיאה בהעלאת תמונה';
          _saving = false;
        });
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _error = 'שגיאת העלאה';
          _saving = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('עריכת פרופיל'),
        leading: BackButton(
            color: Colors.white, onPressed: () => Navigator.pop(context)),
        actions: [
          if (!_loading)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('שמור',
                      style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kPrimary))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Avatar
                Center(
                  child: GestureDetector(
                    onTap: _changePhoto,
                    child: Stack(
                      children: [
                        UserAvatar(
                          picUrl: _picUrl,
                          name: _nameCtrl.text,
                          radius: 52,
                        ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                                color: kPrimary,
                                borderRadius: BorderRadius.circular(20)),
                            child: const Icon(Icons.camera_alt,
                                color: Colors.white, size: 18),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Center(
                  child: Text('לחץ לשינוי תמונה • תעבור בדיקת תוכן לא ראוי',
                      style: TextStyle(fontSize: 12, color: kSubtext)),
                ),
                const SizedBox(height: 28),

                if (_error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(_error!,
                        style:
                            const TextStyle(color: Colors.red, fontSize: 13)),
                  ),
                  const SizedBox(height: 12),
                ],

                // ── פרטי קשר (read-only) ─────────────────────────────
                const _SectionHeader(title: 'פרטי קשר'),
                Container(
                  decoration: BoxDecoration(
                    color: kCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: kBorder),
                  ),
                  child: Column(children: [
                    if (_email != null) ...[
                      _InfoTile(
                        icon: Icons.email_outlined,
                        label: 'אימייל',
                        value: _email!,
                        verified: _emailVerified,
                      ),
                      const Divider(height: 1, indent: 52),
                    ],
                    if (_phone != null)
                      _InfoTile(
                        icon: Icons.phone_android,
                        label: 'טלפון',
                        value: _phone!,
                        verified: _phoneVerified,
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Row(children: [
                          const Icon(Icons.phone_android,
                              color: kSubtext, size: 20),
                          const SizedBox(width: 12),
                          Text('לא נוסף מספר טלפון',
                              style: const TextStyle(
                                  color: kSubtext, fontSize: 14)),
                        ]),
                      ),
                  ]),
                ),
                const SizedBox(height: 20),

                // ── פרטים אישיים ─────────────────────────────────────
                const _SectionHeader(title: 'פרטים אישיים'),
                _FieldLabel(label: 'שם מלא'),
                const SizedBox(height: 6),
                TextField(
                  controller: _nameCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(hintText: 'השם שלך'),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 14),

                // ── כתובת ─────────────────────────────────────────────
                const _SectionHeader(title: 'כתובת'),
                _FieldLabel(label: 'ארץ'),
                const SizedBox(height: 6),
                TextField(
                  controller: _countryCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: InputDecoration(
                    hintText: 'ישראל',
                    prefixIcon: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('🇮🇱', style: const TextStyle(fontSize: 22)),
                    ),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 48, minHeight: 48),
                  ),
                ),
                const SizedBox(height: 14),

                _FieldLabel(label: 'עיר'),
                const SizedBox(height: 6),
                _LocationAutocompleteField(
                  controller: _cityCtrl,
                  label: 'עיר או יישוב',
                  hint: 'הקלד שם עיר או יישוב',
                ),
                const SizedBox(height: 14),

                _FieldLabel(label: 'רחוב'),
                const SizedBox(height: 6),
                _StreetAutocompleteField(
                  controller: _streetCtrl,
                  cityController: _cityCtrl,
                ),
                const SizedBox(height: 14),

                Row(children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FieldLabel(label: 'מס\' בית'),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _houseCtrl,
                            textDirection: TextDirection.ltr,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(hintText: '12'),
                          ),
                        ]),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FieldLabel(label: 'דירה'),
                          const SizedBox(height: 6),
                          TextField(
                            controller: _apartmentCtrl,
                            textDirection: TextDirection.ltr,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(hintText: '5'),
                          ),
                        ]),
                  ),
                ]),
                const SizedBox(height: 24),

                _FieldLabel(label: 'מי רואה את תמונת הפרופיל שלי'),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: kBorder, width: 1.5),
                    borderRadius: BorderRadius.circular(10),
                    color: kCard,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _privacyPic,
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(value: 'all', child: Text('כולם')),
                        DropdownMenuItem(
                            value: 'contacts', child: Text('אנשי קשר בלבד')),
                        DropdownMenuItem(
                            value: 'nobody', child: Text('אף אחד')),
                      ],
                      onChanged: (v) => setState(() => _privacyPic = v!),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

// ── Blocked Users Screen ──────────────────────────────────────────
class BlockedUsersScreen extends StatefulWidget {
  final String token;
  const BlockedUsersScreen({super.key, required this.token});
  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  List<Map<String, dynamic>> _blocked = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/blocked'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() {
          _blocked =
              (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _unblock(String userId, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ביטול חסימה'),
        content: Text('לבטל חסימה של $name?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('בטל חסימה')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await http.delete(
        Uri.parse('$kApi/block/$userId'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      setState(() => _blocked.removeWhere((u) => u['id'] == userId));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('משתמשים חסומים')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kPrimary))
          : _blocked.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 64, color: kAccent),
                      SizedBox(height: 12),
                      Text('אין משתמשים חסומים',
                          style: TextStyle(color: kSubtext, fontSize: 15)),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: _blocked.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (_, i) {
                    final u = _blocked[i];
                    final name = u['name'] as String? ?? '';
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: kPrimaryMid,
                        child: Text(
                            name.isNotEmpty ? name[0].toUpperCase() : '?',
                            style: const TextStyle(color: Colors.white)),
                      ),
                      title: Text(name,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      trailing: TextButton(
                        onPressed: () => _unblock(u['id'] as String, name),
                        child: const Text('בטל חסימה',
                            style: TextStyle(color: kPrimary)),
                      ),
                    );
                  },
                ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String label;
  const _FieldLabel({required this.label});
  @override
  Widget build(BuildContext context) =>
      Text(label, style: const TextStyle(color: kSubtext, fontSize: 13));
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool verified;
  const _InfoTile(
      {required this.icon,
      required this.label,
      required this.value,
      this.verified = false});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Icon(icon, color: kSubtext, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 11, color: kSubtext)),
            const SizedBox(height: 2),
            Text(value, style: const TextStyle(fontSize: 14, color: kTextDark)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: verified ? const Color(0xFFDCFCE7) : const Color(0xFFFEF9C3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(verified ? Icons.verified : Icons.schedule,
                size: 13,
                color:
                    verified ? Colors.green.shade700 : Colors.orange.shade700),
            const SizedBox(width: 4),
            Text(verified ? 'מאומת' : 'לא מאומת',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: verified
                        ? Colors.green.shade700
                        : Colors.orange.shade700)),
          ]),
        ),
      ]),
    );
  }
}

// ── Admin Screen ──────────────────────────────────────────────────
class AdminScreen extends StatefulWidget {
  final String token;
  final String perm;
  const AdminScreen({super.key, required this.token, required this.perm});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  List<Map<String, dynamic>> _tables = [];
  bool _loadingTables = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _loadTables();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadTables() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/admin/db'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _tables = (data['tables'] as List).cast<Map<String, dynamic>>();
          _loadingTables = false;
        });
      } else {
        setState(() => _loadingTables = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingTables = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('לוח ניהול'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(icon: Icon(Icons.table_chart_outlined), text: 'טבלאות'),
            Tab(icon: Icon(Icons.manage_accounts_outlined), text: 'הרשאות'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _TablesView(
              token: widget.token,
              perm: widget.perm,
              tables: _tables,
              loading: _loadingTables,
              onRefresh: _loadTables),
          _PermissionsView(token: widget.token, perm: widget.perm),
        ],
      ),
    );
  }
}

class _TablesView extends StatelessWidget {
  final String token;
  final String perm;
  final List<Map<String, dynamic>> tables;
  final bool loading;
  final VoidCallback onRefresh;
  const _TablesView(
      {required this.token,
      required this.perm,
      required this.tables,
      required this.loading,
      required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (tables.isEmpty)
      return const Center(child: Text('שגיאה בטעינת הנתונים'));
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: tables.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (ctx, i) {
          final t = tables[i];
          return Card(
            elevation: 0,
            color: kCard,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: kPrimaryMid.withOpacity(0.15),
                child: Text('${t['count']}',
                    style: const TextStyle(
                        color: kPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
              ),
              title: Text(t['label'] as String,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(t['table'] as String,
                  style: const TextStyle(fontSize: 11, color: kSubtext)),
              trailing: const Icon(Icons.chevron_left, color: kSubtext),
              onTap: () => Navigator.push(
                  ctx,
                  MaterialPageRoute(
                      builder: (_) => _TableDetailScreen(
                          token: token,
                          perm: perm,
                          table: t['table'] as String,
                          label: t['label'] as String))),
            ),
          );
        },
      ),
    );
  }
}

class _TableDetailScreen extends StatefulWidget {
  final String token;
  final String perm;
  final String table;
  final String label;
  const _TableDetailScreen(
      {required this.token,
      required this.perm,
      required this.table,
      required this.label});
  @override
  State<_TableDetailScreen> createState() => _TableDetailScreenState();
}

class _TableDetailScreenState extends State<_TableDetailScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  int _total = 0;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({String search = ''}) async {
    setState(() => _loading = true);
    try {
      final uri = Uri.parse('$kApi/admin/db/${widget.table}')
          .replace(queryParameters: {'search': search, 'limit': '100'});
      final res = await http
          .get(uri, headers: {'Authorization': 'Bearer ${widget.token}'});
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _rows = (data['rows'] as List).cast<Map<String, dynamic>>();
          _total = data['total'] as int;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deleteRow(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('מחיקת רשומה'),
        content: const Text('האם למחוק את הרשומה לצמיתות?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('מחק', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final res = await http.delete(
        Uri.parse('$kApi/admin/db/${widget.table}/$id'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        setState(
            () => _rows.removeWhere((r) => r.values.first.toString() == id));
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('נמחק בהצלחה')));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: Text(widget.label),
        actions: [
          if (_total > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                  child: Text('$_total רשומות',
                      style: const TextStyle(
                          fontSize: 13, color: Colors.white70))),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              textDirection: TextDirection.rtl,
              decoration: InputDecoration(
                hintText: 'חיפוש...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          _load();
                        })
                    : null,
                filled: true,
                fillColor: kCard,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
              onSubmitted: (v) => _load(search: v),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _rows.isEmpty
                    ? const Center(child: Text('אין רשומות'))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: _rows.length,
                        itemBuilder: (ctx, i) {
                          final row = _rows[i];
                          final firstVal = row.values.first?.toString() ?? '';
                          return Card(
                            elevation: 0,
                            color: kCard,
                            margin: const EdgeInsets.only(bottom: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            child: ExpansionTile(
                              title: Text(
                                row.values
                                    .take(2)
                                    .map((v) => v?.toString() ?? '—')
                                    .join(' · '),
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600),
                                overflow: TextOverflow.ellipsis,
                              ),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 8),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ...row.entries.map((e) => Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 6),
                                            child: Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                SizedBox(
                                                  width: 110,
                                                  child: Text(e.key,
                                                      style: const TextStyle(
                                                          color: kSubtext,
                                                          fontSize: 11)),
                                                ),
                                                Expanded(
                                                  child: Text(
                                                      e.value?.toString() ??
                                                          '—',
                                                      style: const TextStyle(
                                                          fontSize: 12)),
                                                ),
                                              ],
                                            ),
                                          )),
                                      if (widget.perm == 'edit') ...[
                                        const Divider(),
                                        Align(
                                          alignment: Alignment.centerLeft,
                                          child: TextButton.icon(
                                            onPressed: () =>
                                                _deleteRow(firstVal),
                                            icon: const Icon(
                                                Icons.delete_outline,
                                                color: Colors.red,
                                                size: 18),
                                            label: const Text('מחק',
                                                style: TextStyle(
                                                    color: Colors.red)),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _PermissionsView extends StatefulWidget {
  final String token;
  final String perm;
  const _PermissionsView({required this.token, required this.perm});
  @override
  State<_PermissionsView> createState() => _PermissionsViewState();
}

class _PermissionsViewState extends State<_PermissionsView> {
  List<Map<String, dynamic>> _perms = [];
  bool _loading = true;
  final _emailCtrl = TextEditingController();
  String _newPerm = 'view';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await http.get(
        Uri.parse('$kApi/admin/permissions'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        setState(() {
          _perms = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _grant() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) return;
    try {
      final res = await http.post(
        Uri.parse('$kApi/admin/permissions'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({'email': email, 'permission': _newPerm}),
      );
      if (res.statusCode == 200 && mounted) {
        _emailCtrl.clear();
        _load();
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('הרשאה עודכנה בהצלחה')));
      } else if (mounted) {
        final err = jsonDecode(res.body)['error'] ?? 'שגיאה';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err)));
      }
    } catch (_) {}
  }

  Future<void> _revoke(String userId, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('הסרת הרשאה'),
        content: Text('להסיר הרשאת אדמין מ-$name?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('הסר', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final res = await http.delete(
        Uri.parse('$kApi/admin/permissions/$userId'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        _load();
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('הרשאה הוסרה')));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.perm == 'edit') ...[
          const _SectionHeader(title: 'הענקת הרשאה'),
          Container(
            color: kCard,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'אימייל משתמש',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('הרשאה: ', style: TextStyle(color: kSubtext)),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('צפייה'),
                      selected: _newPerm == 'view',
                      onSelected: (_) => setState(() => _newPerm = 'view'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('עריכה'),
                      selected: _newPerm == 'edit',
                      selectedColor: kPrimary.withOpacity(0.2),
                      onSelected: (_) => setState(() => _newPerm = 'edit'),
                    ),
                    const Spacer(),
                    ElevatedButton(
                        onPressed: _grant, child: const Text('הענק')),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        const _SectionHeader(title: 'מנהלים קיימים'),
        if (_loading)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator()))
        else if (_perms.isEmpty)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(24), child: Text('אין מנהלים')))
        else
          Container(
            color: kCard,
            child: Column(
              children: _perms.asMap().entries.map((e) {
                final p = e.value;
                final isEdit = p['permission'] == 'edit';
                return Column(
                  children: [
                    if (e.key > 0) const Divider(height: 1, indent: 16),
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor:
                            isEdit ? kPrimary.withOpacity(0.15) : kCard,
                        child: Icon(isEdit ? Icons.edit : Icons.visibility,
                            color: isEdit ? kPrimary : kSubtext, size: 18),
                      ),
                      title: Text(p['name'] as String? ?? '—'),
                      subtitle: Text(p['email'] as String? ?? '—',
                          style: const TextStyle(fontSize: 11)),
                      trailing: widget.perm == 'edit'
                          ? IconButton(
                              icon: const Icon(Icons.remove_circle_outline,
                                  color: Colors.red),
                              onPressed: () => _revoke(p['user_id'] as String,
                                  p['name'] as String? ?? ''))
                          : Chip(
                              label: Text(isEdit ? 'עריכה' : 'צפייה',
                                  style: const TextStyle(fontSize: 11)),
                              backgroundColor: isEdit
                                  ? kPrimary.withOpacity(0.1)
                                  : kBorder.withOpacity(0.3)),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}

// ── Educational approvals, signatures and surveys ─────────────────
class EducationFormsScreen extends StatefulWidget {
  final String token;
  final String groupId;
  final String groupName;
  final bool isAdmin;
  final IO.Socket? socket;
  const EducationFormsScreen(
      {super.key,
      required this.token,
      required this.groupId,
      required this.groupName,
      required this.isAdmin,
      this.socket});

  @override
  State<EducationFormsScreen> createState() => _EducationFormsScreenState();
}

class _EducationFormsScreenState extends State<EducationFormsScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _forms = [];
  Timer? _onlineRefreshTimer;

  @override
  void initState() {
    super.initState();
    widget.socket?.on('education:updated', _onEducationUpdated);
    _onlineRefreshTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _load(silent: true));
    _load();
  }

  void _onEducationUpdated(dynamic data) {
    if (!mounted || data is! Map || data['groupId'] != widget.groupId) return;
    _load(silent: true);
  }

  @override
  void dispose() {
    _onlineRefreshTimer?.cancel();
    widget.socket?.off('education:updated', _onEducationUpdated);
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final response = await http.get(
        Uri.parse('$kApi/groups/${widget.groupId}/education-forms'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      final data = jsonDecode(response.body);
      if (response.statusCode != 200) throw Exception(data['error'] ?? 'שגיאה');
      if (!mounted) return;
      setState(() {
        _forms = (data['forms'] as List).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (mounted)
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
    }
  }

  String _kind(Map<String, dynamic> form) => switch (form['form_type']) {
        'signature' => 'מסמך לחתימה',
        'survey' => 'סקר',
        _ => 'אישור'
      };

  IconData _icon(Map<String, dynamic> form) => switch (form['form_type']) {
        'signature' => Icons.draw_outlined,
        'survey' => Icons.poll_outlined,
        _ => Icons.fact_check_outlined
      };

  String _date(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return '';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  Future<void> _create() async {
    final created = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => CreateEducationFormScreen(
              token: widget.token,
              groupId: widget.groupId,
              groupName: widget.groupName),
        ));
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text('אישורים וסקרים • ${widget.groupName}'),
            backgroundColor: kPrimary,
            actions: [
              IconButton(onPressed: _load, icon: const Icon(Icons.refresh))
            ]),
        floatingActionButton: widget.isAdmin
            ? FloatingActionButton.extended(
                onPressed: _create,
                backgroundColor: kPrimary,
                icon: const Icon(Icons.add),
                label: const Text('יצירה חדשה'))
            : null,
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          ElevatedButton(
                              onPressed: _load, child: const Text('נסה שוב'))
                        ])))
                : _forms.isEmpty
                    ? Center(
                        child: Padding(
                            padding: const EdgeInsets.all(30),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.assignment_outlined,
                                      size: 72,
                                      color: Colors.blueGrey.shade200),
                                  const SizedBox(height: 14),
                                  const Text('אין עדיין אישורים או סקרים',
                                      style: TextStyle(
                                          fontSize: 19,
                                          fontWeight: FontWeight.bold)),
                                  if (widget.isAdmin)
                                    const Padding(
                                        padding: EdgeInsets.only(top: 8),
                                        child: Text(
                                            'לחץ על „יצירה חדשה” כדי להתחיל'))
                                ])))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                            itemCount: _forms.length,
                            itemBuilder: (_, index) {
                              final form = _forms[index];
                              final answered =
                                  form['my_response_status'] != null;
                              final closed = form['status'] == 'closed';
                              final responses = form['response_count'] ?? 0;
                              final expected = form['expected_count'] ?? 0;
                              return Card(
                                  margin: const EdgeInsets.only(bottom: 11),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () async {
                                      await Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  EducationFormDetailsScreen(
                                                      token: widget.token,
                                                      formId:
                                                          form['id'] as String,
                                                      isAdmin: widget.isAdmin,
                                                      socket: widget.socket)));
                                      _load();
                                    },
                                    child: Padding(
                                        padding: const EdgeInsets.all(15),
                                        child: Row(children: [
                                          CircleAvatar(
                                              backgroundColor:
                                                  kPrimary.withOpacity(.12),
                                              child: Icon(_icon(form),
                                                  color: kPrimary)),
                                          const SizedBox(width: 12),
                                          Expanded(
                                              child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                Row(children: [
                                                  Expanded(
                                                      child: Text(
                                                          form['title']
                                                                  ?.toString() ??
                                                              '',
                                                          style: const TextStyle(
                                                              fontSize: 16,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold))),
                                                  if (closed)
                                                    const Chip(
                                                        label: Text('סגור',
                                                            style: TextStyle(
                                                                fontSize: 11)))
                                                ]),
                                                Text(
                                                    '${_kind(form)}${form['due_at'] != null ? ' • עד ${_date(form['due_at'])}' : ''}',
                                                    style: const TextStyle(
                                                        color: kSubtext,
                                                        fontSize: 13)),
                                                const SizedBox(height: 5),
                                                Text(
                                                    widget.isAdmin
                                                        ? '$responses מתוך $expected השלימו'
                                                        : answered
                                                            ? 'הושלם'
                                                            : 'ממתין לתשובתך',
                                                    style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: answered
                                                            ? Colors
                                                                .green.shade700
                                                            : Colors.orange
                                                                .shade800)),
                                              ])),
                                          const Icon(Icons.chevron_left),
                                        ])),
                                  ));
                            })),
      );
}

class CreateEducationFormScreen extends StatefulWidget {
  final String token, groupId, groupName;
  const CreateEducationFormScreen(
      {super.key,
      required this.token,
      required this.groupId,
      required this.groupName});
  @override
  State<CreateEducationFormScreen> createState() =>
      _CreateEducationFormScreenState();
}

class _CreateEducationFormScreenState extends State<CreateEducationFormScreen> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  String _type = 'approval';
  bool _anonymous = false, _loading = false, _uploading = false;
  DateTime? _dueAt;
  String? _fileUrl, _fileName, _error;
  final List<Map<String, dynamic>> _questions = [];

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDocument() async {
    final result = await FilePicker.platform.pickFiles(
        withData: true,
        type: FileType.custom,
        allowedExtensions: ['pdf', 'doc', 'docx', 'jpg', 'jpeg', 'png']);
    if (result == null || result.files.single.bytes == null) return;
    final file = result.files.single;
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final request = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
        ..headers['Authorization'] = 'Bearer ${widget.token}'
        ..fields['groupId'] = widget.groupId
        ..files.add(http.MultipartFile.fromBytes('file', file.bytes!,
            filename: file.name, contentType: _mimeFromFileName(file.name)));
      final streamed =
          await request.send().timeout(const Duration(seconds: 90));
      final body = await streamed.stream.bytesToString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (streamed.statusCode != 200 || data['status'] == 'pending') {
        throw Exception(data['error'] ??
            (data['status'] == 'pending'
                ? 'הקובץ ממתין לאישור הסריקה'
                : 'העלאת הקובץ נכשלה'));
      }
      if (mounted)
        setState(() {
          _fileUrl = data['url'] as String?;
          _fileName = file.name;
        });
    } catch (e) {
      if (mounted)
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _addQuestion() async {
    final question = TextEditingController();
    final options = TextEditingController();
    final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('שאלת סקר'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: question,
                      decoration: const InputDecoration(labelText: 'השאלה')),
                  const SizedBox(height: 10),
                  TextField(
                      controller: options,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                          labelText: 'אפשרויות — כל אפשרות בשורה')),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('ביטול')),
                  ElevatedButton(
                      onPressed: () {
                        final values = options.text
                            .split('\n')
                            .map((e) => e.trim())
                            .where((e) => e.isNotEmpty)
                            .toList();
                        if (question.text.trim().isNotEmpty &&
                            values.length >= 2) {
                          Navigator.pop(ctx, {
                            'text': question.text.trim(),
                            'options': values
                          });
                        }
                      },
                      child: const Text('הוסף'))
                ]));
    question.dispose();
    options.dispose();
    if (result != null) setState(() => _questions.add(result));
  }

  Future<void> _chooseDueDate() async {
    final date = await showDatePicker(
        context: context,
        initialDate: DateTime.now().add(const Duration(days: 2)),
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(const Duration(days: 730)));
    if (date != null)
      setState(
          () => _dueAt = DateTime(date.year, date.month, date.day, 23, 59));
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'יש להזין כותרת');
      return;
    }
    if (_type == 'survey' && _questions.isEmpty) {
      setState(() => _error = 'יש להוסיף לפחות שאלת סקר אחת');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await http.post(
          Uri.parse('$kApi/groups/${widget.groupId}/education-forms'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({
            'formType': _type,
            'title': _title.text.trim(),
            'description': _description.text.trim(),
            'fileUrl': _fileUrl,
            'fileName': _fileName,
            'questions': _questions,
            'anonymous': _anonymous,
            if (_dueAt != null) 'dueAt': _dueAt!.toUtc().toIso8601String()
          }));
      final data = jsonDecode(response.body);
      if (response.statusCode != 201)
        throw Exception(data['error'] ?? 'יצירת הטופס נכשלה');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted)
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: const Text('יצירת אישור או סקר'), backgroundColor: kPrimary),
        body: ListView(padding: const EdgeInsets.all(18), children: [
          SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'approval',
                    icon: Icon(Icons.fact_check_outlined),
                    label: Text('אישור')),
                ButtonSegment(
                    value: 'signature',
                    icon: Icon(Icons.draw_outlined),
                    label: Text('חתימה')),
                ButtonSegment(
                    value: 'survey',
                    icon: Icon(Icons.poll_outlined),
                    label: Text('סקר')),
              ],
              selected: {
                _type
              },
              onSelectionChanged: (value) =>
                  setState(() => _type = value.first)),
          const SizedBox(height: 18),
          TextField(
              controller: _title,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(
                  labelText: 'כותרת *', prefixIcon: Icon(Icons.title))),
          const SizedBox(height: 12),
          TextField(
              controller: _description,
              minLines: 3,
              maxLines: 7,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(
                  labelText: 'הסבר להורים', alignLabelWithHint: true)),
          const SizedBox(height: 12),
          Card(
              child: ListTile(
                  leading: _uploading
                      ? const CircularProgressIndicator()
                      : const Icon(Icons.attach_file),
                  title: Text(_fileName ?? 'צירוף תמונה או מסמך'),
                  subtitle: const Text('PDF, Word או תמונה'),
                  trailing: _fileName != null
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                                _fileName = null;
                                _fileUrl = null;
                              }))
                      : null,
                  onTap: _uploading ? null : _pickDocument)),
          Card(
              child: ListTile(
                  leading: const Icon(Icons.event_outlined),
                  title: Text(_dueAt == null
                      ? 'ללא מועד סיום'
                      : 'מועד סיום: ${_dueAt!.day}/${_dueAt!.month}/${_dueAt!.year}'),
                  trailing: _dueAt == null
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _dueAt = null)),
                  onTap: _chooseDueDate)),
          if (_type == 'survey') ...[
            SwitchListTile(
                value: _anonymous,
                onChanged: (v) => setState(() => _anonymous = v),
                title: const Text('סקר אנונימי'),
                subtitle: const Text(
                    'המנהל יראה מי השתתף, אך לא איזו תשובה שייכת למי')),
            const Divider(),
            ..._questions.asMap().entries.map((entry) => Card(
                child: ListTile(
                    leading: CircleAvatar(child: Text('${entry.key + 1}')),
                    title: Text(entry.value['text'] as String),
                    subtitle:
                        Text((entry.value['options'] as List).join(' • ')),
                    trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () =>
                            setState(() => _questions.removeAt(entry.key)))))),
            OutlinedButton.icon(
                onPressed: _addQuestion,
                icon: const Icon(Icons.add),
                label: const Text('הוסף שאלת סקר')),
          ],
          if (_error != null)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
              onPressed: _loading || _uploading ? null : _submit,
              icon: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('פרסם בקבוצה'))),
        ]),
      );
}

class EducationFormDetailsScreen extends StatefulWidget {
  final String token, formId;
  final bool isAdmin;
  final IO.Socket? socket;
  const EducationFormDetailsScreen(
      {super.key,
      required this.token,
      required this.formId,
      required this.isAdmin,
      this.socket});
  @override
  State<EducationFormDetailsScreen> createState() =>
      _EducationFormDetailsScreenState();
}

class _EducationFormDetailsScreenState
    extends State<EducationFormDetailsScreen> {
  bool _loading = true, _saving = false, _exportingPdf = false;
  String? _error;
  Map<String, dynamic>? _form;
  List<Map<String, dynamic>> _participants = [], _results = [];
  final Map<int, String> _answers = {};
  final _signerName = TextEditingController();
  final List<Offset?> _signature = [];
  Timer? _onlineRefreshTimer;

  @override
  void initState() {
    super.initState();
    widget.socket?.on('education:updated', _onEducationUpdated);
    if (widget.isAdmin) {
      _onlineRefreshTimer = Timer.periodic(
          const Duration(seconds: 5), (_) => _load(silent: true));
    }
    _load();
  }

  void _onEducationUpdated(dynamic data) {
    if (!mounted || data is! Map || data['formId'] != widget.formId) return;
    final action = data['action']?.toString();
    if (!widget.isAdmin &&
        action != 'closed' &&
        action != 'opened' &&
        action != 'change_approved' &&
        action != 'change_rejected') {
      return;
    }
    _load(silent: true);
  }

  @override
  void dispose() {
    _onlineRefreshTimer?.cancel();
    widget.socket?.off('education:updated', _onEducationUpdated);
    _signerName.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final response = await http.get(
          Uri.parse('$kApi/education-forms/${widget.formId}'),
          headers: {'Authorization': 'Bearer ${widget.token}'});
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) throw Exception(data['error'] ?? 'שגיאה');
      final loadedForm = data['form'] as Map<String, dynamic>;
      var defaultSignerName =
          loadedForm['current_user_name']?.toString().trim() ?? '';
      if (loadedForm['form_type'] == 'signature' && defaultSignerName.isEmpty) {
        final profileResponse = await http.get(Uri.parse('$kApi/profile'),
            headers: {'Authorization': 'Bearer ${widget.token}'});
        if (profileResponse.statusCode == 200) {
          final profile =
              jsonDecode(profileResponse.body) as Map<String, dynamic>;
          defaultSignerName = profile['name']?.toString().trim() ?? '';
        }
      }
      if (!mounted) return;
      setState(() {
        _form = loadedForm;
        _participants = data['participants'] == null
            ? []
            : (data['participants'] as List).cast<Map<String, dynamic>>();
        _results = data['results'] == null
            ? []
            : (data['results'] as List).cast<Map<String, dynamic>>();
        final previous = _form?['my_answers'];
        if (previous is Map)
          for (final entry in previous.entries) {
            final key = int.tryParse(entry.key.toString());
            if (key != null) _answers[key] = entry.value.toString();
          }
        if (_signerName.text.trim().isEmpty) {
          _signerName.text =
              _form?['my_signer_name']?.toString().trim().isNotEmpty == true
                  ? _form!['my_signer_name'].toString()
                  : defaultSignerName;
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted)
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
    }
  }

  String _statusLabel(String? status) => switch (status) {
        'approved' => 'אושר',
        'declined' => 'לא אושר',
        'completed' => 'הושלם',
        _ => 'טרם השלים'
      };

  Future<void> _respond(String status) async {
    final form = _form!;
    final type = form['form_type'];
    if (type == 'signature' &&
        (_signerName.text.trim().isEmpty ||
            _signature.whereType<Offset>().length < 2)) {
      setState(() => _error = 'יש להזין שם מלא ולחתום בתוך המסגרת');
      return;
    }
    final questions = (form['questions'] as List? ?? []);
    if (type == 'survey' && _answers.length < questions.length) {
      setState(() => _error = 'יש לענות על כל שאלות הסקר');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final signatureData = _signature
          .map((point) => point == null ? null : {'x': point.dx, 'y': point.dy})
          .toList();
      final response = await http.post(
          Uri.parse('$kApi/education-forms/${widget.formId}/respond'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({
            'status': status,
            'answers': _answers.map((k, v) => MapEntry('$k', v)),
            'signerName': _signerName.text.trim(),
            'signatureData': signatureData
          }));
      final data = jsonDecode(response.body);
      if (response.statusCode != 200)
        throw Exception(data['error'] ?? 'שמירת התשובה נכשלה');
      if (mounted) Navigator.pop(context, status);
    } catch (e) {
      if (mounted)
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _requestResponseChange() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final response = await http.post(
          Uri.parse('$kApi/education-forms/${widget.formId}/change-request'),
          headers: {'Authorization': 'Bearer ${widget.token}'});
      final data = jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw Exception(data['error'] ?? 'שליחת בקשת השינוי נכשלה');
      }
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('בקשת השינוי נשלחה למנהל הקבוצה')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _decideResponseChange(String userId, String decision) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final response = await http.post(
          Uri.parse(
              '$kApi/education-forms/${widget.formId}/change-request/$userId/decision'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({'decision': decision}));
      final data = jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw Exception(data['error'] ?? 'שמירת החלטת המנהל נכשלה');
      }
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remind({String? userId}) async {
    setState(() => _saving = true);
    try {
      final response = await http.post(
          Uri.parse('$kApi/education-forms/${widget.formId}/remind'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode({
            'userIds': userId == null ? [] : [userId]
          }));
      final data = jsonDecode(response.body);
      if (response.statusCode != 200)
        throw Exception(data['error'] ?? 'שליחת התזכורת נכשלה');
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('נשלחו ${data['sent']} תזכורות')));
      await _load();
    } catch (e) {
      if (mounted)
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleStatus() async {
    final next = _form?['status'] == 'open' ? 'closed' : 'open';
    final response = await http.put(
        Uri.parse('$kApi/education-forms/${widget.formId}/status'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json'
        },
        body: jsonEncode({'status': next}));
    if (response.statusCode == 200) _load();
  }

  Future<void> _downloadSurveyPdf() async {
    if (_form?['form_type'] != 'survey' ||
        _form?['status'] != 'closed' ||
        _exportingPdf) {
      return;
    }
    setState(() {
      _exportingPdf = true;
      _error = null;
    });
    try {
      final fontData = await rootBundle.load('assets/fonts/NotoSansHebrew.ttf');
      final font = pw.Font.ttf(fontData);
      final document = pw.Document();
      final questions = (_form?['questions'] as List? ?? []).cast<dynamic>();
      final completed =
          _participants.where((p) => p['response_status'] != null).length;
      final generatedAt = DateTime.now();

      document.addPage(pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          textDirection: pw.TextDirection.rtl,
          theme: pw.ThemeData.withFont(base: font, bold: font),
          margin: const pw.EdgeInsets.all(32),
          header: (context) => pw.Container(
              alignment: pw.Alignment.centerRight,
              padding: const pw.EdgeInsets.only(bottom: 8),
              decoration: const pw.BoxDecoration(
                  border: pw.Border(
                      bottom: pw.BorderSide(color: PdfColors.grey400))),
              child: pw.Text('תוצאות סקר',
                  style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700))),
          footer: (context) => pw.Align(
              alignment: pw.Alignment.center,
              child: pw.Text(
                  'עמוד ${context.pageNumber} מתוך ${context.pagesCount}',
                  style: const pw.TextStyle(
                      fontSize: 9, color: PdfColors.grey600))),
          build: (context) => [
                pw.SizedBox(height: 12),
                pw.Text(_form?['title']?.toString() ?? 'סקר',
                    style: pw.TextStyle(
                        fontSize: 22, fontWeight: pw.FontWeight.bold)),
                if ((_form?['description']?.toString().trim() ?? '')
                    .isNotEmpty) ...[
                  pw.SizedBox(height: 8),
                  pw.Text(_form!['description'].toString()),
                ],
                pw.SizedBox(height: 12),
                pw.Container(
                    padding: const pw.EdgeInsets.all(10),
                    color: PdfColors.grey100,
                    child: pw.Row(children: [
                      pw.Expanded(
                          child: pw.Text('השלימו: $completed',
                              style: pw.TextStyle(
                                  fontWeight: pw.FontWeight.bold))),
                      pw.Expanded(
                          child: pw.Text(
                              'סה״כ משתתפים: ${_participants.length}',
                              style: pw.TextStyle(
                                  fontWeight: pw.FontWeight.bold))),
                    ])),
                pw.SizedBox(height: 18),
                ...questions.asMap().entries.map((entry) {
                  final question = entry.value as Map<String, dynamic>;
                  final counts = <String, int>{
                    for (final option in question['options'] as List)
                      option.toString(): 0
                  };
                  for (final result in _results) {
                    final answers = result['answers'];
                    if (answers is Map) {
                      final answer = answers['${entry.key}']?.toString();
                      if (answer != null) {
                        counts[answer] = (counts[answer] ?? 0) + 1;
                      }
                    }
                  }
                  return pw.Container(
                      margin: const pw.EdgeInsets.only(bottom: 14),
                      padding: const pw.EdgeInsets.all(12),
                      decoration: pw.BoxDecoration(
                          border: pw.Border.all(color: PdfColors.grey400),
                          borderRadius:
                              const pw.BorderRadius.all(pw.Radius.circular(6))),
                      child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                          children: [
                            pw.Text('${entry.key + 1}. ${question['text']}',
                                style: pw.TextStyle(
                                    fontWeight: pw.FontWeight.bold)),
                            pw.SizedBox(height: 8),
                            ...counts.entries.map((item) => pw.Padding(
                                padding:
                                    const pw.EdgeInsets.symmetric(vertical: 3),
                                child: pw.Row(children: [
                                  pw.Expanded(child: pw.Text(item.key)),
                                  pw.Text('${item.value}',
                                      style: pw.TextStyle(
                                          fontWeight: pw.FontWeight.bold)),
                                ]))),
                          ]));
                }),
                pw.SizedBox(height: 8),
                pw.Text(
                    'הופק בתאריך ${generatedAt.day}/${generatedAt.month}/${generatedAt.year} ${generatedAt.hour.toString().padLeft(2, '0')}:${generatedAt.minute.toString().padLeft(2, '0')}',
                    style: const pw.TextStyle(
                        fontSize: 9, color: PdfColors.grey600)),
              ]));

      final title = (_form?['title']?.toString() ?? 'survey')
          .replaceAll(RegExp(r'[^\w\u0590-\u05FF-]+'), '_');
      await Printing.sharePdf(
          bytes: await document.save(), filename: '$title.pdf');
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'הפקת קובץ ה־PDF נכשלה');
      }
    } finally {
      if (mounted) setState(() => _exportingPdf = false);
    }
  }

  Future<void> _assignNewMembers() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final response = await http.post(
          Uri.parse(
              '$kApi/education-forms/${widget.formId}/assign-new-members'),
          headers: {'Authorization': 'Bearer ${widget.token}'});
      final data = jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw Exception(data['error'] ?? 'השליחה נכשלה');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('הטופס נשלח ל־${data['sent']} חברים חדשים')));
      }
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _republish() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final response = await http.post(
          Uri.parse('$kApi/education-forms/${widget.formId}/republish'),
          headers: {'Authorization': 'Bearer ${widget.token}'});
      final data = jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw Exception(data['error'] ?? 'הפרסום נכשל');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('הטופס פורסם שוב בשיחת הקבוצה')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _documentCard() {
    final form = _form!;
    if (form['file_url'] == null) return const SizedBox.shrink();
    final storedUrl = form['file_url'].toString();
    final documentUri = Uri.parse(storedUrl).hasScheme
        ? Uri.parse(storedUrl)
        : Uri.parse(kServer).resolve(storedUrl);
    return Card(
        child: ListTile(
            leading: const Icon(Icons.description_outlined, color: kPrimary),
            title: Text(form['file_name']?.toString() ?? 'מסמך מצורף'),
            subtitle: const Text('לחץ לצפייה במסמך לפני האישור'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () async {
              final opened = await launchUrl(documentUri,
                  mode: kIsWeb
                      ? LaunchMode.platformDefault
                      : LaunchMode.externalApplication);
              if (!opened && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('לא ניתן לפתוח את המסמך. נסה שוב.')));
              }
            }));
  }

  Widget _memberResponse() {
    final form = _form!;
    final type = form['form_type'];
    final closed = form['status'] == 'closed';
    final answered = form['my_response_status'] != null;
    if (closed)
      return const Card(
          child: Padding(
              padding: EdgeInsets.all(18),
              child: Text('הטופס נסגר ולא ניתן עוד להשיב.')));
    if (answered) {
      final changeStatus = form['my_change_request_status']?.toString();
      return Card(
          child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(children: [
                const Icon(Icons.verified_outlined,
                    color: Colors.green, size: 34),
                const SizedBox(height: 8),
                Text(
                    'תשובתך: ${_statusLabel(form['my_response_status'] as String?)}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 6),
                const Text('התגובה נשלחה ולא ניתן לשנות אותה',
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                if (changeStatus == 'pending')
                  const Chip(label: Text('בקשת שינוי ממתינה לאישור מנהל'))
                else
                  OutlinedButton.icon(
                      onPressed: _saving ? null : _requestResponseChange,
                      icon: const Icon(Icons.change_circle_outlined),
                      label: const Text('בקש/י מהמנהל לשנות בחירה')),
              ])));
    }
    if (type == 'survey') {
      final questions = (form['questions'] as List? ?? []).cast<dynamic>();
      return Column(children: [
        ...questions.asMap().entries.map((entry) {
          final q = entry.value as Map<String, dynamic>;
          return Card(
              child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${entry.key + 1}. ${q['text']}',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        ...(q['options'] as List).map((option) =>
                            RadioListTile<String>(
                                dense: true,
                                value: option.toString(),
                                groupValue: _answers[entry.key],
                                title: Text(option.toString()),
                                onChanged: (v) =>
                                    setState(() => _answers[entry.key] = v!))),
                      ])));
        }),
        ElevatedButton.icon(
            onPressed: _saving ? null : () => _respond('completed'),
            icon: const Icon(Icons.send),
            label: const Text('שלח תשובות')),
      ]);
    }
    if (type == 'signature') {
      return Card(
          child: Padding(
              padding: const EdgeInsets.all(15),
              child: Column(children: [
                TextField(
                    controller: _signerName,
                    decoration:
                        const InputDecoration(labelText: 'שם מלא של החותם')),
                const SizedBox(height: 12),
                Row(children: [
                  const Expanded(
                      child: Text('חתימה באצבע בתוך המסגרת',
                          style: TextStyle(fontWeight: FontWeight.bold))),
                  TextButton(
                      onPressed: () => setState(_signature.clear),
                      child: const Text('נקה'))
                ]),
                Container(
                    height: 170,
                    width: double.infinity,
                    decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: kPrimary),
                        borderRadius: BorderRadius.circular(8)),
                    child: GestureDetector(
                        onPanStart: (d) =>
                            setState(() => _signature.add(d.localPosition)),
                        onPanUpdate: (d) =>
                            setState(() => _signature.add(d.localPosition)),
                        onPanEnd: (_) => setState(() => _signature.add(null)),
                        child: CustomPaint(
                            painter: _EducationSignaturePainter(_signature)))),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                    onPressed: _saving ? null : () => _respond('approved'),
                    icon: const Icon(Icons.draw),
                    label: const Text('אני מאשר/ת וחותם/ת')),
              ])));
    }
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(15),
            child: Column(children: [
              Row(children: [
                Expanded(
                    child: OutlinedButton.icon(
                        onPressed: _saving ? null : () => _respond('declined'),
                        icon: const Icon(Icons.close),
                        label: const Text('איני מאשר/ת'))),
                const SizedBox(width: 10),
                Expanded(
                    child: ElevatedButton.icon(
                        onPressed: _saving ? null : () => _respond('approved'),
                        icon: const Icon(Icons.check),
                        label: const Text('מאשר/ת'))),
              ])
            ])));
  }

  Widget _adminPanel() {
    final pending =
        _participants.where((p) => p['response_status'] == null).length;
    final newMembers = (_form?['new_member_count'] as num?)?.toInt() ?? 0;
    final closed = _form?['status'] == 'closed';
    return Column(children: [
      if (closed)
        const Card(
            child: ListTile(
                leading: Icon(Icons.lock_outline, color: Colors.orange),
                title: Text('הטופס סגור'),
                subtitle:
                    Text('תגובות, שינויי בחירה, תזכורות ופרסום נוסף מושבתים'))),
      Card(
          child: Padding(
              padding: const EdgeInsets.all(15),
              child: Column(children: [
                Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _EducationCount(
                          value: '${_participants.length - pending}',
                          label: 'השלימו',
                          color: Colors.green),
                      _EducationCount(
                          value: '$pending',
                          label: 'טרם השלימו',
                          color: Colors.orange),
                      _EducationCount(
                          value: '${_participants.length}',
                          label: 'סה״כ',
                          color: kPrimary),
                    ]),
                const SizedBox(height: 12),
                SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                        onPressed: closed || pending == 0 || _saving
                            ? null
                            : () => _remind(),
                        icon: const Icon(Icons.notifications_active_outlined),
                        label: Text('שלח תזכורת לכל הממתינים ($pending)'))),
                const SizedBox(height: 8),
                SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                        onPressed: closed || _saving ? null : _republish,
                        icon: const Icon(Icons.campaign_outlined),
                        label: const Text('פרסם שוב בשיחת הקבוצה'))),
                if (newMembers > 0) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                          onPressed:
                              closed || _saving ? null : _assignNewMembers,
                          icon: const Icon(Icons.person_add_alt_1_outlined),
                          label: Text(
                              'שלח גם לחברים שהצטרפו לאחר מכן ($newMembers)'))),
                ],
                if (closed && _form?['form_type'] == 'survey') ...[
                  const SizedBox(height: 8),
                  SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                          onPressed: _exportingPdf ? null : _downloadSurveyPdf,
                          icon: _exportingPdf
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.picture_as_pdf_outlined),
                          label: const Text('הורד תוצאות כ־PDF'))),
                ],
              ]))),
      if (_form?['form_type'] == 'survey') _surveyResults(),
      const Padding(
          padding: EdgeInsets.fromLTRB(4, 14, 4, 5),
          child: Align(
              alignment: Alignment.centerRight,
              child: Text('מצב משתתפים',
                  style:
                      TextStyle(fontSize: 17, fontWeight: FontWeight.bold)))),
      ..._participants.map((person) {
        final status = person['response_status'] as String?;
        final changePending = person['change_request_status'] == 'pending';
        return Card(
            child: ListTile(
          leading: CircleAvatar(
              child:
                  Text((person['name']?.toString() ?? '?').characters.first)),
          title: Text(person['name']?.toString() ?? ''),
          subtitle: Text(
              changePending
                  ? '${_statusLabel(status)} • מבקש/ת לשנות בחירה'
                  : _statusLabel(status),
              style: TextStyle(
                  color: changePending
                      ? Colors.orange.shade800
                      : status == null
                          ? Colors.orange.shade800
                          : Colors.green.shade700)),
          trailing: changePending
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      tooltip: 'דחה בקשת שינוי',
                      icon: const Icon(Icons.close, color: Colors.red),
                      onPressed: closed || _saving
                          ? null
                          : () => _decideResponseChange(
                              person['id'] as String, 'rejected')),
                  IconButton(
                      tooltip: 'אשר שינוי בחירה',
                      icon: const Icon(Icons.check, color: Colors.green),
                      onPressed: closed || _saving
                          ? null
                          : () => _decideResponseChange(
                              person['id'] as String, 'approved')),
                ])
              : status == null
                  ? IconButton(
                      icon: const Icon(Icons.notifications_none),
                      tooltip: 'שלח תזכורת',
                      onPressed: _saving
                          ? null
                          : () => _remind(userId: person['id'] as String))
                  : person['submitted_at'] == null
                      ? null
                      : Text(_shortDate(person['submitted_at'])),
        ));
      }),
    ]);
  }

  Widget _surveyResults() {
    final questions = (_form?['questions'] as List? ?? []).cast<dynamic>();
    return Column(
        children: questions.asMap().entries.map((entry) {
      final q = entry.value as Map<String, dynamic>;
      final counts = <String, int>{
        for (final o in q['options'] as List) o.toString(): 0
      };
      for (final row in _results) {
        final answers = row['answers'];
        if (answers is Map) {
          final answer = answers['${entry.key}']?.toString();
          if (answer != null) counts[answer] = (counts[answer] ?? 0) + 1;
        }
      }
      return Card(
          child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(q['text'].toString(),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ...counts.entries.map((item) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(children: [
                          Expanded(child: Text(item.key)),
                          Text('${item.value}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold))
                        ]))),
                  ])));
    }).toList());
  }

  String _shortDate(dynamic value) {
    final d = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    return d == null
        ? ''
        : '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_form == null)
      return Scaffold(
          appBar: AppBar(),
          body: Center(child: Text(_error ?? 'הטופס לא נמצא')));
    final form = _form!;
    return Scaffold(
        appBar: AppBar(
            title: Text(form['title']?.toString() ?? ''),
            backgroundColor: kPrimary,
            actions: [
              if (widget.isAdmin)
                PopupMenuButton<String>(
                    onSelected: (_) => _toggleStatus(),
                    itemBuilder: (_) => [
                          PopupMenuItem(
                              value: 'toggle',
                              child: Text(form['status'] == 'open'
                                  ? 'סגור טופס'
                                  : 'פתח מחדש'))
                        ])
            ]),
        body: RefreshIndicator(
            onRefresh: _load,
            child: ListView(padding: const EdgeInsets.all(14), children: [
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(17),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Icon(
                                  form['form_type'] == 'survey'
                                      ? Icons.poll_outlined
                                      : form['form_type'] == 'signature'
                                          ? Icons.draw_outlined
                                          : Icons.fact_check_outlined,
                                  color: kPrimary),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: Text(form['title'].toString(),
                                      style: const TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold)))
                            ]),
                            if ((form['description']?.toString() ?? '')
                                .isNotEmpty)
                              Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Text(form['description'].toString())),
                            if (form['due_at'] != null)
                              Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Text(
                                      'מועד אחרון: ${_shortDate(form['due_at'])}',
                                      style: const TextStyle(color: kSubtext))),
                            if (form['anonymous'] == true)
                              const Padding(
                                  padding: EdgeInsets.only(top: 8),
                                  child: Chip(label: Text('סקר אנונימי'))),
                          ]))),
              _documentCard(),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(_error!,
                        style: const TextStyle(color: Colors.red),
                        textAlign: TextAlign.center)),
              if (widget.isAdmin) _adminPanel() else _memberResponse(),
              const SizedBox(height: 30),
            ])));
  }
}

class _EducationCount extends StatelessWidget {
  final String value, label;
  final Color color;
  const _EducationCount(
      {required this.value, required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Column(children: [
        Text(value,
            style: TextStyle(
                fontSize: 24, fontWeight: FontWeight.bold, color: color)),
        Text(label)
      ]);
}

class _EducationSignaturePainter extends CustomPainter {
  final List<Offset?> points;
  _EducationSignaturePainter(this.points);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF123B57)
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < points.length - 1; i++) {
      if (points[i] != null && points[i + 1] != null)
        canvas.drawLine(points[i]!, points[i + 1]!, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EducationSignaturePainter oldDelegate) => true;
}

class _AppLifecycleObserver extends WidgetsBindingObserver {
  final VoidCallback onResume;
  _AppLifecycleObserver({required this.onResume});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}
