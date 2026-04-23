import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

// ── Color Palette ─────────────────────────────────────────────────
const kPrimary    = Color(0xFF1B4332);
const kPrimaryMid = Color(0xFF2D6A4F);
const kAccent     = Color(0xFF52B788);
const kBg         = Color(0xFFF0F4F0);
const kCard       = Color(0xFFFFFFFF);
const kBorder     = Color(0xFFD8E4D8);
const kSubtext    = Color(0xFF6C757D);
const kReadGreen  = Color(0xFF25D366);
const kOutgoing   = Color(0xFFD8F5E4);
const kChatBg     = Color(0xFFECF3E8);

const kServer  = 'https://xo-app-betshuva.azurewebsites.net';
const kApi     = '$kServer/api';
const kVersion = '1.0.1';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const BetshuvApp());
}

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
          backgroundColor: kPrimary,
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
        barrierDismissible: false,
        builder: (_) => AlertDialog(
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
              onPressed: () => Navigator.pop(context),
              child: const Text('אחר כך', style: TextStyle(color: kSubtext)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                final uri = Uri.parse(apkUrl);
                await http.get(uri); // trigger download via browser
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
              Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 60,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'בתשובה',
                style: TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 3,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'מסרים לקהילה החרדית',
                style: TextStyle(
                  fontSize: 16,
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
  final _otpCtrl   = TextEditingController();
  bool    _otpSent  = false;
  bool    _loading  = false;
  String? _error;

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _nameCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final phone = _phoneCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (phone.length < 9) { setState(() => _error = 'נא להזין מספר טלפון תקין'); return; }
    if (_nameCtrl.text.trim().isEmpty) { setState(() => _error = 'נא להזין שם מלא'); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final res = await http.post(
        Uri.parse('$kApi/send-otp'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'phone': phone, 'name': _nameCtrl.text.trim()}),
      );
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
      );
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
  String? _success;

  final _nameCtrl  = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email    = _emailCtrl.text.trim();
    final password = _passCtrl.text;
    final name     = _nameCtrl.text.trim();
    if (!_isLogin && name.isEmpty) { setState(() => _error = 'נא להזין שם מלא'); return; }
    if (email.isEmpty || !email.contains('@')) { setState(() => _error = 'נא להזין כתובת אימייל תקינה'); return; }
    if (password.length < 6) { setState(() => _error = 'הסיסמה חייבת להיות לפחות 6 תווים'); return; }
    setState(() { _loading = true; _error = null; _success = null; });
    try {
      final endpoint = _isLogin ? '/login' : '/register';
      final body     = _isLogin
          ? {'email': email, 'password': password}
          : {'name': name, 'email': email, 'password': password};
      final res  = await http.post(
        Uri.parse('$kApi$endpoint'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        setState(() { _error = data['error'] ?? 'שגיאה לא ידועה'; _loading = false; });
        return;
      }
      final token = data['token'] as String;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', token);
      if (!_isLogin) {
        setState(() { _success = 'נרשמת בהצלחה! נשלח אליך מייל אישור.'; _loading = false; });
        await Future.delayed(const Duration(milliseconds: 800));
      }
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
              if (_success != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50, borderRadius: BorderRadius.circular(8)),
                  child: Text(_success!,
                      style: TextStyle(color: Colors.green.shade700, fontSize: 13)),
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
        final data  = jsonDecode(res.body) as List;
        final myId  = _me?['id'];
        setState(() => _users = data
            .cast<Map<String, dynamic>>()
            .where((u) => u['id'] != myId)
            .toList());
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
      GroupsScreen(token: widget.token, me: _me),
      SettingsScreen(me: _me, onLogout: _logout),
    ];

    return Scaffold(
      body: screens[_idx],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _idx,
        onTap: (i) => setState(() => _idx = i),
        selectedItemColor: kPrimary,
        unselectedItemColor: kSubtext,
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
class ConversationsScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('שיחות'),
        actions: [
          IconButton(icon: const Icon(Icons.search), onPressed: () {}),
        ],
      ),
      body: users.isEmpty
          ? const Center(
              child: CircularProgressIndicator(color: kPrimary),
            )
          : ListView.separated(
              itemCount: users.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, indent: 76, endIndent: 0),
              itemBuilder: (_, i) {
                final user = users[i];
                return _ConversationTile(
                  user: user,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatScreen(
                        token: token,
                        me: me,
                        recipient: user,
                        socket: socket,
                      ),
                    ),
                  ),
                );
              },
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
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: CircleAvatar(
        radius: 26,
        backgroundColor: kPrimaryMid,
        child: Text(
          initials,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
      title: Text(
        name,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
      subtitle: const Text(
        'לחץ לפתיחת שיחה',
        style: TextStyle(fontSize: 13, color: kSubtext),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_left, color: kSubtext),
      onTap: onTap,
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

  @override
  void initState() {
    super.initState();
    _messages.addAll([
      {
        'id': '1',
        'text': 'שלום! מה שלומך?',
        'from': widget.recipient['id'],
        'time': '10:30',
        'status': 'read',
      },
      {
        'id': '2',
        'text': 'ברוך השם, הכל טוב. ואתה?',
        'from': widget.me?['id'],
        'time': '10:31',
        'status': 'read',
      },
      {
        'id': '3',
        'text': 'ב"ה הכל בסדר. האם תוכל לבוא לשיעור היום בשעה 8?',
        'from': widget.recipient['id'],
        'time': '10:33',
        'status': 'read',
      },
    ]);
    widget.socket?.on('chat:message', (data) {
      if (data['fromUserId'] == widget.recipient['id']) {
        setState(() {
          _messages.add({
            'id': DateTime.now().millisecondsSinceEpoch.toString(),
            'text': data['text'] as String,
            'from': widget.recipient['id'],
            'time': _nowTime(),
            'status': 'received',
          });
        });
        _scrollToBottom();
      }
    });
  }

  @override
  void dispose() {
    widget.socket?.off('chat:message');
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
    setState(() {
      _messages.add({
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'text': text,
        'from': widget.me?['id'],
        'time': _nowTime(),
        'status': 'sent',
        if (_replyTo != null) 'replyTo': Map<String, dynamic>.from(_replyTo!),
      });
      _replyTo = null;
    });
    widget.socket?.emit('chat:message', {
      'toUserId': widget.recipient['id'],
      'text': text,
    });
    _msgCtrl.clear();
    _scrollToBottom();
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
            const Text(
              'שיתוף קובץ',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _AttachOption(
                  icon: Icons.image_outlined,
                  label: 'תמונה',
                  color: kPrimary,
                  onTap: () {
                    Navigator.pop(context);
                    _fakeScan('תמונה');
                  },
                ),
                _AttachOption(
                  icon: Icons.camera_alt_outlined,
                  label: 'מצלמה',
                  color: kPrimaryMid,
                  onTap: () {
                    Navigator.pop(context);
                    _fakeScan('צילום');
                  },
                ),
                _AttachOption(
                  icon: Icons.picture_as_pdf_outlined,
                  label: 'מסמך',
                  color: Colors.orange,
                  onTap: () {
                    Navigator.pop(context);
                    _fakeScan('מסמך');
                  },
                ),
                _AttachOption(
                  icon: Icons.mic_outlined,
                  label: 'הקלטה',
                  color: Colors.deepPurple,
                  onTap: () => Navigator.pop(context),
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
              child: Row(
                children: [
                  Icon(Icons.block, color: Colors.red.shade600, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'שליחת סרטוני וידאו וקישורי YouTube אינה נתמכת',
                      style: TextStyle(fontSize: 12, color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _fakeScan(String type) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Row(
          children: const [
            Icon(Icons.security, color: kPrimary),
            SizedBox(width: 8),
            Text('סריקת צניעות'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: kPrimary),
            const SizedBox(height: 16),
            Text('$type עובר סריקה אוטומטית...\nמקסימום 3 שניות'),
          ],
        ),
      ),
    );
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      Navigator.pop(context);
      setState(() {
        _messages.add({
          'id': DateTime.now().millisecondsSinceEpoch.toString(),
          'text': '[$type נשלח ✓]',
          'from': widget.me?['id'],
          'time': _nowTime(),
          'status': 'sent',
          'isFile': true,
        });
      });
      _scrollToBottom();
    });
  }

  @override
  Widget build(BuildContext context) {
    final recipientName = widget.recipient['name'] as String? ?? '';
    return Scaffold(
      backgroundColor: kChatBg,
      appBar: AppBar(
        backgroundColor: kPrimary,
        leading: BackButton(color: Colors.white, onPressed: () => Navigator.pop(context)),
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: kAccent,
              child: Text(
                recipientName.isNotEmpty ? recipientName[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              recipientName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
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

          // Messages list
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (_, i) {
                final msg  = _messages[i];
                final isMe = msg['from'] == widget.me?['id'];
                return Column(
                  children: [
                    if (i == 0) const _DateDivider(label: 'היום'),
                    GestureDetector(
                      onLongPress: () => setState(() => _replyTo = msg),
                      child: _MessageBubble(message: msg, isMe: isMe),
                    ),
                  ],
                );
              },
            ),
          ),

          // Input bar
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
                    maxLines: 4,
                    minLines: 1,
                    decoration: InputDecoration(
                      hintText: 'הודעה...',
                      hintTextDirection: TextDirection.rtl,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: kBg,
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.emoji_emotions_outlined,
                            color: kSubtext),
                        onPressed: () {},
                      ),
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

class _DateDivider extends StatelessWidget {
  final String label;
  const _DateDivider({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: kBorder,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(label,
                  style: const TextStyle(fontSize: 12, color: kSubtext)),
            ),
          ),
          const Expanded(child: Divider()),
        ],
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
        return const Icon(Icons.done_all, size: 14, color: kReadGreen);
      case 'received':
        return const Icon(Icons.done_all, size: 14, color: kSubtext);
      default:
        return const Icon(Icons.done, size: 14, color: kSubtext);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isFile = message['isFile'] == true;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMe ? kOutgoing : kCard,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft:
                isMe ? const Radius.circular(16) : const Radius.circular(4),
            bottomRight:
                isMe ? const Radius.circular(4) : const Radius.circular(16),
          ),
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
            // Quote/reply preview
            if (message['replyTo'] != null)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(8),
                  border: const Border(
                    right: BorderSide(color: kPrimary, width: 3),
                  ),
                ),
                child: Text(
                  (message['replyTo'] as Map)['text'] as String,
                  style: const TextStyle(fontSize: 12, color: kSubtext),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textDirection: TextDirection.rtl,
                ),
              ),

            // Text or file
            if (isFile)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.insert_drive_file, size: 18, color: kPrimary),
                  const SizedBox(width: 6),
                  Text(
                    message['text'] as String,
                    style: const TextStyle(fontSize: 15),
                    textDirection: TextDirection.rtl,
                  ),
                ],
              )
            else
              Text(
                message['text'] as String,
                style: const TextStyle(fontSize: 15, height: 1.4),
                textDirection: TextDirection.rtl,
              ),

            // Time + status
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message['time'] as String? ?? '',
                  style: const TextStyle(fontSize: 11, color: kSubtext),
                ),
                const SizedBox(width: 4),
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
  const GroupsScreen({super.key, required this.token, required this.me});
  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  final List<Map<String, dynamic>> _groups = [
    {
      'id': '1',
      'name': 'שיעור יומי',
      'desc': 'שיעור תורה יומי',
      'members': 24,
      'isAdmin': true,
      'lastMsg': 'השיעור מחר בשעה 8:00',
      'time': 'אתמול',
      'unread': 3,
    },
    {
      'id': '2',
      'name': 'חברי הקהילה',
      'desc': 'קהילת בתשובה',
      'members': 87,
      'isAdmin': false,
      'lastMsg': 'ברכות לכולם!',
      'time': '10:15',
      'unread': 0,
    },
    {
      'id': '3',
      'name': 'הורים וילדים',
      'desc': 'עדכונים מבית הספר',
      'members': 42,
      'isAdmin': false,
      'lastMsg': 'אין לימודים מחר',
      'time': '09:30',
      'unread': 1,
    },
  ];

  void _createGroup() {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    showDialog(
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
              decoration: const InputDecoration(labelText: 'תיאור'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ביטול'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameCtrl.text.isNotEmpty) {
                setState(() {
                  _groups.insert(0, {
                    'id': DateTime.now().toString(),
                    'name': nameCtrl.text,
                    'desc': descCtrl.text,
                    'members': 1,
                    'isAdmin': true,
                    'lastMsg': 'קבוצה חדשה נוצרה',
                    'time': 'עכשיו',
                    'unread': 0,
                  });
                });
                Navigator.pop(context);
              }
            },
            child: const Text('צור'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        title: const Text('קבוצות'),
        actions: [
          IconButton(icon: const Icon(Icons.search), onPressed: () {}),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createGroup,
        backgroundColor: kPrimary,
        child: const Icon(Icons.group_add, color: Colors.white),
      ),
      body: ListView.separated(
        itemCount: _groups.length,
        separatorBuilder: (_, __) =>
            const Divider(height: 1, indent: 76, endIndent: 0),
        itemBuilder: (_, i) {
          final g = _groups[i];
          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: Stack(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: kPrimary,
                  child: const Icon(Icons.group, color: Colors.white, size: 26),
                ),
                if (g['isAdmin'] == true)
                  Positioned(
                    left: 0,
                    bottom: 0,
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
            title: Text(
              g['name'] as String,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              g['lastMsg'] as String,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: kSubtext),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(g['time'] as String,
                    style: const TextStyle(fontSize: 11, color: kSubtext)),
                if ((g['unread'] as int) > 0)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: kPrimary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${g['unread']}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    GroupChatScreen(group: g, me: widget.me),
              ),
            ),
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
  const GroupChatScreen({super.key, required this.group, required this.me});
  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final List<Map<String, dynamic>> _messages = [];
  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();
  late bool _isAdmin;

  @override
  void initState() {
    super.initState();
    _isAdmin = widget.group['isAdmin'] == true;
    _messages.addAll([
      {
        'id': '1',
        'text': 'ברוכים הבאים לקבוצה!',
        'from': 'מנהל',
        'time': '09:00',
        'isMe': false,
      },
      {
        'id': '2',
        'text': widget.group['lastMsg'] as String,
        'from': 'יעקב לוי',
        'time': '10:15',
        'isMe': false,
      },
    ]);
  }

  @override
  void dispose() {
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
    setState(() {
      _messages.add({
        'id': DateTime.now().toString(),
        'text': text,
        'from': widget.me?['name'] as String? ?? 'אני',
        'time': _nowTime(),
        'isMe': true,
      });
    });
    _msgCtrl.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  void _showAdminPanel() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ניהול: ${widget.group['name']}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.person_add_outlined, color: kPrimary),
              title: const Text('הוסף חבר'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.tune, color: kPrimary),
              title: const Text('הגדרות שליחה'),
              subtitle: const Text('כולם / מנהלים בלבד'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.campaign_outlined, color: Colors.orange),
              title: const Text('מצב ברודקסט'),
              subtitle: const Text('שליחה חד-כיוונית'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.shield_outlined, color: kPrimary),
              title: const Text('רמת סינון תוכן'),
              subtitle: const Text('Standard / Strict'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.people_outline, color: kPrimary),
              title: const Text('רשימת חברים'),
              subtitle:
                  Text('${widget.group['members']} חברים'),
              onTap: () => Navigator.pop(context),
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
            Text(
              widget.group['name'] as String,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              '${widget.group['members']} חברים',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          if (_isAdmin)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              onPressed: _showAdminPanel,
            ),
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
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
                          msg['from'] as String,
                          style: const TextStyle(
                              fontSize: 12,
                              color: kPrimary,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.75,
                      ),
                      decoration: BoxDecoration(
                        color: isMe ? kOutgoing : kCard,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 3,
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            msg['text'] as String,
                            style: const TextStyle(fontSize: 15, height: 1.4),
                            textDirection: TextDirection.rtl,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            msg['time'] as String,
                            style:
                                const TextStyle(fontSize: 11, color: kSubtext),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
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
  final VoidCallback onLogout;
  const SettingsScreen({super.key, required this.me, required this.onLogout});
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
                  builder: (_) => ProfileScreen(me: widget.me)),
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
                  onTap: () {},
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
  const ProfileScreen({super.key, required this.me});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late TextEditingController _nameCtrl;
  late TextEditingController _cityCtrl;
  late TextEditingController _communityCtrl;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl      = TextEditingController(text: widget.me?['name'] as String? ?? '');
    _cityCtrl      = TextEditingController();
    _communityCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cityCtrl.dispose();
    _communityCtrl.dispose();
    super.dispose();
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
          TextButton(
            onPressed: () {
              setState(() => _saved = true);
              Future.delayed(
                  const Duration(seconds: 1), () => Navigator.pop(context));
            },
            child: const Text('שמור',
                style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Avatar
          Center(
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 52,
                  backgroundColor: kPrimaryMid,
                  child: Text(
                    _nameCtrl.text.isNotEmpty
                        ? _nameCtrl.text[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 38,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: kPrimary,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Icon(Icons.camera_alt,
                        color: Colors.white, size: 18),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'תמונת פרופיל תעבור סריקת צניעות',
              style: TextStyle(fontSize: 12, color: kSubtext),
            ),
          ),
          const SizedBox(height: 28),

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

          if (_saved)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Row(
                children: const [
                  Icon(Icons.check_circle, color: kAccent),
                  SizedBox(width: 8),
                  Text('הפרטים נשמרו',
                      style: TextStyle(color: kAccent, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
        ],
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
