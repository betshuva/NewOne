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
import 'file_download.dart';

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

bool _hasImageExtension(String? value) {
  if (value == null || value.isEmpty) return false;
  final v = value.toLowerCase();
  return v.endsWith('.jpg') ||
      v.endsWith('.jpeg') ||
      v.endsWith('.png') ||
      v.endsWith('.gif') ||
      v.endsWith('.webp');
}

String? _normalizeIncomingFileType(String? fileType,
    {String? fileUrl, String? fileName}) {
  // Extension check takes priority — DB may store 'text' even for image messages
  if (_hasImageExtension(fileUrl) || _hasImageExtension(fileName))
    return 'image';
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
const kOutgoing = Color(0xFFDCEEFF); // outgoing bubble — light blue
const kGroupOutgoing = Color(0xFFDCEEFF); // light background for readable text
const kChatBg = Color(0xFFEBF5FC); // chat background
const kFilterBg = Color(0xFFE8F4FD); // filter banner background

const kServer = 'https://betshuva.com/betshuva-app';
const kApi = '$kServer/api';
// Socket.IO treats any path in the connection URL as a *namespace*, not a URL
// prefix — so it must be given the bare origin plus an explicit `path` option
// (see kSocketPath below), or it'll try to handshake at "/socket.io/" on the
// domain root instead of through our nginx sub-path proxy.
final kServerUri = Uri.parse(kServer);
final kSocketOrigin = kServerUri.origin;
final kSocketPath = '${kServerUri.path}/socket.io/';
const kVersion = '1.2.20';
const kApkUrl = 'https://betshuva.com/betshuva-app/betshuva-1.2.20.apk';
const _shareChannel = MethodChannel('com.betshuva.app/share');

String _absoluteMediaUrl(String url) =>
    Uri.parse(url).hasScheme ? url : Uri.parse(kServer).resolve(url).toString();

Future<void> _forwardChatMessage(BuildContext context, String token,
    IO.Socket? socket, Map<String, dynamic> message) async {
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
    var fileUrl = message['fileUrl'] as String?;
    var fileName = message['fileName'] as String?;
    var fileType = message['fileType'] as String?;
    final localPath = message['localPath'] as String?;
    if (localPath != null) {
      final request = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
        ..headers['Authorization'] = 'Bearer $token'
        ..fields[target['kind'] == 'group' ? 'groupId' : 'toUserId'] =
            target['id'].toString()
        ..files.add(await http.MultipartFile.fromPath('file', localPath,
            filename: fileName,
            contentType: _mimeFromFileName(fileName ?? localPath)));
      final upload = await request.send().timeout(const Duration(seconds: 60));
      final uploadBody = await upload.stream.bytesToString();
      if (upload.statusCode != 200) {
        var uploadError = 'העלאת התמונה נכשלה';
        try {
          uploadError = (jsonDecode(uploadBody) as Map)['error']?.toString() ??
              uploadError;
        } catch (_) {}
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(uploadError)));
        }
        return;
      }
      final uploaded = jsonDecode(uploadBody) as Map<String, dynamic>;
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
    } else if (socket?.connected == true) {
      socket!.emit('group:message', {...payload, 'groupId': target['id']});
      sent = true;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(sent ? 'ההודעה הועברה' : 'לא ניתן להעביר את ההודעה')));
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
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
    await _initLocalNotifications();
    FirebaseMessaging.onMessage.listen(_showLocalNotification);
  } catch (_) {}
  runApp(const BetshuvApp());
}

// ── Magen David Logo ──────────────────────────────────────────────
class _MagenDavidPainter extends CustomPainter {
  final Color color;
  final Color bgColor;
  const _MagenDavidPainter(this.color, this.bgColor);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = bgColor;
    canvas.drawCircle(
        Offset(size.width / 2, size.height / 2), size.width / 2, bg);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.07
      ..strokeJoin = StrokeJoin.round;

    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.36;

    Path _tri(double startAngle) {
      final p = Path();
      for (int i = 0; i < 3; i++) {
        final a = (startAngle + i * 120) * math.pi / 180;
        final x = cx + r * math.cos(a);
        final y = cy + r * math.sin(a);
        if (i == 0)
          p.moveTo(x, y);
        else
          p.lineTo(x, y);
      }
      p.close();
      return p;
    }

    canvas.drawPath(_tri(-90), paint);
    canvas.drawPath(_tri(90), paint);
  }

  @override
  bool shouldRepaint(_) => false;
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
    CustomPaint(
      size: Size(size, size),
      painter: _MagenDavidPainter(color, bg),
    );

Widget _androidDownloadLink() => TextButton.icon(
      onPressed: () =>
          launchUrl(Uri.parse(kApkUrl), mode: LaunchMode.externalApplication),
      icon: const Icon(Icons.android, size: 20),
      label: const Text('הורדת betshuva-1.2.20.apk  •  גרסה 1.2.20'),
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
                'מסרים לקהילה החרדית',
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
  String? _error;
  final _googleSignIn = GoogleSignIn(
    clientId: kIsWeb ? kGoogleWebClientId : null,
    serverClientId: kIsWeb ? null : kGoogleWebClientId,
  );

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _googleSignIn.signOut();
      // On web, signIn() is an OAuth authorization flow and does not return
      // an ID token. The GIS authentication flow used by signInSilently does.
      final account = kIsWeb
          ? await _googleSignIn.signInSilently()
          : await _googleSignIn.signIn();
      if (account == null) {
        setState(() {
          _loading = false;
        });
        return;
      }
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null) throw Exception('לא התקבל טוקן מגוגל');
      final res = await http
          .post(
            Uri.parse('$kApi/auth/google'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'idToken': idToken}),
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
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final phone = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (phone.length < 9) {
      setState(() => _error = 'נא להזין מספר טלפון תקין');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await http
          .post(
            Uri.parse('$kApi/send-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'phone': phone, 'name': _nameCtrl.text.trim()}),
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
      final phone = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
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
                    const SizedBox(height: 36),
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
                    ] else ...[
                      TextField(
                        controller: _otpCtrl,
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
                            'https://www.google.com/favicon.ico',
                            width: 18,
                            height: 18,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.g_mobiledata, size: 22),
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
class AuthScreen extends StatefulWidget {
  final String? initialEmail;
  const AuthScreen({super.key, this.initialEmail});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isLogin = true;
  bool _loading = false;
  bool _choosingVerification = false;
  bool _verificationRequired = false;
  String _verificationMethod = 'email';
  String? _error;

  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  final _googleSignIn = GoogleSignIn(
    clientId: kIsWeb ? kGoogleWebClientId : null,
    serverClientId: kIsWeb ? null : kGoogleWebClientId,
  );

  @override
  void initState() {
    super.initState();
    _emailCtrl.text = widget.initialEmail ?? '';
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _googleSignIn.signOut();
      // On web, signIn() is an OAuth authorization flow and does not return
      // an ID token. The GIS authentication flow used by signInSilently does.
      final account = kIsWeb
          ? await _googleSignIn.signInSilently()
          : await _googleSignIn.signIn();
      if (account == null) {
        setState(() {
          _loading = false;
        });
        return;
      }
      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null) throw Exception('לא התקבל טוקן מגוגל');

      final res = await http
          .post(
            Uri.parse('$kApi/auth/google'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'idToken': idToken}),
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
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _passCtrl.dispose();
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
    final phone = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');

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
      if (name.isEmpty) {
        setState(() => _error = 'נא להזין שם מלא');
        return;
      }
      if (email.isEmpty || !email.contains('@')) {
        setState(() => _error = 'נא להזין כתובת אימייל תקינה');
        return;
      }
      if (phone.length < 9) {
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
                'verificationMethod': _verificationMethod
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
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => VerifyScreen(
              phone: phone,
              email: email,
              method: _verificationMethod,
            ),
          ),
        );
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
                    if (!_isLogin) ...[
                      TextField(
                        controller: _nameCtrl,
                        textDirection: TextDirection.rtl,
                        decoration: const InputDecoration(
                            labelText: 'שם מלא',
                            prefixIcon: Icon(Icons.person_outline)),
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
                                        ? 'שלח אימות'
                                        : 'המשך',
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
                          'https://www.google.com/favicon.ico',
                          width: 18,
                          height: 18,
                          errorBuilder: (_, __, ___) =>
                              const Icon(Icons.g_mobiledata, size: 22),
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

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final phone = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (phone.length < 9) {
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
      final res = await http
          .post(
            Uri.parse('$kApi/send-otp'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ${widget.token}',
            },
            body: jsonEncode({'phone': phone}),
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
    final phone = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
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
      backgroundColor: kBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const SizedBox(height: 48),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                  color: kPrimary, borderRadius: BorderRadius.circular(20)),
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
                style: TextStyle(fontSize: 14, color: kSubtext, height: 1.5)),
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
                              fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ] else ...[
              Text('נשלח קוד SMS ל-${_phoneCtrl.text}',
                  style: const TextStyle(color: kSubtext, fontSize: 13)),
              const SizedBox(height: 16),
              TextField(
                controller: _otpCtrl,
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
                              fontSize: 16, fontWeight: FontWeight.bold)),
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
                    style: const TextStyle(color: Colors.red, fontSize: 13)),
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
    return CircleAvatar(
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
  const ImagePreviewScreen({super.key, required this.url, this.filename});
  @override
  State<ImagePreviewScreen> createState() => _ImagePreviewScreenState();
}

class _ImagePreviewScreenState extends State<ImagePreviewScreen> {
  final _transform = TransformationController();
  bool _showBars = true;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
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
            InteractiveViewer(
              transformationController: _transform,
              minScale: 0.5,
              maxScale: 5.0,
              child: Center(
                child: Image.network(
                  _absoluteMediaUrl(widget.url),
                  fit: BoxFit.contain,
                  loadingBuilder: (_, child, progress) => progress == null
                      ? child
                      : const Center(
                          child:
                              CircularProgressIndicator(color: Colors.white)),
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                      color: Colors.white54, size: 64),
                ),
              ),
            ),
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
                        child: Text(
                          widget.filename ?? '',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14),
                          overflow: TextOverflow.ellipsis,
                        ),
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

// ── Main Shell (Bottom Nav) ───────────────────────────────────────
class MainShell extends StatefulWidget {
  final String token;
  const MainShell({super.key, required this.token});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _idx = 0;
  Map<String, dynamic>? _desktopRecipient;
  Map<String, dynamic>? _desktopGroup;
  bool _openGroupMembersOnSelect = false;
  IO.Socket? _socket;
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

  @override
  void initState() {
    super.initState();
    _lifecycleObserver =
        _AppLifecycleObserver(onResume: _refreshConversationState);
    _decodeMe();
    _loadMyProfile();
    _connectSocket();
    _loadUsers();
    _loadUnreadCounts();
    _loadGroupUnreadCounts();
    _registerFcmToken();
    _loadAdminPerm();
    _loadMessageRequests();
    _updateLocation();
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
    _messageRequests.removeAt(0);
    _showingMessageRequest = false;
    _showNextMessageRequest();
  }

  Future<void> _registerFcmToken() async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      final token = await messaging.getToken();
      if (token == null) return;
      await http.post(
        Uri.parse('$kApi/fcm-token'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body:
            jsonEncode({'token': token, 'deviceId': Platform.operatingSystem}),
      );
      // Refresh token when it changes
      messaging.onTokenRefresh.listen((newToken) {
        http.post(
          Uri.parse('$kApi/fcm-token'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(
              {'token': newToken, 'deviceId': Platform.operatingSystem}),
        );
      });
    } catch (_) {}
  }

  Future<void> _updateLocation() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever ||
          perm == LocationPermission.denied) return;

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      // server does Hebrew reverse geocoding via Nominatim
      await http.put(
        Uri.parse('$kApi/location'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'latitude': pos.latitude,
          'longitude': pos.longitude,
        }),
      );
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

  void _openGroup(Map<String, dynamic> group, bool openMembers) {
    final groupId = group['id'] as String;
    setState(() {
      _desktopRecipient = null;
      _desktopGroup = group;
      _openGroupMembersOnSelect = openMembers;
      _groupUnreadCounts.remove(groupId);
    });
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
        setState(() =>
            _users = (jsonDecode(cached) as List).cast<Map<String, dynamic>>());
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
        if (mounted) setState(() => _users = data.cast<Map<String, dynamic>>());
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
      } else if (msg.contains('user_not_found') ||
          msg.contains('unauthorized')) {
        _forceLogout();
      }
    });

    // אדמין מחק את המשתמש בזמן שהוא מחובר
    _socket!.on('force_logout', (_) => _forceLogout());
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
    _socket?.disconnect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
  }

  void _forceLogout() {
    _socket?.disconnect();
    SharedPreferences.getInstance().then((prefs) => prefs.remove('token'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('הפגישה פגה — נא להתחבר מחדש'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 3),
      ),
    );
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
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
      onContactsChanged: _loadUsers,
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
      ListingsScreen(token: widget.token, me: _me, socket: _socket),
      SettingsScreen(
          me: _me,
          token: widget.token,
          onLogout: _logout,
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

    return Scaffold(
      body: body,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _idx,
        onTap: (i) => setState(() => _idx = i),
        selectedItemColor: kPrimary,
        unselectedItemColor: kSubtext,
        backgroundColor: Colors.white,
        elevation: 8,
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            activeIcon: Icon(Icons.chat_bubble),
            label: 'שיחות',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.group_outlined),
            activeIcon: Icon(Icons.group),
            label: 'קבוצות',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.storefront_outlined),
            activeIcon: Icon(Icons.storefront),
            label: 'מודעות',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'הגדרות',
          ),
        ],
      ),
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
const _kCategories = [
  'הכל',
  'רהיטים',
  'אלקטרוניקה',
  'בגדים',
  'ספרים',
  'כלי בית',
  'צעצועים',
  'אחר'
];

class ListingsScreen extends StatefulWidget {
  final String token;
  final Map<String, dynamic>? me;
  final IO.Socket? socket;
  const ListingsScreen(
      {super.key, required this.token, required this.me, required this.socket});
  @override
  State<ListingsScreen> createState() => _ListingsScreenState();
}

class _ListingsScreenState extends State<ListingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _typeFilter = 'all'; // all / free / sale
  String _catFilter = 'הכל';
  String _cityFilter = '';
  double _radius = 0; // 0 = no radius filter

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.addListener(() {
      if (!_tab.indexIsChanging) {
        _typeFilter = _tab.index == 0
            ? 'all'
            : _tab.index == 1
                ? 'free'
                : 'sale';
        _load();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final params = <String, String>{'page': '1'};
      if (_typeFilter != 'all') params['type'] = _typeFilter;
      if (_catFilter != 'הכל') params['category'] = _catFilter;
      if (_cityFilter.isNotEmpty) params['city'] = _cityFilter;
      if (_radius > 0) params['radius'] = _radius.toStringAsFixed(0);
      final uri = Uri.parse('$kApi/listings').replace(queryParameters: params);
      final res = await http
          .get(uri, headers: {'Authorization': 'Bearer ${widget.token}'});
      if (!mounted) return;
      final data = jsonDecode(res.body);
      setState(() {
        _items = List<Map<String, dynamic>>.from(data);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openPost() async {
    final ok = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => PostListingScreen(token: widget.token, me: widget.me),
        ));
    if (ok == true) _load();
  }

  void _openDetail(Map<String, dynamic> item) {
    Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ListingDetailScreen(
              item: item,
              token: widget.token,
              me: widget.me,
              socket: widget.socket),
        ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: kPrimary,
        title: const Text('לוח מודעות',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
          IconButton(
              icon: const Icon(Icons.add, color: Colors.white),
              onPressed: _openPost),
        ],
        bottom: TabBar(
          controller: _tab,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(text: 'הכל'),
            Tab(text: 'ונתנו — חינם'),
            Tab(text: 'יד 2')
          ],
        ),
      ),
      body: Column(children: [
        // ── Filters ─────────────────────────────────────────────────
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(
              child: SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _kCategories.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) {
                    final c = _kCategories[i];
                    final sel = c == _catFilter;
                    return GestureDetector(
                      onTap: () {
                        setState(() => _catFilter = c);
                        _load();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: sel ? kPrimary : const Color(0xFFE8F4FD),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(c,
                            style: TextStyle(
                                fontSize: 13,
                                color: sel ? Colors.white : kPrimary,
                                fontWeight: FontWeight.w600)),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _showFilterSheet,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _cityFilter.isNotEmpty || _radius > 0
                      ? kPrimary
                      : const Color(0xFFE8F4FD),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.tune,
                    size: 20,
                    color: _cityFilter.isNotEmpty || _radius > 0
                        ? Colors.white
                        : kPrimary),
              ),
            ),
          ]),
        ),
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
                      Text('אין מודעות כרגע',
                          style: TextStyle(color: kSubtext, fontSize: 16)),
                      const SizedBox(height: 8),
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
                            onTap: () => _openDetail(_items[i])),
                      ),
                    ),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openPost,
        backgroundColor: kPrimary,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('פרסם מודעה', style: TextStyle(color: Colors.white)),
      ),
    );
  }

  void _showFilterSheet() {
    final cityCtrl = TextEditingController(text: _cityFilter);
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
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('סינון',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 16),
                          TextField(
                            controller: cityCtrl,
                            textDirection: TextDirection.rtl,
                            decoration: const InputDecoration(
                                labelText: 'עיר',
                                prefixIcon: Icon(Icons.location_city)),
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
                          const SizedBox(height: 12),
                          Row(children: [
                            Expanded(
                                child: OutlinedButton(
                              onPressed: () {
                                setState(() {
                                  _cityFilter = '';
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
                  ));
        });
  }
}

class _ListingCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onTap;
  const _ListingCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isFree = item['type'] == 'free';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
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
                ? Image.network(item['image_url'],
                    width: 110,
                    height: 110,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _placeholder())
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
                  ? Image.network(item['image_url'],
                      width: 66,
                      height: 66,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _imgPlaceholder())
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
  const PostListingScreen({super.key, required this.token, required this.me});
  @override
  State<PostListingScreen> createState() => _PostListingScreenState();
}

class _PostListingScreenState extends State<PostListingScreen> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  late final _cityCtrl =
      TextEditingController(text: widget.me?['city'] as String? ?? '');
  String _type = 'free';
  String _category = 'אחר';
  final List<String?> _imageUrls = [null, null, null, null];
  final List<bool> _uploadingSlot = [false, false, false, false];
  bool _saving = false;

  Future<void> _pickImage(int slot) async {
    final picker = ImagePicker();
    final f =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (f == null) return;
    setState(() => _uploadingSlot[slot] = true);
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
        ..headers['Authorization'] = 'Bearer ${widget.token}'
        ..files.add(await http.MultipartFile.fromPath('file', f.path,
            contentType: _mimeFromFileName(f.path)));
      final res = await req.send();
      final body = jsonDecode(await res.stream.bytesToString());
      if (!mounted) return;
      if (body['url'] != null) {
        setState(() => _imageUrls[slot] = body['url']);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(body['error'] ?? 'שגיאה בהעלאת תמונה')));
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _uploadingSlot[slot] = false);
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
      final urls = _imageUrls.where((u) => u != null).toList();
      final city = _cityCtrl.text.trim();
      final body = <String, dynamic>{
        'type': _type,
        'title': _titleCtrl.text.trim(),
        'description': _descCtrl.text.trim(),
        'category': _category,
        if (city.isNotEmpty) 'city': city,
        if (urls.isNotEmpty) 'image_urls': urls,
      };
      if (_type == 'sale')
        body['price'] = double.tryParse(_priceCtrl.text) ?? 0;
      final res = await http.post(
        Uri.parse('$kApi/listings'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json'
        },
        body: jsonEncode(body),
      );
      if (res.statusCode == 200 && mounted) Navigator.pop(context, true);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kPrimary,
        title: const Text('פרסום מודעה', style: TextStyle(color: Colors.white)),
        leading: BackButton(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Type toggle
          Row(children: [
            Expanded(
                child: _typeBtn('free', 'ונתנו — חינם', const Color(0xFFD1FAE5),
                    const Color(0xFF065F46))),
            const SizedBox(width: 10),
            Expanded(
                child: _typeBtn('sale', 'יד 2 — מכירה', const Color(0xFFEDE9FE),
                    const Color(0xFF5B21B6))),
          ]),
          const SizedBox(height: 16),
          // Images grid (up to 4)
          Text('תמונות (עד 4)',
              style: TextStyle(
                  fontSize: 13, color: kSubtext, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 4,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: List.generate(4, (i) => _imageSlot(i)),
          ),
          const SizedBox(height: 16),
          // Title
          TextField(
              controller: _titleCtrl,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(
                  labelText: 'כותרת המודעה *', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          // Description
          TextField(
              controller: _descCtrl,
              textDirection: TextDirection.rtl,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'תיאור', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          // Price (sale only)
          if (_type == 'sale') ...[
            TextField(
                controller: _priceCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'מחיר (₪)',
                    border: OutlineInputBorder(),
                    prefixText: '₪ ')),
            const SizedBox(height: 12),
          ],
          // Category
          DropdownButtonFormField<String>(
            value: _category,
            decoration: const InputDecoration(
                labelText: 'קטגוריה', border: OutlineInputBorder()),
            items: _kCategories
                .skip(1)
                .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                .toList(),
            onChanged: (v) => setState(() => _category = v!),
          ),
          const SizedBox(height: 12),
          // City
          TextField(
            controller: _cityCtrl,
            textDirection: TextDirection.rtl,
            decoration: const InputDecoration(
              labelText: 'עיר',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.location_city_outlined),
            ),
          ),
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
    );
  }

  Widget _imageSlot(int i) {
    final url = _imageUrls[i];
    final uploading = _uploadingSlot[i];
    return GestureDetector(
      onTap: uploading || url != null ? null : () => _pickImage(i),
      onLongPress:
          url != null ? () => setState(() => _imageUrls[i] = null) : null,
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
                        child: Image.network(url, fit: BoxFit.cover)),
                    Positioned(
                        top: 3,
                        left: 3,
                        child: GestureDetector(
                            onTap: () => setState(() => _imageUrls[i] = null),
                            child: Container(
                                width: 20,
                                height: 20,
                                decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle),
                                child: const Icon(Icons.close,
                                    size: 13, color: Colors.white)))),
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

  Widget _typeBtn(String val, String label, Color bg, Color fg) =>
      GestureDetector(
        onTap: () => setState(() => _type = val),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: _type == val ? bg : Colors.white,
            border: Border.all(color: _type == val ? fg : kBorder, width: 2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: fg, fontWeight: FontWeight.bold, fontSize: 13)),
        ),
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
  String _type = 'free';
  String _category = 'אחר';
  final List<String?> _imageUrls = [null, null, null, null];
  final List<bool> _uploadingSlot = [false, false, false, false];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _cityCtrl.dispose();
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
      setState(() {
        _type = item['type'] as String? ?? 'free';
        _category = item['category'] as String? ?? 'אחר';
        _titleCtrl.text = item['title'] as String? ?? '';
        _descCtrl.text = item['description'] as String? ?? '';
        _priceCtrl.text = item['price'] != null ? item['price'].toString() : '';
        _cityCtrl.text = item['city'] as String? ?? '';
        for (int i = 0; i < 4; i++) {
          _imageUrls[i] = i < imgs.length ? imgs[i] : null;
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickImage(int slot) async {
    final picker = ImagePicker();
    final f =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (f == null) return;
    setState(() => _uploadingSlot[slot] = true);
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
        ..headers['Authorization'] = 'Bearer ${widget.token}'
        ..files.add(await http.MultipartFile.fromPath('file', f.path,
            contentType: _mimeFromFileName(f.path)));
      final res = await req.send();
      final body = jsonDecode(await res.stream.bytesToString());
      if (!mounted) return;
      if (body['url'] != null) {
        setState(() => _imageUrls[slot] = body['url']);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(body['error'] ?? 'שגיאה בהעלאת תמונה')));
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _uploadingSlot[slot] = false);
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
      final urls = _imageUrls.where((u) => u != null).toList();
      final city = _cityCtrl.text.trim();
      final body = <String, dynamic>{
        'type': _type,
        'title': _titleCtrl.text.trim(),
        'description': _descCtrl.text.trim(),
        'category': _category,
        if (city.isNotEmpty) 'city': city,
        'image_urls': urls,
      };
      if (_type == 'sale')
        body['price'] = double.tryParse(_priceCtrl.text) ?? 0;
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
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [
                      Expanded(
                          child: _typeBtn(
                              'free',
                              'ונתנו — חינם',
                              const Color(0xFFD1FAE5),
                              const Color(0xFF065F46))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: _typeBtn(
                              'sale',
                              'יד 2 — מכירה',
                              const Color(0xFFEDE9FE),
                              const Color(0xFF5B21B6))),
                    ]),
                    const SizedBox(height: 16),
                    Text('תמונות (עד 4)',
                        style: TextStyle(
                            fontSize: 13,
                            color: kSubtext,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 8),
                    GridView.count(
                      crossAxisCount: 4,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: List.generate(4, (i) => _imageSlot(i)),
                    ),
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
                            labelText: 'תיאור', border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    if (_type == 'sale') ...[
                      TextField(
                          controller: _priceCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'מחיר (₪)',
                              border: OutlineInputBorder(),
                              prefixText: '₪ ')),
                      const SizedBox(height: 12),
                    ],
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
                    const SizedBox(height: 12),
                    TextField(
                      controller: _cityCtrl,
                      textDirection: TextDirection.rtl,
                      decoration: const InputDecoration(
                        labelText: 'עיר',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.location_city_outlined),
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: kPrimary,
                          padding: const EdgeInsets.symmetric(vertical: 14)),
                      onPressed: _saving ? null : _submit,
                      child: _saving
                          ? const CircularProgressIndicator(color: Colors.white)
                          : const Text('שמור שינויים',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold)),
                    ),
                  ]),
            ),
    );
  }

  Widget _imageSlot(int i) {
    final url = _imageUrls[i];
    final uploading = _uploadingSlot[i];
    return GestureDetector(
      onTap: uploading || url != null ? null : () => _pickImage(i),
      onLongPress:
          url != null ? () => setState(() => _imageUrls[i] = null) : null,
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
                        child: Image.network(url, fit: BoxFit.cover)),
                    Positioned(
                        top: 3,
                        left: 3,
                        child: GestureDetector(
                            onTap: () => setState(() => _imageUrls[i] = null),
                            child: Container(
                                width: 20,
                                height: 20,
                                decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle),
                                child: const Icon(Icons.close,
                                    size: 13, color: Colors.white)))),
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

  Widget _typeBtn(String val, String label, Color bg, Color fg) =>
      GestureDetector(
        onTap: () => setState(() => _type = val),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: _type == val ? bg : Colors.white,
            border: Border.all(color: _type == val ? fg : kBorder, width: 2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: fg, fontWeight: FontWeight.bold, fontSize: 13)),
        ),
      );
}

// ── Listing Detail Screen ─────────────────────────────────────────
class ListingDetailScreen extends StatefulWidget {
  final Map<String, dynamic> item;
  final String token;
  final Map<String, dynamic>? me;
  final IO.Socket? socket;
  const ListingDetailScreen(
      {super.key,
      required this.item,
      required this.token,
      required this.me,
      required this.socket});
  @override
  State<ListingDetailScreen> createState() => _ListingDetailScreenState();
}

class _ListingDetailScreenState extends State<ListingDetailScreen> {
  late final PageController _pageCtrl = PageController();
  int _pageIdx = 0;
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
    Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            token: widget.token,
            recipient: {
              'id': widget.item['seller_id'],
              'name': widget.item['seller_name'],
              'profile_pic_url': widget.item['seller_pic']
            },
            me: widget.me,
            socket: widget.socket,
            initialText: _listingDefaultMessage(),
          ),
        ));
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('המודעה סומנה כ$label')));
    }
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isFree = widget.item['type'] == 'free';
    final isOwner = widget.me?['id'] == widget.item['seller_id'];
    final images = _images;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: kPrimary,
        title: Text(widget.item['title'] ?? '',
            style: const TextStyle(color: Colors.white)),
        leading: BackButton(color: Colors.white),
      ),
      body: SingleChildScrollView(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (images.isNotEmpty)
            Stack(children: [
              SizedBox(
                height: 260,
                child: PageView.builder(
                  controller: _pageCtrl,
                  itemCount: images.length,
                  onPageChanged: (i) => setState(() => _pageIdx = i),
                  itemBuilder: (_, i) => Image.network(images[i],
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          Container(color: const Color(0xFFE8F4FD))),
                ),
              ),
              if (images.length > 1)
                Positioned(
                  bottom: 10,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                        images.length,
                        (i) => Container(
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              width: _pageIdx == i ? 18 : 7,
                              height: 7,
                              decoration: BoxDecoration(
                                  color: _pageIdx == i
                                      ? Colors.white
                                      : Colors.white54,
                                  borderRadius: BorderRadius.circular(4)),
                            )),
                  ),
                ),
            ])
          else
            Container(
                height: 200,
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
  final Future<void> Function() onContactsChanged;

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
    required this.onContactsChanged,
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
    final searchController = TextEditingController();
    var results = <Map<String, dynamic>>[];
    var loading = false;
    String? error;
    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> search() async {
            final query = searchController.text.trim();
            if (query.length < 2) {
              setDialogState(() => error = 'יש להזין לפחות 2 תווים');
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
              setDialogState(() {
                loading = false;
                results = response.statusCode == 200
                    ? (jsonDecode(response.body) as List)
                        .cast<Map<String, dynamic>>()
                    : [];
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

          return AlertDialog(
            title: const Text('חיפוש ושמירת חבר'),
            content: SizedBox(
              width: 430,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: searchController,
                    autofocus: true,
                    textDirection: TextDirection.rtl,
                    decoration: InputDecoration(
                      hintText: 'מספר טלפון או אימייל',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: search,
                      ),
                    ),
                    onSubmitted: (_) => search(),
                  ),
                  const SizedBox(height: 12),
                  if (loading) const CircularProgressIndicator(),
                  if (error != null && !loading)
                    Text(error!, style: const TextStyle(color: kSubtext)),
                  if (!loading && results.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: results.length,
                        itemBuilder: (_, index) {
                          final user = results[index];
                          final saved = user['saved'] == true;
                          return ListTile(
                            leading: UserAvatar(
                              picUrl: user['profile_pic_url'] as String?,
                              name: user['name'] as String? ?? '',
                            ),
                            title: Text(user['name'] as String? ?? ''),
                            subtitle: Text(
                              (user['phone'] as String?)?.isNotEmpty == true
                                  ? user['phone'] as String
                                  : user['email'] as String? ?? '',
                            ),
                            trailing: saved
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
        titleSpacing: 16,
        title: _searching
            ? TextField(
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
            : Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: _magenDavid(
                          size: 22, color: kPrimary, bg: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('בתשובה',
                          style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              height: 1.1)),
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
              if (value == 'logout') _confirmLogout();
            },
            itemBuilder: (_) => const [
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
          // Filter banner
          Container(
            color: kFilterBg,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(
              children: [
                const Icon(Icons.verified_user_outlined,
                    size: 14, color: kPrimary),
                const SizedBox(width: 7),
                const Expanded(
                  child: Text(
                    'Betshuva Filter פעיל — תוכן מסונן ומאושר',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: kHeader),
                  ),
                ),
              ],
            ),
          ),
          // Divider below banner
          Container(height: 1, color: const Color(0xFFC5DFF2)),
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
                              if (g['role'] == 'admin') ...[
                                const SizedBox(width: 6),
                                const _AdminBadge(),
                              ],
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
                          trailing:
                              unread > 0 ? _UnreadBadge(count: unread) : null,
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
                                  if (group['role'] == 'admin') ...[
                                    const SizedBox(width: 6),
                                    const _AdminBadge(),
                                  ],
                                  const Spacer(),
                                  Text(
                                    _conversationTime(group['last_message_at']),
                                    style: const TextStyle(
                                        fontSize: 11, color: kSubtext),
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
                              trailing: unread > 0
                                  ? _UnreadBadge(count: unread)
                                  : const Icon(Icons.groups_outlined,
                                      color: kPrimary, size: 20),
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
                                            socket: widget.socket)));
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

  const _ConversationTile({
    required this.user,
    required this.onTap,
    this.unreadCount = 0,
    this.selected = false,
    this.isTyping = false,
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
    final initials = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected
            ? const Color(0xFFE9EDEF)
            : (unreadCount > 0 ? const Color(0xFFF0F7FF) : Colors.white),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: unreadCount > 0 ? kPrimary : const Color(0xFFC5DFF2),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      initials,
                      style: TextStyle(
                        color: unreadCount > 0 ? Colors.white : kHeader,
                        fontWeight: FontWeight.bold,
                        fontSize: 20,
                      ),
                    ),
                  ),
                ),
                if (unreadCount > 0)
                  Positioned(
                    top: -4,
                    left: -4,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      constraints:
                          const BoxConstraints(minWidth: 20, minHeight: 20),
                      decoration: const BoxDecoration(
                        color: Color(0xFF25D366),
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        unreadCount > 99 ? '99+' : '$unreadCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
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
                      Text(
                        _conversationTime(user['last_message_at']),
                        style: const TextStyle(fontSize: 11, color: kSubtext),
                      ),
                      if (unreadCount > 0) const SizedBox(width: 6),
                      if (unreadCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: Color(0xFF25D366),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '$unreadCount הודעות',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
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
            color: Color(0xFF25D366),
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
  const _AdminBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFFFE8B2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFF2B84B)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star, size: 11, color: Color(0xFF9A6500)),
            SizedBox(width: 3),
            Text(
              'מנהל',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Color(0xFF795000),
              ),
            ),
          ],
        ),
      );
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

// ── Chat Screen ───────────────────────────────────────────────────
class ChatScreen extends StatefulWidget {
  final String token;
  final Map<String, dynamic>? me;
  final Map<String, dynamic> recipient;
  final IO.Socket? socket;
  final String? initialText;
  final bool embedded;
  final VoidCallback? onClose;

  const ChatScreen({
    super.key,
    required this.token,
    required this.me,
    required this.recipient,
    required this.socket,
    this.initialText,
    this.embedded = false,
    this.onClose,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<Map<String, dynamic>> _messages = [];
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  Map<String, dynamic>? _replyTo;
  Map<String, dynamic>? _editingMsg;
  bool _loading = true;
  bool _isTyping = false;
  late final void Function(dynamic) _chatTypingHandler;
  Timer? _messageRefreshTimer;
  String? _serverMessagesFingerprint;
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  String _voiceFileName = 'voice_message.webm';

  @override
  void initState() {
    super.initState();
    final prefill = (widget.initialText ?? '').trim();
    if (prefill.isNotEmpty) {
      _msgCtrl.text = prefill;
      _msgCtrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _msgCtrl.text.length),
      );
    }
    _loadMessages();
    _setupSocket();
    // WebSocket delivery is best-effort (a browser can sleep or reconnect).
    // Quietly reconcile with the server so an incoming message can never stay
    // invisible until the user closes and reopens the conversation.
    _messageRefreshTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _loadMessages(silent: true),
    );
  }

  Future<void> _loadMessages({bool silent = false}) async {
    final cacheKey = 'cache_msgs_${widget.recipient['id']}';
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
            if (!_messages.any((m) => m['text'] == p['text'])) _messages.add(p);
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
      'status': map['message_status'] == 'read'
          ? 'read'
          : map['message_status'] == 'delivered'
              ? 'delivered'
              : 'sent',
      if (map['reply_to_id'] != null)
        'replyTo': {
          'id': map['reply_to_id'],
          'text': map['reply_body'] ?? '',
        },
      'isFile': isFile,
      'fileType': isFile ? msgType : null,
      'fileUrl': map['file_url'],
      'fileName': map['file_name'],
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
      if (data['fromUserId'] == widget.recipient['id']) {
        if (!mounted) return;
        final fileUrl = data['fileUrl'] as String?;
        final fileName = data['fileName'] as String?;
        final fileType = _normalizeIncomingFileType(
          data['fileType'] as String?,
          fileUrl: fileUrl,
          fileName: fileName,
        );
        final isFile =
            fileUrl != null || (fileType != null && fileType != 'text');
        setState(() {
          _messages.add({
            'id':
                data['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
            'text': data['text'] as String? ?? fileName ?? '',
            'from': widget.recipient['id'],
            'time': data['createdAt'] != null
                ? _formatTime(data['createdAt'])
                : _nowTime(),
            'createdAt': data['createdAt']?.toString() ??
                DateTime.now().toIso8601String(),
            'isUnread': false,
            'status': 'received',
            'isFile': isFile,
            'fileType': fileType,
            'fileUrl': fileUrl,
            'fileName': fileName,
            if (data['replyToId'] != null)
              'replyTo': {
                'id': data['replyToId'],
                'text': data['replyBody'] ?? ''
              },
          });
          _isTyping = false;
        });
        _scrollToBottom();
        _markAsRead();
      }
    });

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
        if (idx != -1) _messages[idx]['text'] = '🚫 הודעה נמחקה';
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
    _messageRefreshTimer?.cancel();
    _recordTimer?.cancel();
    _audioRecorder.dispose();
    widget.socket?.off('chat:message');
    widget.socket?.off('chat:typing', _chatTypingHandler);
    widget.socket?.off('messages:read');
    widget.socket?.off('messages:delivered');
    widget.socket?.off('message:delivered');
    widget.socket?.off('message:deleted');
    widget.socket?.off('message:edited');
    _msgCtrl.dispose();
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
        } else {
          setState(() {
            final idx = _messages.indexWhere((m) => m['id'] == tempId);
            if (idx != -1) _messages[idx]['status'] = 'failed';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('שליחת ההודעה נכשלה')),
          );
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
            if (isMe && msg['id']?.toString().startsWith('temp_') != true)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('מחק אצל כולם',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteMessageForEveryone(msg);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMessageForEveryone(Map<String, dynamic> message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('מחיקת הודעה'),
        content: const Text('למחוק את ההודעה אצל כולם?'),
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
        body: jsonEncode({'forEveryone': true}),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() {
          message['text'] = '🚫 הודעה נמחקה';
          message['isFile'] = false;
          message['fileUrl'] = null;
          message['fileName'] = null;
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
                _openContactFilterSettings();
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('הדיווח התקבל לבדיקה')),
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
        _openContactFilterSettings();
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
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('הדיווח התקבל לבדיקה')),
          );
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
                  label: 'גלריה',
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
                  child: Text('שליחת סרטוני וידאו וקישורי YouTube אינה נתמכת',
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
    final picked = await picker.pickImage(
      source: source,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked == null) return;
    await _uploadAndSend(picked, picked.name, 'image');
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

  Future<void> _uploadAndSend(
      dynamic file, String fileName, String fileType) async {
    // Show scanning/upload dialog
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.security, color: kPrimary),
          SizedBox(width: 8),
          Text('סריקה והעלאה'),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(color: kPrimary),
          const SizedBox(height: 16),
          Text('$fileName\nעובר סריקת צניעות והעלאה...'),
        ]),
      ),
    );

    try {
      final bytes = file is XFile
          ? await file.readAsBytes()
          : (file as PlatformFile).bytes ??
              await File(file.path!).readAsBytes();
      final request = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
        ..headers['Authorization'] = 'Bearer ${widget.token}'
        ..fields['toUserId'] = widget.recipient['id'].toString()
        ..files.add(http.MultipartFile.fromBytes('file', bytes,
            filename: fileName, contentType: _mimeFromFileName(fileName)));
      final streamed =
          await request.send().timeout(const Duration(seconds: 60));
      final body = await streamed.stream.bytesToString();
      if (!mounted) return;
      Navigator.pop(context); // close dialog

      if (streamed.statusCode != 200) {
        final err = jsonDecode(body)['error'] ?? 'שגיאה בהעלאה';
        _showError(err);
        return;
      }

      final data = jsonDecode(body) as Map<String, dynamic>;
      final fileUrl = data['url'] as String;
      final isPending = data['status'] == 'pending';
      final isRejected = data['status'] == 'rejected';

      if (isRejected) {
        setState(() {
          _messages.add({
            'id': 'temp_${DateTime.now().millisecondsSinceEpoch}',
            'text': fileName,
            'from': widget.me?['id'],
            'time': _nowTime(),
            'createdAt': DateTime.now().toIso8601String(),
            'status': 'rejected_scan',
            'isFile': true,
            'fileType': fileType,
            'fileUrl': fileUrl,
            'scanReason': data['reason'],
          });
        });
        _scrollToBottom();
        _showBlockedDialog(data['reason'] as String? ?? 'התמונה לא נשלחה');
        return;
      }

      if (isPending) {
        // Scan service unavailable — file queued, server will send it later
        setState(() {
          _messages.add({
            'id': 'temp_${DateTime.now().millisecondsSinceEpoch}',
            'text': fileName,
            'from': widget.me?['id'],
            'time': _nowTime(),
            'createdAt': DateTime.now().toIso8601String(),
            'status': 'pending_scan',
            'isFile': true,
            'fileType': fileType,
            'fileUrl': fileUrl,
          });
        });
        _scrollToBottom();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('הקובץ בהמתנה לסריקה — יישלח אוטומטית כשהשירות יחזור',
                textDirection: TextDirection.rtl),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }

      // Scan passed — send via socket as usual
      widget.socket?.emit('chat:message', {
        'toUserId': widget.recipient['id'],
        'fileUrl': fileUrl,
        'fileName': fileName,
        'fileType': fileType,
        'text': null,
      });

      setState(() {
        _messages.add({
          'id': 'temp_${DateTime.now().millisecondsSinceEpoch}',
          'text': fileName,
          'from': widget.me?['id'],
          'time': _nowTime(),
          'createdAt': DateTime.now().toIso8601String(),
          'status': 'sent',
          'isFile': true,
          'fileType': fileType,
          'fileUrl': fileUrl,
        });
      });
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        _showError('שגיאת העלאה: ${e.toString()}');
      }
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
      backgroundColor: kCard,
      appBar: AppBar(
        backgroundColor: kPrimary,
        leading: BackButton(
            color: Colors.white,
            onPressed: widget.onClose ?? () => Navigator.pop(context)),
        leadingWidth: 40,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                color: Color(0xFFC5DFF2),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  recipientName.isNotEmpty
                      ? recipientName[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                      color: kHeader,
                      fontWeight: FontWeight.bold,
                      fontSize: 16),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(recipientName,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
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
            icon: const Icon(Icons.videocam_outlined, color: Colors.white),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.phone_outlined, color: Colors.white),
            onPressed: () {},
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
                          final firstUnreadIndex = _messages.indexWhere(
                              (message) => message['isUnread'] == true);
                          final showDate = messageIndex == 0 ||
                              !_sameMessageDay(
                                  msg, _messages[messageIndex - 1]);
                          return Column(
                            children: [
                              if (showDate)
                                _DateDivider(label: _messageDateLabel(msg)),
                              if (messageIndex == firstUnreadIndex)
                                const _UnreadMessagesDivider(),
                              if (msg['isGroupInvite'] == true && !isMe)
                                _GroupInviteCard(
                                  message: msg,
                                  token: widget.token,
                                  onJoined: () => setState(() {}),
                                )
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
                                    isMe: isMe,
                                    token: widget.token,
                                    me: widget.me,
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
                        Expanded(
                          child: TextField(
                            controller: _msgCtrl,
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

class _MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;
  final String token;
  final Map<String, dynamic>? me;

  const _MessageBubble({
    required this.message,
    required this.isMe,
    required this.token,
    required this.me,
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
          message: 'בהמתנה לסריקת צניעות',
          child:
              Icon(Icons.hourglass_top, size: 14, color: Colors.orangeAccent),
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

    // זיהוי קישור מודעה פנימי: betshuva://listing/{id}
    final rawText = message['text'] as String? ?? '';
    final linkRegex = RegExp(r'betshuva://listing/([\w\-]+)');
    final linkMatch = !isFile ? linkRegex.firstMatch(rawText) : null;
    final listingId = linkMatch?.group(1);
    // טקסט נקי ללא שורת הקישור
    final displayText = linkMatch != null
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
          color: isMe ? kOutgoing : kChatBg,
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
              Container(
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
                ),
              ),

            if (isAudioFile)
              VoiceMessagePlayer(url: fileUrl!, isMe: isMe)
            else if (isImageFile)
              GestureDetector(
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ImagePreviewScreen(
                        url: fileUrl!,
                        filename: message['text'] as String?,
                      ),
                    )),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    _absoluteMediaUrl(fileUrl!),
                    width: 220,
                    fit: BoxFit.cover,
                    loadingBuilder: (_, child, p) => p == null
                        ? child
                        : Container(
                            width: 220,
                            height: 160,
                            color: kBorder,
                            child: const Center(
                                child: CircularProgressIndicator(
                                    color: kPrimary, strokeWidth: 2)),
                          ),
                    errorBuilder: (_, __, ___) => Container(
                      width: 220,
                      height: 120,
                      color: kBorder,
                      child: const Icon(Icons.broken_image,
                          color: kSubtext, size: 40),
                    ),
                  ),
                ),
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
                      Icon(Icons.insert_drive_file, size: 20, color: kPrimary),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          fileName ?? message['text'] as String? ?? 'מסמך',
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
            else
              Text(
                displayText,
                style: TextStyle(fontSize: 14, height: 1.45, color: textColor),
                textDirection: TextDirection.rtl,
              ),

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

            if (message['status'] == 'pending_scan')
              const Padding(
                padding: EdgeInsets.only(top: 5),
                child: Text('ממתינה לסריקה — עדיין לא נשלחה',
                    style: TextStyle(fontSize: 11, color: Colors.orange)),
              ),
            if (message['status'] == 'rejected_scan')
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  'לא נשלחה · ${message['scanReason'] ?? 'נדחתה בסריקה'}',
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                  textDirection: TextDirection.rtl,
                ),
              ),

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
                const SizedBox(width: 3),
                _statusIcon(),
              ],
            ),
          ],
        ),
      ),
    );
  }
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('קבוצות',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            if ((widget.me?['name'] as String? ?? '').isNotEmpty)
              Text(widget.me!['name'] as String,
                  style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ],
        ),
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
                                if (isAdmin && !isPending) ...[
                                  const SizedBox(width: 6),
                                  const _AdminBadge(),
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
                            trailing:
                                const Icon(Icons.chevron_left, color: kSubtext),
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
  final _scrollCtrl = ScrollController();
  bool _loading = true;
  bool _isAdmin = false;
  bool _isTyping = false;
  String _typingName = '';
  late final void Function(dynamic) _typingSocketHandler;
  List<Map<String, dynamic>> _members = [];
  String _myStatus = 'member'; // 'member' or 'pending'
  Map<String, dynamic>? _editingMsg;
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  String _voiceFileName = 'voice_message.webm';

  String get _groupId => widget.group['id'] as String;

  @override
  void initState() {
    super.initState();
    _isAdmin = widget.group['role'] == 'admin';
    _myStatus = widget.group['status'] as String? ?? 'member';
    // A newly-created group is added after the socket connected, so its
    // creator is not yet in the room that was joined during connection.
    widget.socket?.emit('group:join', {'groupId': _groupId});
    widget.socket?.emit('group:viewed', {'groupId': _groupId});
    _loadMessages();
    _setupSocket();
    _loadMembers();
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
    var added = 0;
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
        if (res.statusCode == 200) added++;
      } catch (_) {}
    }
    if (!mounted) return;
    await _loadMembers();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$added חברים נוספו לקבוצה בהצלחה')),
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
      if (map['reply_to_id'] != null)
        'replyTo': {
          'id': map['reply_to_id'],
          'text': map['reply_body'] ?? '',
        },
    };
  }

  Future<void> _acceptPending() async {
    try {
      final res = await http.post(
        Uri.parse('$kApi/groups/$_groupId/join'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _myStatus = 'member');
        // Join socket room
        widget.socket?.emit('group:join', {'groupId': _groupId});
        // Load missed messages
        final missed = (data['missedMessages'] as List? ?? [])
            .map((m) => _mapMsg(m))
            .toList();
        if (missed.isNotEmpty) {
          setState(() {
            _messages.insertAll(0, missed);
          });
        }
        _scrollToBottom();
      }
    } catch (_) {}
  }

  Future<void> _declinePending() async {
    try {
      await http.delete(
        Uri.parse('$kApi/groups/$_groupId/decline'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {}
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

  Future<void> _inviteViaSms(String phone, String contactName) async {
    try {
      final res = await http.post(
        Uri.parse('$kApi/groups/$_groupId/invite-sms'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'phone': phone, 'contactName': contactName}),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ההזמנה נשלחה ל$contactName')),
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
    final normQ = _normalizePhone(q);
    return name.contains(q) || phone.contains(normQ);
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
    // Unregistered phone contacts — { name, phone }
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
      for (final c in contacts) {
        for (final p in c.phones) {
          final norm = _normalizePhone(p.number);
          if (norm.length >= 9)
            phoneToName.putIfAbsent(norm, () => c.displayName);
        }
      }

      if (phoneToName.isNotEmpty) {
        try {
          final res = await http.post(
            Uri.parse('$kApi/contacts/match'),
            headers: {
              'Authorization': 'Bearer ${widget.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'phones': phoneToName.keys.toList()}),
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
        unregistered = phoneToName.entries
            .where((e) => !appPhones.contains(e.key))
            .map((e) => {'name': e.value, 'phone': e.key})
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
            title: const Text('הוסף חבר לקבוצה'),
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
                        hintText: 'חיפוש לפי שם או מספר...',
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
                                        icon: const Icon(Icons.sms_outlined,
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
                                              c['phone'] as String,
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

  Future<void> _confirmAndInvite(String phone, String contactName) async {
    final myName = widget.me?['name'] as String? ?? 'חבר';
    final groupName = widget.group['name'] as String? ?? 'הקבוצה';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('הזמן את $contactName'),
        content: Text(
          '$contactName אינו רשום בבתשובה.\n\n'
          'האם לשלוח לו SMS עם הזמנה להצטרף לקבוצה "$groupName"?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton.icon(
            icon: const Icon(Icons.sms_outlined),
            label: const Text('שלח SMS'),
            style: ElevatedButton.styleFrom(backgroundColor: kPrimary),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (confirm == true) _inviteViaSms(phone, contactName);
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
    final cacheKey = 'cache_group_msgs_$_groupId';
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
        setState(() {
          final pending = _messages
              .where((message) =>
                  message['id']?.toString().startsWith('temp_') == true)
              .toList();
          _messages.clear();
          _messages.addAll(normalized);
          _messages.addAll(pending);
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
      'isEdited': map['is_edited'] == true || map['is_edited'] == 1,
      'fileUrl': map['file_url'],
      'fileName': map['file_name'],
      'fileType': _normalizeIncomingFileType(map['type'] as String?,
          fileUrl: map['file_url'] as String?,
          fileName: map['file_name'] as String?),
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
      };
      setState(() {
        final clientMessageId = data['clientMessageId'] as String?;
        final existingIndex = clientMessageId == null
            ? -1
            : _messages.indexWhere((m) => m['id'] == clientMessageId);
        if (existingIndex != -1) {
          final savedIndex =
              _messages.indexWhere((m) => m['id'] == incoming['id']);
          if (savedIndex != -1 && savedIndex != existingIndex) {
            _messages.removeAt(existingIndex);
          } else {
            _messages[existingIndex] = incoming;
          }
        } else if (!_messages.any((m) => m['id'] == incoming['id'])) {
          _messages.add(incoming);
        }
        _isTyping = false;
      });
      _scrollToBottom();
    });

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
    _recordTimer?.cancel();
    _audioRecorder.dispose();
    widget.socket?.off('group:message');
    widget.socket?.off('group:typing', _typingSocketHandler);
    widget.socket?.off('group:viewed');
    widget.socket?.off('message:edited');
    widget.socket?.off('message:deleted');
    _msgCtrl.dispose();
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
            if (isMe && msg['id']?.toString().startsWith('temp_') != true)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('מחק אצל כולם',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  _deleteGroupMessage(msg);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteGroupMessage(Map<String, dynamic> message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('מחיקת הודעה'),
        content: const Text('למחוק את ההודעה אצל כל חברי הקבוצה?'),
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
        body: jsonEncode({'forEveryone': true}),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() {
          message['text'] = '🚫 הודעה נמחקה';
          message['fileUrl'] = null;
          message['fileName'] = null;
          message['fileType'] = 'text';
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
                  label: 'גלריה',
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
    final picked = await picker.pickImage(
        source: source, maxWidth: 1920, maxHeight: 1920, imageQuality: 85);
    if (picked == null) return;
    await _uploadGroupFile(picked, picked.name, 'image');
  }

  Future<void> _pickDocument() async {
    final result = await FilePicker.platform
        .pickFiles(type: FileType.custom, allowedExtensions: ['pdf', 'docx']);
    if (result == null) return;
    final f = result.files.single;
    await _uploadGroupFile(f, f.name, 'document');
  }

  Future<void> _uploadGroupFile(
      dynamic file, String fileName, String fileType) async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.security, color: kPrimary),
          SizedBox(width: 8),
          Text('סריקה והעלאה'),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(color: kPrimary),
          const SizedBox(height: 16),
          Text('$fileName\nעובר סריקת צניעות והעלאה...'),
        ]),
      ),
    );
    try {
      final bytes = file is XFile
          ? await file.readAsBytes()
          : (file as PlatformFile).bytes ??
              await File(file.path!).readAsBytes();
      final request = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
        ..headers['Authorization'] = 'Bearer ${widget.token}'
        ..fields['groupId'] = _groupId
        ..files.add(http.MultipartFile.fromBytes('file', bytes,
            filename: fileName, contentType: _mimeFromFileName(fileName)));
      final streamed =
          await request.send().timeout(const Duration(seconds: 60));
      final body = await streamed.stream.bytesToString();
      if (!mounted) return;
      Navigator.pop(context);
      if (streamed.statusCode != 200) {
        final err = jsonDecode(body)['error'] ?? 'שגיאה בהעלאה';
        if (err.contains('נחסמה')) {
          _showGroupBlockedDialog(err);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(err), backgroundColor: Colors.red));
        }
        return;
      }
      final data = jsonDecode(body) as Map<String, dynamic>;
      final fileUrl = data['url'] as String;
      final clientMessageId =
          'group_file_${DateTime.now().microsecondsSinceEpoch}';
      widget.socket?.emit('group:message', {
        'groupId': _groupId,
        'text': null,
        'fileUrl': fileUrl,
        'fileName': fileName,
        'fileType': fileType,
        'clientMessageId': clientMessageId,
      });
      setState(() {
        _messages.add({
          'id': clientMessageId,
          'text': fileName,
          'senderName': widget.me?['name'] as String? ?? '',
          'time': _nowTime(),
          'createdAt': DateTime.now().toIso8601String(),
          'isMe': true,
          'fileType': fileType,
          'fileUrl': fileUrl,
        });
      });
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('שגיאה: $e'), backgroundColor: Colors.red));
      }
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
      await http.delete(
        Uri.parse('$kApi/groups/$_groupId/leave'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {}
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
        if (widget.onClose != null) {
          widget.onClose!();
        } else {
          Navigator.pop(context);
        }
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
            ListTile(
              leading: const Icon(Icons.info_outline, color: kPrimary),
              title: const Text('פרטי הקבוצה'),
              subtitle: Text('${_members.length} חברים'),
              onTap: () {
                Navigator.pop(context);
                _showMembersDialog();
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
                onTap: () => Navigator.pop(context),
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

  Future<void> _handleGroupMenuAction(String action) async {
    switch (action) {
      case 'info':
      case 'members':
        _showMembersDialog();
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
      case 'leave':
        _leaveGroup();
        break;
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
      backgroundColor: kCard,
      appBar: AppBar(
        backgroundColor: kPrimary,
        leading: BackButton(
            color: Colors.white,
            onPressed: widget.onClose ?? () => Navigator.pop(context)),
        title: Row(
          children: [
            UserAvatar(
              radius: 19,
              picUrl: widget.group['profile_pic_url'] as String?,
              name: widget.group['name'] as String? ?? 'קבוצה',
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.group['name'] as String,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
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
              const PopupMenuDivider(height: 8),
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
                        onPressed: _acceptPending,
                        style:
                            ElevatedButton.styleFrom(backgroundColor: kPrimary),
                        child: const Text('אשר הצטרפות',
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
                          final firstUnreadIndex = _messages.indexWhere(
                              (message) => message['isUnread'] == true);
                          final showDate = messageIndex == 0 ||
                              !_sameMessageDay(
                                  msg, _messages[messageIndex - 1]);
                          return Column(
                            crossAxisAlignment: isMe
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              if (showDate)
                                _DateDivider(label: _messageDateLabel(msg)),
                              if (messageIndex == firstUnreadIndex)
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
                              GestureDetector(
                                onTap: !kIsWeb && msg['fileUrl'] == null
                                    ? () => _copyMessageText(context, msg)
                                    : null,
                                onDoubleTap: kIsWeb && msg['fileUrl'] == null
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
                                    color: isMe ? kGroupOutgoing : kChatBg,
                                    borderRadius: BorderRadius.circular(12),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.05),
                                        blurRadius: 3,
                                      )
                                    ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      if (msg['fileUrl'] != null &&
                                          _normalizeIncomingFileType(
                                                  msg['fileType'] as String?,
                                                  fileUrl:
                                                      msg['fileUrl'] as String?,
                                                  fileName: msg['fileName']
                                                      as String?) ==
                                              'audio')
                                        VoiceMessagePlayer(
                                            url: msg['fileUrl'] as String,
                                            isMe: isMe)
                                      else if (msg['fileUrl'] != null &&
                                          _normalizeIncomingFileType(
                                                  msg['fileType'] as String?,
                                                  fileUrl:
                                                      msg['fileUrl'] as String?,
                                                  fileName: msg['fileName']
                                                      as String?) ==
                                              'image')
                                        GestureDetector(
                                          onTap: () => Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                  builder: (_) =>
                                                      ImagePreviewScreen(
                                                          url: msg['fileUrl']
                                                              as String,
                                                          filename:
                                                              msg['fileName']
                                                                  as String?))),
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            child: Image.network(
                                              _absoluteMediaUrl(
                                                  msg['fileUrl'] as String),
                                              width: 200,
                                              fit: BoxFit.cover,
                                              loadingBuilder: (_, child, p) => p ==
                                                      null
                                                  ? child
                                                  : Container(
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
                                              errorBuilder: (_, __, ___) =>
                                                  Container(
                                                      width: 200,
                                                      height: 100,
                                                      color: kBorder,
                                                      child: const Icon(
                                                          Icons.broken_image,
                                                          color: kSubtext)),
                                            ),
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
                                            padding: const EdgeInsets.symmetric(
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
                                                        style: const TextStyle(
                                                            fontSize: 13))),
                                                const SizedBox(width: 10),
                                                const Icon(Icons.download,
                                                    size: 19, color: kPrimary),
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
                                      else
                                        Text(
                                          msg['text'] as String? ?? '',
                                          style: const TextStyle(
                                              fontSize: 15, height: 1.4),
                                          textDirection: TextDirection.rtl,
                                        ),
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
                    icon: const Icon(Icons.attach_file, color: kSubtext),
                    onPressed: _showAttachMenu,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
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
  const ContentFilterSettingsScreen(
      {super.key, required this.token, this.contactId, this.contactName});

  @override
  State<ContentFilterSettingsScreen> createState() =>
      _ContentFilterSettingsScreenState();
}

class _ContentFilterSettingsScreenState
    extends State<ContentFilterSettingsScreen> {
  bool _loading = true;
  bool _saving = false;
  bool _inherit = true;
  Map<String, bool> _filter = {
    'text': true,
    'nonHumanImages': true,
    'men': true,
    'women': true,
    'children': true,
  };

  bool get _isContact => widget.contactId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final path = _isContact
          ? '/contacts/${widget.contactId}/filter-settings'
          : '/filter-settings';
      final response = await http.get(Uri.parse('$kApi$path'),
          headers: {'Authorization': 'Bearer ${widget.token}'});
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) throw Exception(data['error'] ?? 'שגיאה');
      final raw = (_isContact ? data['filter'] : data) as Map<String, dynamic>;
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
      final path = _isContact
          ? '/contacts/${widget.contactId}/filter-settings'
          : '/filter-settings';
      final body = _isContact
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
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('שמירת ההגדרות נכשלה: $e')),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _option(String key, String title, String subtitle, IconData icon) =>
      SwitchListTile(
        secondary: Icon(icon, color: kPrimary),
        title: Text(title),
        subtitle: Text(subtitle),
        activeColor: kPrimary,
        value: _filter[key] == true,
        onChanged:
            _inherit ? null : (value) => setState(() => _filter[key] = value),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_isContact
              ? 'סינון עבור ${widget.contactName ?? 'איש קשר'}'
              : 'סינון תוכן כללי')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              if (_isContact) ...[
                SwitchListTile(
                  title: const Text('השתמש בהגדרות הכלליות'),
                  subtitle:
                      const Text('שינויים עתידיים בהגדרה הכללית יחולו גם כאן'),
                  value: _inherit,
                  activeColor: kPrimary,
                  onChanged: (value) => setState(() => _inherit = value),
                ),
                const Divider(height: 1),
              ],
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 18, 18, 8),
                child: Text('סוגי תוכן מותרים',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              _option('text', 'טקסט', 'הודעות טקסט רגילות', Icons.text_fields),
              _option('nonHumanImages', 'תמונות ללא בני אדם',
                  'חפצים, נוף, צמחים ובעלי חיים', Icons.landscape_outlined),
              _option('men', 'גברים', 'תמונות שסווגו כתמונות גברים', Icons.man),
              _option(
                  'women', 'נשים', 'תמונות שסווגו כתמונות נשים', Icons.woman),
              _option('children', 'ילדים', 'תמונות שסווגו כתמונות ילדים',
                  Icons.child_care),
              const Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                    'כל התמונות עוברות בדיקת צניעות תמיד, ללא קשר לבחירות כאן.',
                    style: TextStyle(color: kSubtext)),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
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
    );
  }
}

// ── Settings Screen ───────────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  final Map<String, dynamic>? me;
  final String token;
  final VoidCallback onLogout;
  final Future<void> Function() onProfileChanged;
  final String? adminPerm;
  const SettingsScreen(
      {super.key,
      required this.me,
      required this.token,
      required this.onLogout,
      required this.onProfileChanged,
      this.adminPerm});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _strictFilter = false;
  bool _hidePicture = false;
  bool _notifications = true;
  bool _readReceipts = true;

  @override
  Widget build(BuildContext context) {
    final name = widget.me?['name'] as String? ?? 'משתמש';
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
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
      body: ListView(
        children: [
          // Profile header
          InkWell(
            onTap: () async {
              final changed = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        ProfileScreen(me: widget.me, token: widget.token)),
              );
              if (changed == true) await widget.onProfileChanged();
            },
            child: Container(
              color: kCard,
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: kPrimaryMid,
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                        const Text('ערוך פרופיל',
                            style: TextStyle(color: kSubtext, fontSize: 13)),
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
          const _SectionHeader(title: 'הגדרות צניעות'),
          Container(
            color: kCard,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.tune, color: kPrimary),
                  title: const Text('סוגי תוכן מותרים'),
                  subtitle: const Text('טקסט, תמונות, גברים, נשים וילדים'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ContentFilterSettingsScreen(
                          token: widget.token,
                        ),
                      )),
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  activeColor: kPrimary,
                  title: const Text('סינון תוכן מחמיר (Strict)'),
                  subtitle: const Text('חסימה מרבית של תוכן'),
                  value: _strictFilter,
                  onChanged: (v) => setState(() => _strictFilter = v),
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  activeColor: kPrimary,
                  title: const Text('הסתר תמונת פרופיל'),
                  subtitle: const Text('לא יראו את תמונתך'),
                  value: _hidePicture,
                  onChanged: (v) => setState(() => _hidePicture = v),
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
                  onChanged: (v) => setState(() => _notifications = v),
                ),
                const Divider(height: 1, indent: 16),
                SwitchListTile(
                  activeColor: kPrimary,
                  title: const Text('אישורי קריאה'),
                  subtitle: const Text('שלח אישור כשנקראת הודעה'),
                  value: _readReceipts,
                  onChanged: (v) => setState(() => _readReceipts = v),
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
                  trailing: const Icon(Icons.chevron_left, color: kSubtext),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              BlockedUsersScreen(token: widget.token))),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.lock_outline, color: kSubtext),
                  title: const Text('מדיניות פרטיות'),
                  trailing: const Icon(Icons.chevron_left, color: kSubtext),
                  onTap: () {},
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // About
          const _SectionHeader(title: 'אודות'),
          Container(
            color: kCard,
            child: const Column(
              children: [
                ListTile(
                  leading: Icon(Icons.info_outline, color: kSubtext),
                  title: Text('גרסה'),
                  trailing: Text(kVersion, style: TextStyle(color: kSubtext)),
                ),
                Divider(height: 1, indent: 16),
                ListTile(
                  leading: Icon(Icons.verified_outlined, color: kAccent),
                  title: Text('בתשובה Messenger'),
                  subtitle: Text('מסרים לקהילה החרדית'),
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
                leading:
                    const Icon(Icons.admin_panel_settings, color: kPrimary),
                title: const Text('לוח ניהול'),
                subtitle: Text(
                    widget.adminPerm == 'edit' ? 'הרשאת עריכה' : 'הרשאת צפייה',
                    style: const TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.chevron_left, color: kSubtext),
                onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => AdminScreen(
                            token: widget.token, perm: widget.adminPerm!))),
              ),
            ),
            const SizedBox(height: 8),
          ],

          const SizedBox(height: 8),

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
  final _communityCtrl = TextEditingController();
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
    _communityCtrl.dispose();
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
          _communityCtrl.text = data['community'] as String? ?? '';
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
          'community': _communityCtrl.text.trim(),
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
      final request = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
        ..headers['Authorization'] = 'Bearer ${widget.token}'
        ..files.add(await http.MultipartFile.fromPath('file', picked.path,
            filename: picked.name,
            contentType: _mimeFromFileName(picked.name)));
      final streamed = await request.send();
      final body = await streamed.stream.bytesToString();
      if (!mounted) return;
      if (streamed.statusCode == 200) {
        final url = (jsonDecode(body) as Map)['url'] as String;
        setState(() {
          _picUrl = url;
          _saving = false;
        });
      } else {
        setState(() {
          _error = 'שגיאה בהעלאת תמונה';
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
                  child: Text('לחץ לשינוי תמונה • תעבור סריקת צניעות',
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

                _FieldLabel(label: 'קהילה'),
                const SizedBox(height: 6),
                TextField(
                  controller: _communityCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(hintText: 'קהילה / כולל'),
                ),
                const SizedBox(height: 20),

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
                TextField(
                  controller: _cityCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(hintText: 'עיר מגורים'),
                ),
                const SizedBox(height: 14),

                _FieldLabel(label: 'רחוב'),
                const SizedBox(height: 6),
                TextField(
                  controller: _streetCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(hintText: 'שם הרחוב'),
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

class _AppLifecycleObserver extends WidgetsBindingObserver {
  final VoidCallback onResume;
  _AppLifecycleObserver({required this.onResume});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}
