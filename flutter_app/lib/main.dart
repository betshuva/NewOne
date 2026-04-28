import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:url_launcher/url_launcher.dart';

// ── Local notifications setup ─────────────────────────────────────
final _localNotif = FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage msg) async {
  await Firebase.initializeApp();
}

Future<void> _initLocalNotifications() async {
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const ios     = DarwinInitializationSettings();
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
        'betshuva_messages', 'הודעות',
        importance: Importance.high,
        priority: Priority.high,
        sound: RawResourceAndroidNotificationSound('default'),
      ),
      iOS: DarwinNotificationDetails(sound: 'default'),
    ),
  );
}

// ── Color Palette — Betshuva Brand ───────────────────────────────
const kPrimary    = Color(0xFF1B6CA8); // Betshuva Blue
const kPrimaryMid = Color(0xFF3A8FCC); // Blue Light
const kAccent     = Color(0xFF3A8FCC); // Blue Light
const kHeader     = Color(0xFF0D4F82); // App bar / header
const kBg         = Color(0xFFFFFFFF);
const kCard       = Color(0xFFFFFFFF);
const kBorder     = Color(0xFFD4E9F7); // divider
const kSubtext    = Color(0xFF8AAFC9); // text-muted
const kTextDark   = Color(0xFF0D2137); // text-primary
const kReadTick   = Color(0xFF93C5E8); // read double-tick
const kOutgoing   = Color(0xFF1B6CA8); // outgoing bubble — brand blue
const kChatBg     = Color(0xFFEBF5FC); // chat background
const kFilterBg   = Color(0xFFE8F4FD); // filter banner background

const kServer  = 'https://xo-app-betshuva.azurewebsites.net';
const kApi     = '$kServer/api';
const kVersion = '1.1.0';

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
    canvas.drawCircle(Offset(size.width / 2, size.height / 2),
        size.width / 2, bg);

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
        if (i == 0) p.moveTo(x, y);
        else p.lineTo(x, y);
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

Widget _magenDavid({double size = 32, Color color = kPrimary,
    Color bg = Colors.white}) =>
    CustomPaint(
      size: Size(size, size),
      painter: _MagenDavidPainter(color, bg),
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

  static const _currentVersion = kVersion;

  Future<void> _navigate() async {
    final prefs = await SharedPreferences.getInstance();
    final token  = prefs.getString('token');
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => token != null
            ? MainShell(token: token)
            : const PhoneAuthScreen(),
      ),
    );
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    try {
      final res = await http.get(Uri.parse('$kApi/version'));
      if (res.statusCode != 200 || !mounted) return;
      final data       = jsonDecode(res.body);
      final latest     = data['version'] as String;
      final apkUrl     = data['apkUrl']  as String;
      if (latest == _currentVersion) return;
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.system_update, color: kPrimary),
            SizedBox(width: 10),
            Text('עדכון זמין'),
          ]),
          content: Text(
            'גירסה $latest זמינה!\nגירסתך הנוכחית: $_currentVersion',
            textDirection: TextDirection.rtl,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('אחר כך', style: TextStyle(color: kSubtext)),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                http.get(Uri.parse(apkUrl));
              },
              icon: const Icon(Icons.download),
              label: const Text('הורד עכשיו'),
            ),
          ],
        ),
      );
    } catch (_) {}
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
              _magenDavid(size: 96, color: Colors.white, bg: Colors.transparent),
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
  final _phoneCtrl = TextEditingController();
  final _nameCtrl  = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _otpCtrl   = TextEditingController();
  bool    _otpSent  = false;
  bool    _loading  = false;
  String? _error;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final phone = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    final email = _emailCtrl.text.trim();
    if (_nameCtrl.text.trim().isEmpty) { setState(() => _error = 'נא להזין שם מלא'); return; }
    if (email.isEmpty || !email.contains('@')) { setState(() => _error = 'נא להזין כתובת אימייל תקינה'); return; }
    if (phone.length < 9) { setState(() => _error = 'נא להזין מספר טלפון תקין'); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final res = await http.post(
        Uri.parse('$kApi/send-otp'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'phone': phone, 'name': _nameCtrl.text.trim(), 'email': email}),
      ).timeout(const Duration(seconds: 30));
      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        setState(() { _error = data['error'] ?? 'שגיאה בשליחה'; _loading = false; }); return;
      }
      setState(() { _otpSent = true; _loading = false; });
    } catch (_) {
      setState(() { _error = 'שגיאת חיבור. נסה שוב.'; _loading = false; });
    }
  }

  Future<void> _verifyOtp() async {
    final code = _otpCtrl.text.trim();
    if (code.length < 6) { setState(() => _error = 'נא להזין קוד בן 6 ספרות'); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final phone = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
      final res = await http.post(
        Uri.parse('$kApi/verify-otp'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'phone': phone, 'code': code, 'name': _nameCtrl.text.trim()}),
      ).timeout(const Duration(seconds: 30));
      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        setState(() { _error = data['error'] ?? 'קוד שגוי'; _loading = false; }); return;
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
      setState(() { _error = 'שגיאת חיבור. נסה שוב.'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              Container(
                width: 88, height: 88,
                decoration: BoxDecoration(color: kPrimary, borderRadius: BorderRadius.circular(22)),
                child: const Icon(Icons.chat_bubble_outline_rounded, size: 48, color: Colors.white),
              ),
              const SizedBox(height: 20),
              const Text('בתשובה',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: kPrimary)),
              const SizedBox(height: 8),
              Text(
                _otpSent ? 'הזן את הקוד שנשלח ב-SMS' : 'הרשמה / כניסה עם טלפון',
                style: const TextStyle(fontSize: 15, color: kSubtext),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 36),
              if (!_otpSent) ...[
                TextField(
                  controller: _nameCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(
                    labelText: 'שם מלא', prefixIcon: Icon(Icons.person_outline)),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'כתובת אימייל',
                    hintText: 'example@gmail.com',
                    prefixIcon: Icon(Icons.email_outlined),
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
                  style: const TextStyle(fontSize: 32, letterSpacing: 12, fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(labelText: 'קוד אימות', counterText: ''),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                  child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : (_otpSent ? _verifyOtp : _sendOtp),
                  child: _loading
                      ? const SizedBox(height: 22, width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(
                          _otpSent ? 'אמת קוד' : 'שלח קוד SMS',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                ),
              ),
              if (_otpSent) ...[
                const SizedBox(height: 14),
                TextButton(
                  onPressed: () => setState(() { _otpSent = false; _error = null; _otpCtrl.clear(); }),
                  child: const Text('שנה מספר טלפון', style: TextStyle(color: kSubtext)),
                ),
              ] else ...[
                const SizedBox(height: 14),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AuthScreen()),
                  ),
                  child: const Text('כניסה עם אימייל', style: TextStyle(color: kSubtext, fontSize: 13)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Auth Screen (Login / Register) ───────────────────────────────
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool    _isLogin = true;
  bool    _loading = false;
  String? _error;

  final _nameCtrl  = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  final _phoneCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email    = _emailCtrl.text.trim();
    final password = _passCtrl.text;
    final name     = _nameCtrl.text.trim();
    final phone    = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');

    if (_isLogin) {
      if (email.isEmpty || !email.contains('@')) { setState(() => _error = 'נא להזין כתובת אימייל תקינה'); return; }
      if (password.length < 6) { setState(() => _error = 'הסיסמה חייבת להיות לפחות 6 תווים'); return; }
    } else {
      if (name.isEmpty) { setState(() => _error = 'נא להזין שם מלא'); return; }
      if (email.isEmpty || !email.contains('@')) { setState(() => _error = 'נא להזין כתובת אימייל תקינה'); return; }
      if (password.length < 6) { setState(() => _error = 'הסיסמה חייבת להיות לפחות 6 תווים'); return; }
      if (phone.length < 9) { setState(() => _error = 'נא להזין מספר טלפון תקין'); return; }
    }

    setState(() { _loading = true; _error = null; });
    try {
      if (_isLogin) {
        final res  = await http.post(
          Uri.parse('$kApi/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        ).timeout(const Duration(seconds: 30));
        final data = jsonDecode(res.body);
        if (res.statusCode != 200) {
          setState(() { _error = data['error'] ?? 'שגיאה'; _loading = false; }); return;
        }
        final token = data['token'] as String;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', token);
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => MainShell(token: token)));
      } else {
        final res = await http.post(
          Uri.parse('$kApi/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'name': name, 'email': email, 'password': password, 'phone': phone}),
        ).timeout(const Duration(seconds: 30));
        final data = jsonDecode(res.body);
        if (res.statusCode != 200) {
          setState(() { _error = data['error'] ?? 'שגיאה'; _loading = false; }); return;
        }
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => VerifyScreen(phone: phone, email: email)),
        );
      }
    } catch (_) {
      setState(() { _error = 'שגיאת חיבור. נסה שוב.'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              Container(
                width: 88, height: 88,
                decoration: BoxDecoration(color: kPrimary, borderRadius: BorderRadius.circular(22)),
                child: const Icon(Icons.chat_bubble_outline_rounded, size: 48, color: Colors.white),
              ),
              const SizedBox(height: 20),
              const Text('בתשובה',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: kPrimary)),
              const SizedBox(height: 4),
              const Text('🇮🇱', style: TextStyle(fontSize: 22)),
              const SizedBox(height: 6),
              Text(_isLogin ? 'כניסה לחשבון' : 'יצירת חשבון חדש',
                  style: const TextStyle(fontSize: 15, color: kSubtext)),
              const SizedBox(height: 32),
              // Toggle
              Container(
                decoration: BoxDecoration(color: kBorder, borderRadius: BorderRadius.circular(10)),
                child: Row(children: [
                  _TabBtn(label: 'כניסה',  active: _isLogin,
                      onTap: () => setState(() { _isLogin = true;  _error = null; })),
                  _TabBtn(label: 'הרשמה', active: !_isLogin,
                      onTap: () => setState(() { _isLogin = false; _error = null; })),
                ]),
              ),
              const SizedBox(height: 24),
              if (!_isLogin) ...[
                TextField(
                  controller: _nameCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(
                    labelText: 'שם מלא', prefixIcon: Icon(Icons.person_outline)),
                ),
                const SizedBox(height: 14),
              ],
              TextField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'כתובת אימייל', prefixIcon: Icon(Icons.email_outlined)),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passCtrl,
                obscureText: true,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'סיסמה', prefixIcon: Icon(Icons.lock_outline)),
              ),
              if (!_isLogin) ...[
                const SizedBox(height: 14),
                TextField(
                  controller: _phoneCtrl,
                  keyboardType: TextInputType.phone,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                    labelText: 'מספר טלפון', hintText: '05X-XXX-XXXX',
                    prefixIcon: Icon(Icons.phone_android)),
                ),
              ],
              if (_isLogin) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
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
                    color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.red, fontSize: 13)),
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(height: 22, width: 22,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(_isLogin ? 'כניסה' : 'הרשמה',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabBtn({required this.label, required this.active, required this.onTap});
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
        child: Text(label,
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
  const VerifyScreen({super.key, required this.phone, required this.email});
  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  final _codeCtrl = TextEditingController();
  bool    _loading      = false;

  bool    _waitingEmail = false;
  String? _error;

  @override
  void dispose() { _codeCtrl.dispose(); super.dispose(); }

  Future<void> _verifyPhone() async {
    final code = _codeCtrl.text.trim();
    if (code.length < 6) { setState(() => _error = 'נא להזין קוד בן 6 ספרות'); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final res = await http.post(
        Uri.parse('$kApi/verify-phone'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'phone': widget.phone, 'code': code}),
      ).timeout(const Duration(seconds: 30));
      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        setState(() { _error = data['error'] ?? 'קוד שגוי'; _loading = false; }); return;
      }
      if (data['token'] != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('token', data['token'] as String);
        if (!mounted) return;
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => MainShell(token: data['token'] as String)));
      } else {
        setState(() { _waitingEmail = true; _loading = false; });
      }
    } catch (_) {
      setState(() { _error = 'שגיאת חיבור. נסה שוב.'; _loading = false; });
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
                  const Icon(Icons.mark_email_read_outlined, size: 80, color: kAccent),
                  const SizedBox(height: 24),
                  const Text('הטלפון אומת ✅',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: kPrimary),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(
                    'נשלח קישור אימות ל-${widget.email}\nלחץ על הקישור במייל להשלמת ההרשמה.',
                    style: const TextStyle(color: kSubtext, fontSize: 14, height: 1.6),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pushReplacement(
                          context, MaterialPageRoute(builder: (_) => const AuthScreen())),
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
                          'שלחנו קוד SMS ל-${widget.phone} וקישור אימות ל-${widget.email}',
                          style: const TextStyle(fontSize: 13, color: kPrimary, height: 1.4),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 28),
                  const Text('שלב 1: אימות טלפון',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: kPrimary)),
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
                    style: const TextStyle(fontSize: 32, letterSpacing: 12, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(labelText: 'קוד אימות', counterText: ''),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                      child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _verifyPhone,
                      child: _loading
                          ? const SizedBox(height: 22, width: 22,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('אמת טלפון',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Divider(),
                  const SizedBox(height: 16),
                  Row(children: [
                    const Icon(Icons.email_outlined, color: kSubtext, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'שלב 2: לחץ על הקישור שנשלח ל-${widget.email} לאימות האימייל',
                        style: const TextStyle(color: kSubtext, fontSize: 13, height: 1.4),
                      ),
                    ),
                  ]),
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
  bool    _loading = false;
  bool    _sent    = false;
  String? _error;

  @override
  void dispose() { _emailCtrl.dispose(); super.dispose(); }

  Future<void> _send() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'נא להזין כתובת אימייל תקינה'); return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await http.post(
        Uri.parse('$kApi/forgot-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );
      setState(() { _sent = true; _loading = false; });
    } catch (_) {
      setState(() { _error = 'שגיאת חיבור. נסה שוב.'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('שכחתי סיסמה'),
        leading: BackButton(color: Colors.white, onPressed: () => Navigator.pop(context)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: _sent
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.mark_email_read_outlined, size: 72, color: kAccent),
                  const SizedBox(height: 20),
                  const Text('נשלח מייל לאיפוס הסיסמה',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: kPrimary),
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
                      labelText: 'כתובת אימייל', prefixIcon: Icon(Icons.email_outlined)),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _loading ? null : _send,
                      child: _loading
                          ? const SizedBox(height: 22, width: 22,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('שלח קישור לאיפוס',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
  IO.Socket? _socket;
  Map<String, dynamic>? _me;
  List<Map<String, dynamic>> _users = [];

  @override
  void initState() {
    super.initState();
    _decodeMe();
    _connectSocket();
    _loadUsers();
    _registerFcmToken();
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
        body: jsonEncode({'token': token, 'deviceId': Platform.operatingSystem}),
      );
      // Refresh token when it changes
      messaging.onTokenRefresh.listen((newToken) {
        http.post(
          Uri.parse('$kApi/fcm-token'),
          headers: {
            'Authorization': 'Bearer ${widget.token}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'token': newToken, 'deviceId': Platform.operatingSystem}),
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

  Future<void> _loadUsers() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/users'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        setState(() => _users = data.cast<Map<String, dynamic>>());
      }
    } catch (_) {}
  }

  void _connectSocket() {
    _socket = IO.io(
      kServer,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': widget.token})
          .build(),
    );
  }

  Future<void> _logout() async {
    _socket?.disconnect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const PhoneAuthScreen()),
    );
  }

  @override
  void dispose() {
    _socket?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      ConversationsScreen(
        users: _users,
        token: widget.token,
        me: _me,
        socket: _socket,
      ),
      GroupsScreen(token: widget.token, me: _me, socket: _socket),
      SettingsScreen(me: _me, token: widget.token, onLogout: _logout),
    ];

    return Scaffold(
      body: screens[_idx],
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
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'הגדרות',
          ),
        ],
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

  const ConversationsScreen({
    super.key,
    required this.users,
    required this.token,
    required this.me,
    required this.socket,
  });

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  int _tab = 0;
  static const _tabs = ['כל השיחות', 'לא נקרא', 'קבוצות'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F6FC),
      appBar: AppBar(
        backgroundColor: kPrimary,
        elevation: 0,
        titleSpacing: 16,
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: _magenDavid(size: 22, color: kPrimary, bg: Colors.white),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text('בתשובה',
                    style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.1)),
                Text('Betshuva',
                    style: TextStyle(
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
            icon: const Icon(Icons.search, color: Colors.white),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: () {},
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
                    onTap: () => setState(() => _tab = i),
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
                          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
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
          Expanded(
            child: widget.users.isEmpty
                ? const Center(
                    child: Text('אין משתמשים רשומים עדיין',
                        style: TextStyle(color: kSubtext, fontSize: 15)),
                  )
                : ListView.separated(
                    itemCount: widget.users.length,
                    separatorBuilder: (_, __) => const Divider(
                        height: 1,
                        color: Color(0xFFD4E9F7),
                        indent: 76,
                        endIndent: 0),
                    itemBuilder: (_, i) {
                      final user = widget.users[i];
                      return _ConversationTile(
                        user: user,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatScreen(
                              token: widget.token,
                              me: widget.me,
                              recipient: user,
                              socket: widget.socket,
                            ),
                          ),
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

class _ConversationTile extends StatelessWidget {
  final Map<String, dynamic> user;
  final VoidCallback onTap;

  const _ConversationTile({required this.user, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name     = user['name'] as String? ?? '';
    final initials = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return InkWell(
      onTap: onTap,
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Color(0xFFC5DFF2),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  initials,
                  style: const TextStyle(
                    color: kHeader,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              color: kTextDark,
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
                      const Text('עכשיו',
                          style: TextStyle(fontSize: 11, color: kSubtext)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'לחץ לפתיחת שיחה',
                    style: TextStyle(fontSize: 12, color: kSubtext),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Chat Screen ───────────────────────────────────────────────────
class ChatScreen extends StatefulWidget {
  final String token;
  final Map<String, dynamic>? me;
  final Map<String, dynamic> recipient;
  final IO.Socket? socket;

  const ChatScreen({
    super.key,
    required this.token,
    required this.me,
    required this.recipient,
    required this.socket,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<Map<String, dynamic>> _messages = [];
  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();
  Map<String, dynamic>? _replyTo;
  bool _loading = true;
  bool _isTyping = false;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _setupSocket();
  }

  Future<void> _loadMessages() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/messages/${widget.recipient['id']}'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        setState(() {
          // Keep pending (optimistic) messages not yet confirmed by server
          final pending = _messages
              .where((m) => (m['id'] as String? ?? '').startsWith('temp_'))
              .toList();
          _messages.clear();
          _messages.addAll(data.map(_normalizeDbMessage));
          for (final p in pending) {
            final alreadyIn = _messages.any((m) => m['text'] == p['text']);
            if (!alreadyIn) _messages.add(p);
          }
          _loading = false;
        });
        _scrollToBottom();
        _markAsRead();
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic> _normalizeDbMessage(dynamic m) {
    final map = m as Map<String, dynamic>;
    return {
      'id':     map['id'],
      'text':   map['body'] ?? '',
      'from':   map['sender_id'],
      'time':   _formatTime(map['created_at']),
      'status': (map['is_read'] == true || map['is_read'] == 1) ? 'read' : 'sent',
      if (map['reply_to_id'] != null) 'replyTo': {
        'id':   map['reply_to_id'],
        'text': map['reply_body'] ?? '',
      },
      'isFile': map['type'] != null && map['type'] != 'text',
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
        setState(() {
          _messages.add({
            'id':     data['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
            'text':   data['text'] as String? ?? '',
            'from':   widget.recipient['id'],
            'time':   data['createdAt'] != null ? _formatTime(data['createdAt']) : _nowTime(),
            'status': 'received',
            if (data['replyToId'] != null) 'replyTo': {'id': data['replyToId'], 'text': ''},
          });
          _isTyping = false;
        });
        _scrollToBottom();
        _markAsRead();
      }
    });

    widget.socket?.on('chat:typing', (data) {
      if (data['fromUserId'] == widget.recipient['id'] && mounted) {
        setState(() => _isTyping = true);
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _isTyping = false);
        });
      }
    });

    widget.socket?.on('messages:read', (_) {
      if (!mounted) return;
      setState(() {
        for (final msg in _messages) {
          if (msg['from'] == widget.me?['id']) msg['status'] = 'read';
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
    widget.socket?.off('chat:message');
    widget.socket?.off('chat:typing');
    widget.socket?.off('messages:read');
    widget.socket?.off('message:deleted');
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  String _nowTime() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  void _send() {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    final replySnapshot = _replyTo;
    setState(() {
      _messages.add({
        'id':     'temp_${DateTime.now().millisecondsSinceEpoch}',
        'text':   text,
        'from':   widget.me?['id'],
        'time':   _nowTime(),
        'status': 'sent',
        if (replySnapshot != null) 'replyTo': Map<String, dynamic>.from(replySnapshot),
      });
      _replyTo = null;
      _msgCtrl.clear();
    });
    widget.socket?.emit('chat:message', {
      'toUserId':  widget.recipient['id'],
      'text':      text,
      if (replySnapshot != null) 'replyToId': replySnapshot['id'],
    });
    _scrollToBottom();
  }

  void _onTyping() {
    widget.socket?.emit('chat:typing', {'toUserId': widget.recipient['id']});
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
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

  Future<void> _blockUser() async {
    final recipientName = widget.recipient['name'] as String? ?? 'משתמש זה';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('חסימת משתמש'),
        content: Text('לחסום את $recipientName?\nלא יוכל לשלוח לך הודעות.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
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
                  onTap: () { Navigator.pop(context); _pickFile(ImageSource.gallery); },
                ),
                _AttachOption(
                  icon: Icons.camera_alt_outlined,
                  label: 'מצלמה',
                  color: kPrimaryMid,
                  onTap: () { Navigator.pop(context); _pickFile(ImageSource.camera); },
                ),
                _AttachOption(
                  icon: Icons.picture_as_pdf_outlined,
                  label: 'מסמך',
                  color: Colors.orange,
                  onTap: () { Navigator.pop(context); _pickDocument(); },
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
    await _uploadAndSend(File(picked.path), picked.name, 'image');
  }

  Future<void> _pickDocument() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx'],
    );
    if (result == null || result.files.single.path == null) return;
    final f = result.files.single;
    await _uploadAndSend(File(f.path!), f.name, 'document');
  }

  Future<void> _uploadAndSend(File file, String fileName, String fileType) async {
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
      final request = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
        ..headers['Authorization'] = 'Bearer ${widget.token}'
        ..files.add(await http.MultipartFile.fromPath('file', file.path,
            filename: fileName));
      final streamed = await request.send();
      final body     = await streamed.stream.bytesToString();
      if (!mounted) return;
      Navigator.pop(context); // close dialog

      if (streamed.statusCode != 200) {
        final err = jsonDecode(body)['error'] ?? 'שגיאה בהעלאה';
        _showError(err);
        return;
      }

      final data = jsonDecode(body) as Map<String, dynamic>;
      final fileUrl = data['url'] as String;

      // Send via socket as file message
      widget.socket?.emit('chat:message', {
        'toUserId': widget.recipient['id'],
        'fileUrl':  fileUrl,
        'fileName': fileName,
        'fileType': fileType,
        'text':     null,
      });

      setState(() {
        _messages.add({
          'id':       'temp_${DateTime.now().millisecondsSinceEpoch}',
          'text':     fileName,
          'from':     widget.me?['id'],
          'time':     _nowTime(),
          'status':   'sent',
          'isFile':   true,
          'fileType': fileType,
          'fileUrl':  fileUrl,
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, textDirection: TextDirection.rtl),
        backgroundColor: Colors.red.shade700,
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
            onPressed: () => Navigator.pop(context)),
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
                        style:
                            TextStyle(fontSize: 11, color: Colors.white70)),
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
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showChatMenu(),
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
                    width: 3, height: 36, color: kPrimary,
                    margin: const EdgeInsets.only(left: 8),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('ציטוט',
                            style: TextStyle(color: kPrimary, fontSize: 12,
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

          // Messages list
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: kPrimary))
                : _messages.isEmpty
                    ? const Center(
                        child: Text('אין הודעות עדיין — שלח הודעה ראשונה!',
                            style: TextStyle(color: kSubtext)))
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) {
                          final msg  = _messages[i];
                          final isMe = msg['from'] == widget.me?['id'];
                          return Column(
                            children: [
                              if (i == 0) const _DateDivider(label: 'היום'),
                              GestureDetector(
                                onLongPress: () =>
                                    setState(() => _replyTo = msg),
                                child: _MessageBubble(message: msg, isMe: isMe),
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
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
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
                      border: Border.all(color: const Color(0xFFC5DFF2),
                          width: 1.5),
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
                            style: const TextStyle(
                                fontSize: 13, color: kTextDark),
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
                GestureDetector(
                  onTap: _send,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: kPrimary,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: const Icon(Icons.send,
                        color: Colors.white, size: 20),
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
              decoration: const BoxDecoration(
                  color: kSubtext, shape: BoxShape.circle),
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
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
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

class _MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;

  const _MessageBubble({required this.message, required this.isMe});

  Widget _statusIcon() {
    if (!isMe) return const SizedBox.shrink();
    switch (message['status'] as String? ?? 'sent') {
      case 'read':
        return const Icon(Icons.done_all, size: 14, color: kReadTick);
      case 'received':
        return Icon(Icons.done_all, size: 14,
            color: Colors.white.withOpacity(0.6));
      default:
        return Icon(Icons.done, size: 14,
            color: Colors.white.withOpacity(0.6));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFile = message['isFile'] == true;
    final textColor = isMe ? Colors.white : kTextDark;
    final timeColor =
        isMe ? Colors.white.withOpacity(0.7) : kSubtext;
    final replyBg = isMe
        ? Colors.white.withOpacity(0.15)
        : Colors.black.withOpacity(0.05);
    final replyBorder =
        isMe ? Colors.white.withOpacity(0.5) : kPrimary;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        decoration: BoxDecoration(
          color: isMe ? kOutgoing : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft:
                isMe ? const Radius.circular(14) : const Radius.circular(3),
            bottomRight:
                isMe ? const Radius.circular(3) : const Radius.circular(14),
          ),
          border: isMe
              ? null
              : Border.all(color: kBorder, width: 1),
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

            if (isFile)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.insert_drive_file,
                      size: 18,
                      color: isMe ? Colors.white70 : kPrimary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      message['text'] as String,
                      style: TextStyle(fontSize: 14, color: textColor),
                      textDirection: TextDirection.rtl,
                    ),
                  ),
                ],
              )
            else
              Text(
                message['text'] as String,
                style: TextStyle(
                    fontSize: 14, height: 1.45, color: textColor),
                textDirection: TextDirection.rtl,
              ),

            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
  const GroupsScreen({super.key, required this.token, required this.me, required this.socket});
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
  }

  @override
  void dispose() {
    widget.socket?.off('group:message');
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('ביטול')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('צור')),
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
        body: jsonEncode({'name': nameCtrl.text.trim(), 'description': descCtrl.text.trim()}),
      );
      if (res.statusCode == 200 && mounted) {
        final group = jsonDecode(res.body) as Map<String, dynamic>;
        widget.socket?.emit('group:join', {'groupId': group['id']});
        setState(() => _groups.insert(0, group));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('קבוצות'),
        actions: [IconButton(icon: const Icon(Icons.search), onPressed: () {})],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createGroup,
        backgroundColor: kPrimary,
        child: const Icon(Icons.group_add, color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kPrimary))
          : _groups.isEmpty
              ? const Center(child: Text('אין קבוצות עדיין', style: TextStyle(color: kSubtext)))
              : ListView.separated(
                  itemCount: _groups.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
                  itemBuilder: (_, i) {
                    final g = _groups[i];
                    final isAdmin = g['role'] == 'admin';
                    final memberCount = g['member_count'] ?? 0;
                    final lastMsg = g['lastMsg'] as String? ?? g['description'] as String? ?? '';
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      leading: Stack(
                        children: [
                          CircleAvatar(
                            radius: 26,
                            backgroundColor: kPrimary,
                            child: const Icon(Icons.group, color: Colors.white, size: 26),
                          ),
                          if (isAdmin)
                            Positioned(
                              left: 0, bottom: 0,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: Colors.orange,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.star, size: 10, color: Colors.white),
                              ),
                            ),
                        ],
                      ),
                      title: Text(g['name'] as String,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        lastMsg.isNotEmpty ? lastMsg : '$memberCount חברים',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: kSubtext),
                      ),
                      trailing: const Icon(Icons.chevron_left, color: kSubtext),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => GroupChatScreen(
                            group: g,
                            me: widget.me,
                            token: widget.token,
                            socket: widget.socket,
                          ),
                        ),
                      ).then((_) => _loadGroups()),
                    );
                  },
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
  const GroupChatScreen({
    super.key,
    required this.group,
    required this.me,
    required this.token,
    required this.socket,
  });
  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final List<Map<String, dynamic>> _messages = [];
  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _loading   = true;
  bool _isAdmin   = false;
  bool _isTyping  = false;
  String _typingName = '';
  List<Map<String, dynamic>> _members = [];

  String get _groupId => widget.group['id'] as String;

  @override
  void initState() {
    super.initState();
    _isAdmin = widget.group['role'] == 'admin';
    _loadMessages();
    _setupSocket();
    if (_isAdmin) _loadMembers();
  }

  Future<void> _loadMembers() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/groups/$_groupId'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() => _members = (data['members'] as List).cast<Map<String, dynamic>>());
      }
    } catch (_) {}
  }

  Future<void> _addMember(String userId) async {
    try {
      final res = await http.post(
        Uri.parse('$kApi/groups/$_groupId/members'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'userId': userId}),
      );
      if (res.statusCode == 200 && mounted) {
        await _loadMembers();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('החבר נוסף לקבוצה')),
        );
      }
    } catch (_) {}
  }

  Future<void> _removeMember(String userId, String userName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('הסרת חבר'),
        content: Text('להסיר את $userName מהקבוצה?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('ביטול')),
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
    final myName = widget.me?['name'] as String? ?? 'חבר';
    final groupName = widget.group['name'] as String? ?? 'הקבוצה';
    final msg = Uri.encodeComponent(
      'שלום $contactName! $myName מזמין אותך להצטרף לקבוצה "$groupName" באפליקציית בתשובה.\n'
      'הורד את האפליקציה והצטרף אלינו!',
    );
    final uri = Uri.parse('sms:$phone?body=$msg');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _showAddMemberDialog() async {
    final granted = await FlutterContacts.requestPermission(readonly: true);
    if (!mounted) return;

    // registered: users found in app — { id, name, profile_pic_url, phone }
    List<Map<String, dynamic>> registered = [];
    // unregistered: contacts NOT in app — { name, phone }
    List<Map<String, dynamic>> unregistered = [];

    if (granted) {
      final contacts = await FlutterContacts.getContacts(withProperties: true);

      // Build map: normalizedPhone → {name, phone (original best number)}
      final Map<String, Map<String, String>> phoneToContact = {};
      for (final c in contacts) {
        for (final p in c.phones) {
          final norm = _normalizePhone(p.number);
          if (norm.length >= 9) {
            phoneToContact.putIfAbsent(norm, () => {
              'name': c.displayName,
              'phone': p.number,
            });
          }
        }
      }

      if (phoneToContact.isNotEmpty) {
        try {
          final res = await http.post(
            Uri.parse('$kApi/contacts/match'),
            headers: {
              'Authorization': 'Bearer ${widget.token}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'phones': phoneToContact.keys.toList()}),
          );
          if (res.statusCode == 200) {
            registered = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
          }
        } catch (_) {}
      }

      // Find unregistered: contacts whose normalized phones have no match
      final registeredPhones = registered
          .map((u) => _normalizePhone((u['phone'] as String? ?? '')))
          .toSet();
      unregistered = phoneToContact.entries
          .where((e) => !registeredPhones.contains(e.key))
          .map((e) => {'name': e.value['name']!, 'phone': e.value['phone']!})
          .toList()
        ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    } else {
      // No contacts permission — show all app users
      try {
        final res = await http.get(
          Uri.parse('$kApi/users'),
          headers: {'Authorization': 'Bearer ${widget.token}'},
        );
        if (res.statusCode == 200) {
          registered = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
        }
      } catch (_) {}
    }

    final memberIds = _members.map((m) => m['id'] as String).toSet();
    registered = registered.where((u) => !memberIds.contains(u['id'] as String)).toList();

    if (!mounted) return;
    final searchCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final query = searchCtrl.text.toLowerCase();
          final filteredReg = query.isEmpty
              ? registered
              : registered.where((u) =>
                  (u['name'] as String).toLowerCase().contains(query)).toList();
          final filteredUnreg = query.isEmpty
              ? unregistered
              : unregistered.where((u) =>
                  (u['name'] as String).toLowerCase().contains(query)).toList();

          return AlertDialog(
            title: const Text('הוסף מאנשי קשר'),
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
                      textDirection: TextDirection.rtl,
                      decoration: const InputDecoration(
                        hintText: 'חיפוש...',
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
                                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                                  child: Text('בתשובה',
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: kPrimary)),
                                ),
                                ...filteredReg.map((u) => ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: kPrimary,
                                    backgroundImage: u['profile_pic_url'] != null
                                        ? NetworkImage(u['profile_pic_url'] as String)
                                        : null,
                                    child: u['profile_pic_url'] == null
                                        ? Text((u['name'] as String)[0],
                                            style: const TextStyle(color: Colors.white))
                                        : null,
                                  ),
                                  title: Text(u['name'] as String),
                                  trailing: const Icon(Icons.person_add_outlined,
                                      color: kPrimary),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _addMember(u['id'] as String);
                                  },
                                )),
                              ],
                              // ── Unregistered contacts ─────────────
                              if (granted && filteredUnreg.isNotEmpty) ...[
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
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
                                        style: const TextStyle(color: Colors.white)),
                                  ),
                                  title: Text(c['name'] as String),
                                  subtitle: const Text('לא רשום בבתשובה',
                                      style: TextStyle(fontSize: 11)),
                                  trailing: TextButton.icon(
                                    icon: const Icon(Icons.sms_outlined, size: 16),
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
                        leading: CircleAvatar(
                          backgroundColor: kPrimary,
                          backgroundImage: m['profile_pic_url'] != null
                              ? NetworkImage(m['profile_pic_url'] as String)
                              : null,
                          child: m['profile_pic_url'] == null
                              ? Text((m['name'] as String)[0],
                                  style: const TextStyle(color: Colors.white))
                              : null,
                        ),
                        title: Text(m['name'] as String),
                        subtitle: isAdminMember
                            ? const Text('מנהל', style: TextStyle(color: kPrimary))
                            : null,
                        trailing: (!isMe && !isAdminMember)
                            ? IconButton(
                                icon: const Icon(Icons.person_remove, color: Colors.red),
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _removeMember(m['id'] as String, m['name'] as String);
                                },
                              )
                            : null,
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('סגור')),
          ],
        ),
      ),
    );
  }

  Future<void> _loadMessages() async {
    try {
      final res = await http.get(
        Uri.parse('$kApi/groups/$_groupId/messages'),
        headers: {'Authorization': 'Bearer ${widget.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        setState(() {
          _messages.clear();
          _messages.addAll(data.map(_normalize));
          _loading = false;
        });
        _scrollToBottom();
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
      'id':         map['id'],
      'text':       map['body'] ?? '',
      'senderName': map['sender_name'] ?? '',
      'time':       _formatTime(map['created_at']),
      'isMe':       isMe,
      if (map['reply_to_id'] != null) 'replyTo': {
        'id':   map['reply_to_id'],
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
      setState(() {
        _messages.add({
          'id':         data['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
          'text':       data['text'] as String? ?? '',
          'senderName': data['fromName'] as String? ?? '',
          'time':       data['createdAt'] != null ? _formatTime(data['createdAt']) : _nowTime(),
          'isMe':       data['fromUserId'] == widget.me?['id'],
          'isTyping':   false,
        });
        _isTyping = false;
      });
      _scrollToBottom();
    });

    widget.socket?.on('group:typing', (data) {
      if (data['groupId'] == _groupId && mounted) {
        setState(() { _isTyping = true; _typingName = data['fromName'] as String? ?? ''; });
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _isTyping = false);
        });
      }
    });
  }

  @override
  void dispose() {
    widget.socket?.off('group:message');
    widget.socket?.off('group:typing');
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  String _nowTime() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  void _send() {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add({
        'id':         'temp_${DateTime.now().millisecondsSinceEpoch}',
        'text':       text,
        'senderName': widget.me?['name'] as String? ?? '',
        'time':       _nowTime(),
        'isMe':       true,
      });
      _msgCtrl.clear();
    });
    widget.socket?.emit('group:message', {'groupId': _groupId, 'text': text});
    _scrollToBottom();
  }

  Future<void> _leaveGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('יציאה מקבוצה'),
        content: Text('האם לצאת מ"${widget.group['name']}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('ביטול')),
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
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_isAdmin) ...[
              ListTile(
                leading: const Icon(Icons.person_add_outlined, color: kPrimary),
                title: const Text('הוסף חבר'),
                onTap: () { Navigator.pop(context); _showAddMemberDialog(); },
              ),
              ListTile(
                leading: const Icon(Icons.group_outlined, color: kPrimary),
                title: const Text('ניהול חברים'),
                subtitle: Text('${_members.length} חברים'),
                onTap: () { Navigator.pop(context); _showMembersDialog(); },
              ),
              ListTile(
                leading: const Icon(Icons.tune, color: kPrimary),
                title: const Text('הגדרות שליחה'),
                subtitle: Text(widget.group['send_permission'] == 'admin'
                    ? 'מנהלים בלבד' : 'כולם יכולים לשלוח'),
                onTap: () => Navigator.pop(context),
              ),
              ListTile(
                leading: const Icon(Icons.campaign_outlined, color: Colors.orange),
                title: const Text('מצב ברודקסט'),
                subtitle: Text(widget.group['is_broadcast'] == true ? 'פעיל' : 'לא פעיל'),
                onTap: () => Navigator.pop(context),
              ),
              ListTile(
                leading: const Icon(Icons.shield_outlined, color: kPrimary),
                title: const Text('רמת סינון תוכן'),
                subtitle: Text(widget.group['filter_level'] == 'strict' ? 'מחמיר' : 'רגיל'),
                onTap: () => Navigator.pop(context),
              ),
              const Divider(),
            ],
            ListTile(
              leading: const Icon(Icons.exit_to_app, color: Colors.red),
              title: const Text('יציאה מקבוצה', style: TextStyle(color: Colors.red)),
              onTap: () { Navigator.pop(context); _leaveGroup(); },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kChatBg,
      appBar: AppBar(
        backgroundColor: kPrimary,
        leading: BackButton(
            color: Colors.white, onPressed: () => Navigator.pop(context)),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.group['name'] as String,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text('${widget.group['member_count'] ?? ''} חברים',
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: _showAdminPanel,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: kPrimary))
                : _messages.isEmpty
                    ? const Center(child: Text('אין הודעות עדיין', style: TextStyle(color: kSubtext)))
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.all(10),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) {
                          final msg  = _messages[i];
                          final isMe = msg['isMe'] == true;
                          return Column(
                            crossAxisAlignment: isMe
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              if (!isMe)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8, bottom: 2),
                                  child: Text(
                                    msg['senderName'] as String? ?? '',
                                    style: const TextStyle(
                                        fontSize: 12, color: kPrimary,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                constraints: BoxConstraints(
                                    maxWidth: MediaQuery.of(context).size.width * 0.75),
                                decoration: BoxDecoration(
                                  color: isMe ? kOutgoing : kCard,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 3,
                                  )],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      msg['text'] as String? ?? '',
                                      style: const TextStyle(fontSize: 15, height: 1.4),
                                      textDirection: TextDirection.rtl,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(msg['time'] as String? ?? '',
                                        style: const TextStyle(fontSize: 11, color: kSubtext)),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
          ),
          if (_isTyping)
            Container(
              width: double.infinity,
              color: kBg,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text('$_typingName מקליד...',
                  style: const TextStyle(fontSize: 12, color: kSubtext,
                      fontStyle: FontStyle.italic),
                  textDirection: TextDirection.rtl),
            ),
          Container(
            color: kCard,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file, color: kSubtext),
                  onPressed: () {},
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
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: _send,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: kPrimary,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: const Icon(Icons.send, color: Colors.white, size: 20),
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

// ── Settings Screen ───────────────────────────────────────────────
class SettingsScreen extends StatefulWidget {
  final Map<String, dynamic>? me;
  final String token;
  final VoidCallback onLogout;
  const SettingsScreen({super.key, required this.me, required this.token, required this.onLogout});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _strictFilter   = false;
  bool _hidePicture    = false;
  bool _notifications  = true;
  bool _readReceipts   = true;

  @override
  Widget build(BuildContext context) {
    final name = widget.me?['name'] as String? ?? 'משתמש';
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('הגדרות')),
      body: ListView(
        children: [
          // Profile header
          InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => ProfileScreen(me: widget.me, token: widget.token)),
            ),
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
                  onTap: () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => BlockedUsersScreen(token: widget.token))),
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
          const SizedBox(height: 16),

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
  final _nameCtrl      = TextEditingController();
  final _cityCtrl      = TextEditingController();
  final _communityCtrl = TextEditingController();
  String  _privacyPic  = 'all';
  String? _picUrl;
  bool    _loading     = true;
  bool    _saving      = false;
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
          _nameCtrl.text      = data['name']      as String? ?? '';
          _cityCtrl.text      = data['city']      as String? ?? '';
          _communityCtrl.text = data['community'] as String? ?? '';
          _privacyPic         = data['privacy_pic'] as String? ?? 'all';
          _picUrl             = data['profile_pic_url'] as String?;
          _loading            = false;
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
    setState(() { _saving = true; _error = null; });
    try {
      final res = await http.put(
        Uri.parse('$kApi/profile'),
        headers: {
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type':  'application/json',
        },
        body: jsonEncode({
          'name':            _nameCtrl.text.trim(),
          'city':            _cityCtrl.text.trim(),
          'community':       _communityCtrl.text.trim(),
          'privacy_pic':     _privacyPic,
          'profile_pic_url': _picUrl,
        }),
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        Navigator.pop(context, true);
      } else {
        final data = jsonDecode(res.body);
        setState(() { _error = data['error'] ?? 'שגיאה'; _saving = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _error = 'שגיאת חיבור'; _saving = false; });
    }
  }

  Future<void> _changePhoto() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 80);
    if (picked == null || !mounted) return;

    setState(() => _saving = true);
    try {
      final request = http.MultipartRequest('POST', Uri.parse('$kApi/upload'))
        ..headers['Authorization'] = 'Bearer ${widget.token}'
        ..files.add(await http.MultipartFile.fromPath('file', picked.path,
            filename: picked.name));
      final streamed = await request.send();
      final body     = await streamed.stream.bytesToString();
      if (!mounted) return;
      if (streamed.statusCode == 200) {
        final url = (jsonDecode(body) as Map)['url'] as String;
        setState(() { _picUrl = url; _saving = false; });
      } else {
        setState(() { _error = 'שגיאה בהעלאת תמונה'; _saving = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _error = 'שגיאת העלאה'; _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('עריכת פרופיל'),
        leading: BackButton(color: Colors.white, onPressed: () => Navigator.pop(context)),
        actions: [
          if (!_loading)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('שמור', style: TextStyle(color: Colors.white, fontSize: 16)),
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
                        CircleAvatar(
                          radius: 52,
                          backgroundColor: kPrimaryMid,
                          backgroundImage: _picUrl != null ? NetworkImage(_picUrl!) : null,
                          child: _picUrl == null
                              ? Text(
                                  _nameCtrl.text.isNotEmpty ? _nameCtrl.text[0].toUpperCase() : '?',
                                  style: const TextStyle(color: Colors.white, fontSize: 38,
                                      fontWeight: FontWeight.bold))
                              : null,
                        ),
                        Positioned(
                          bottom: 0, left: 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                                color: kPrimary, borderRadius: BorderRadius.circular(20)),
                            child: const Icon(Icons.camera_alt, color: Colors.white, size: 18),
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
                    decoration: BoxDecoration(color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                  ),
                  const SizedBox(height: 12),
                ],

                _FieldLabel(label: 'שם מלא'),
                const SizedBox(height: 6),
                TextField(
                  controller: _nameCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(hintText: 'השם שלך'),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),

                _FieldLabel(label: 'עיר'),
                const SizedBox(height: 6),
                TextField(
                  controller: _cityCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(hintText: 'עיר מגורים'),
                ),
                const SizedBox(height: 16),

                _FieldLabel(label: 'קהילה'),
                const SizedBox(height: 6),
                TextField(
                  controller: _communityCtrl,
                  textDirection: TextDirection.rtl,
                  decoration: const InputDecoration(hintText: 'קהילה / כולל'),
                ),
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
                        DropdownMenuItem(value: 'all',      child: Text('כולם')),
                        DropdownMenuItem(value: 'contacts', child: Text('אנשי קשר בלבד')),
                        DropdownMenuItem(value: 'nobody',   child: Text('אף אחד')),
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
          _blocked = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
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
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('ביטול')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true),
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
                      Icon(Icons.check_circle_outline, size: 64, color: kAccent),
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
                    final u    = _blocked[i];
                    final name = u['name'] as String? ?? '';
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: kPrimaryMid,
                        child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
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
