import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

const kServer = 'https://xo-app-betshuva.azurewebsites.net';
const kApi = '$kServer/api';

void main() => runApp(const XOApp());

class XOApp extends StatelessWidget {
  const XOApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'איקס אפס',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

// ── Auth Gate ────────────────────────────────────────────────────
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (!mounted) return;
    if (token != null) {
      Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => LobbyScreen(token: token)));
    } else {
      Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => const AuthScreen()));
    }
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

// ── Auth Screen ──────────────────────────────────────────────────
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit(bool isRegister) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final body = isRegister
          ? {
              'name': _nameCtrl.text,
              'email': _emailCtrl.text,
              'password': _passCtrl.text
            }
          : {'email': _emailCtrl.text, 'password': _passCtrl.text};

      final res = await http.post(
        Uri.parse('$kApi/${isRegister ? 'register' : 'login'}'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        setState(() {
          _error = data['error'];
          _loading = false;
        });
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', data['token']);

      if (!mounted) return;
      Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => LobbyScreen(token: data['token'])));
    } catch (e) {
      setState(() {
        _error = 'שגיאת חיבור לשרת';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('✕  ○', style: TextStyle(fontSize: 72)),
              const SizedBox(height: 8),
              const Text('איקס אפס',
                  style:
                      TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 32),
              TabBar(
                controller: _tabs,
                tabs: const [
                  Tab(text: 'התחברות'),
                  Tab(text: 'הרשמה'),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                height: 300,
                child: TabBarView(
                  controller: _tabs,
                  children: [_buildForm(false), _buildForm(true)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForm(bool isRegister) {
    return Column(
      children: [
        if (isRegister) ...[
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
                labelText: 'שם', border: OutlineInputBorder()),
            textDirection: TextDirection.rtl,
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _emailCtrl,
          decoration: const InputDecoration(
              labelText: 'אימייל', border: OutlineInputBorder()),
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passCtrl,
          decoration: const InputDecoration(
              labelText: 'סיסמה', border: OutlineInputBorder()),
          obscureText: true,
        ),
        const SizedBox(height: 16),
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 8),
        ],
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _loading ? null : () => _submit(isRegister),
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(isRegister ? 'הרשמה' : 'התחברות'),
          ),
        ),
      ],
    );
  }
}

// ── Lobby Screen ─────────────────────────────────────────────────
class LobbyScreen extends StatefulWidget {
  final String token;
  const LobbyScreen({super.key, required this.token});
  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  IO.Socket? _socket;
  List<Map<String, dynamic>> _users = [];
  Set<dynamic> _online = {};
  Map<String, dynamic>? _me;

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
      setState(() => _me = payload);
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
            .build());

    _socket!.on('users:online', (data) {
      setState(() => _online = Set.from(data as List));
    });

    _socket!.on('game:invite', (data) {
      _showInviteDialog(data['from'] as Map<String, dynamic>);
    });

    _socket!.on('game:accepted', (data) {
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => GameScreen(
                    token: widget.token,
                    socket: _socket!,
                    me: _me!,
                    opponent: data['by'] as Map<String, dynamic>,
                    iAmX: true,
                  )));
    });

    _socket!.on('game:declined', (_) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ההזמנה נדחתה')));
    });

    _socket!.on('game:cancel', (_) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ההזמנה בוטלה')));
    });
  }

  void _showInviteDialog(Map<String, dynamic> from) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('הזמנה למשחק!'),
        content: Text('${from['name']} מזמין אותך למשחק'),
        actions: [
          TextButton(
            onPressed: () {
              _socket!.emit('game:decline', {'toUserId': from['id']});
              Navigator.pop(context);
            },
            child: const Text('דחה'),
          ),
          ElevatedButton(
            onPressed: () {
              _socket!.emit('game:accept', {'toUserId': from['id']});
              Navigator.pop(context);
              Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => GameScreen(
                            token: widget.token,
                            socket: _socket!,
                            me: _me!,
                            opponent: from,
                            iAmX: false,
                          )));
            },
            child: const Text('קבל'),
          ),
        ],
      ),
    );
  }

  void _sendInvite(Map<String, dynamic> user) {
    _socket!.emit('game:invite', {'toUserId': user['id']});
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('הזמנה נשלחה ל-${user['name']}')));
  }

  Future<void> _logout() async {
    _socket?.disconnect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    if (!mounted) return;
    Navigator.pushReplacement(context,
        MaterialPageRoute(builder: (_) => const AuthScreen()));
  }

  @override
  void dispose() {
    _socket?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('שלום, ${_me?['name'] ?? ''}'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadUsers),
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout),
        ],
      ),
      body: _users.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadUsers,
              child: ListView.builder(
                itemCount: _users.length,
                itemBuilder: (_, i) {
                  final user = _users[i];
                  final isMe = user['id'] == _me?['id'];
                  final isOnline = _online.contains(user['id']);
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          isOnline ? Colors.green : Colors.grey.shade400,
                      child: Text(
                        (user['name'] as String)[0].toUpperCase(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    title: Text(user['name'],
                        style: TextStyle(
                            fontWeight: isOnline
                                ? FontWeight.bold
                                : FontWeight.normal)),
                    subtitle: Text(
                        'ניצחונות: ${user['wins']}  |  משחקים: ${user['games_played']}'),
                    trailing: (!isMe && isOnline)
                        ? ElevatedButton(
                            onPressed: () => _sendInvite(user),
                            child: const Text('הזמן'),
                          )
                        : isMe
                            ? const Chip(label: Text('אתה'))
                            : null,
                  );
                },
              ),
            ),
    );
  }
}

// ── Game Screen ──────────────────────────────────────────────────
class GameScreen extends StatefulWidget {
  final String token;
  final IO.Socket socket;
  final Map<String, dynamic> me;
  final Map<String, dynamic> opponent;
  final bool iAmX;

  const GameScreen({
    super.key,
    required this.token,
    required this.socket,
    required this.me,
    required this.opponent,
    required this.iAmX,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  List<String?> _board = List.filled(9, null);
  bool _myTurn = false;
  bool _gameOver = false;
  String? _statusMsg;
  int _myScore = 0;
  int _oppScore = 0;
  final List<Map<String, String>> _chat = [];
  final _chatCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  static const _winLines = [
    [0, 1, 2], [3, 4, 5], [6, 7, 8],
    [0, 3, 6], [1, 4, 7], [2, 5, 8],
    [0, 4, 8], [2, 4, 6],
  ];

  @override
  void initState() {
    super.initState();
    _myTurn = widget.iAmX;

    widget.socket.on('game:move', (data) {
      final idx = data['index'] as int;
      setState(() {
        _board[idx] = widget.iAmX ? 'O' : 'X';
        _myTurn = true;
      });
      _checkEnd();
    });

    widget.socket.on('chat:message', (data) {
      setState(() => _chat.add({
            'from': data['from'] as String,
            'text': data['text'] as String,
          }));
      _scrollToBottom();
    });

    widget.socket.on('game:rematch', (_) => _resetBoard());
  }

  @override
  void dispose() {
    widget.socket.off('game:move');
    widget.socket.off('chat:message');
    widget.socket.off('game:rematch');
    _chatCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _tap(int idx) {
    if (!_myTurn || _board[idx] != null || _gameOver) return;
    final mark = widget.iAmX ? 'X' : 'O';
    setState(() {
      _board[idx] = mark;
      _myTurn = false;
    });
    widget.socket
        .emit('game:move', {'toUserId': widget.opponent['id'], 'index': idx});
    _checkEnd();
  }

  void _checkEnd() {
    final myMark = widget.iAmX ? 'X' : 'O';
    final oppMark = widget.iAmX ? 'O' : 'X';

    for (final line in _winLines) {
      final vals = line.map((i) => _board[i]).toList();
      if (vals.every((v) => v == myMark)) {
        setState(() {
          _statusMsg = 'ניצחת! 🎉';
          _myScore++;
          _gameOver = true;
        });
        _saveGame('win', widget.me['id']);
        return;
      }
      if (vals.every((v) => v == oppMark)) {
        setState(() {
          _statusMsg = '${widget.opponent['name']} ניצח';
          _oppScore++;
          _gameOver = true;
        });
        _saveGame('win', widget.opponent['id']);
        return;
      }
    }

    if (_board.every((c) => c != null)) {
      setState(() {
        _statusMsg = 'תיקו!';
        _gameOver = true;
      });
      _saveGame('tie', null);
    }
  }

  Future<void> _saveGame(String result, dynamic winnerId) async {
    try {
      await http.post(
        Uri.parse('$kApi/games'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.token}',
        },
        body: jsonEncode({
          'player1_id': widget.me['id'],
          'player2_id': widget.opponent['id'],
          'winner_id': winnerId,
          'result': result,
          'board': _board.map((c) => c ?? '').toList(),
        }),
      );
    } catch (_) {}
  }

  void _resetBoard() {
    setState(() {
      _board = List.filled(9, null);
      _gameOver = false;
      _statusMsg = null;
      _myTurn = widget.iAmX;
    });
  }

  void _rematch() {
    widget.socket.emit('game:rematch', {'toUserId': widget.opponent['id']});
    _resetBoard();
  }

  void _sendChat() {
    final text = _chatCtrl.text.trim();
    if (text.isEmpty) return;
    widget.socket
        .emit('chat:message', {'toUserId': widget.opponent['id'], 'text': text});
    setState(() => _chat
        .add({'from': widget.me['name'] as String, 'text': text}));
    _chatCtrl.clear();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final myMark = widget.iAmX ? 'X' : 'O';
    final oppMark = widget.iAmX ? 'O' : 'X';

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.me['name']}  vs  ${widget.opponent['name']}'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Score bar
          Container(
            padding:
                const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            color: Colors.deepPurple.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _scoreCard(widget.me['name'] as String, myMark,
                    _myScore, Colors.blue),
                Column(
                  children: [
                    Text(
                      _gameOver
                          ? (_statusMsg ?? '')
                          : _myTurn
                              ? 'התור שלך'
                              : 'ממתין...',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: _gameOver ? Colors.deepPurple : Colors.black),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
                _scoreCard(widget.opponent['name'] as String, oppMark,
                    _oppScore, Colors.red),
              ],
            ),
          ),

          // Board
          Padding(
            padding: const EdgeInsets.all(16),
            child: AspectRatio(
              aspectRatio: 1,
              child: GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: 9,
                itemBuilder: (_, i) {
                  final cell = _board[i];
                  return GestureDetector(
                    onTap: () => _tap(i),
                    child: Container(
                      decoration: BoxDecoration(
                        color: cell == null
                            ? Colors.deepPurple.shade50
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: Colors.deepPurple.shade200, width: 2),
                      ),
                      child: Center(
                        child: Text(
                          cell ?? '',
                          style: TextStyle(
                            fontSize: 52,
                            fontWeight: FontWeight.bold,
                            color:
                                cell == 'X' ? Colors.blue : Colors.red,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // Game over buttons
          if (_gameOver)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: _rematch,
                    icon: const Icon(Icons.replay),
                    label: const Text('משחק חדש'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('חזור ללובי'),
                  ),
                ],
              ),
            ),

          // Chat
          const Divider(height: 8),
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _chat.length,
              itemBuilder: (_, i) {
                final msg = _chat[i];
                final isMe = msg['from'] == widget.me['name'];
                return Align(
                  alignment:
                      isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isMe
                          ? Colors.deepPurple.shade100
                          : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(msg['text']!),
                  ),
                );
              },
            ),
          ),

          // Chat input
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatCtrl,
                    decoration: const InputDecoration(
                      hintText: 'הודעה...',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                    onSubmitted: (_) => _sendChat(),
                    textDirection: TextDirection.rtl,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.deepPurple),
                  onPressed: _sendChat,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _scoreCard(String name, String mark, int score, Color color) {
    return Column(
      children: [
        Text(name,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        Text('($mark)', style: TextStyle(color: color, fontSize: 12)),
        Text('$score',
            style: TextStyle(
                fontSize: 32, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }
}
