import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const messageReactionEmoji = ['👍', '❤️', '😂', '🙏', '😮', '😢'];

class MessageReactions extends StatefulWidget {
  final String api, token, messageId;
  final http.Client? client;
  const MessageReactions(
      {super.key,
      required this.api,
      required this.token,
      required this.messageId,
      this.client});
  @override
  State<MessageReactions> createState() => _MessageReactionsState();
}

class _MessageReactionsState extends State<MessageReactions> {
  late final http.Client _client = widget.client ?? http.Client();
  List<Map<String, dynamic>> _items = [];
  Timer? _timer;
  bool _busy = false;
  bool _loading = false;
  int _revision = 0;
  Uri get _url =>
      Uri.parse('${widget.api}/messages/${widget.messageId}/reactions');
  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${widget.token}',
        'Content-Type': 'application/json'
      };
  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _load();
      }
    });
  }

  Future<void> _load() async {
    if (_loading || _busy) return;
    _loading = true;
    final revision = _revision;
    try {
      final response = await _client
          .get(_url, headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (mounted && revision == _revision && response.statusCode == 200) {
        setState(() => _items = (jsonDecode(response.body) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList());
      }
    } catch (_) {
    } finally {
      _loading = false;
    }
  }

  Future<void> _react(String emoji) async {
    if (_busy) return;
    final mine =
        _items.any((item) => item['emoji'] == emoji && item['mine'] == true);
    _revision++;
    setState(() => _busy = true);
    try {
      final response = await _client
          .put(_url,
              headers: _headers,
              body: jsonEncode({'emoji': mine ? null : emoji}))
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (response.statusCode != 200) throw StateError('reaction rejected');
      setState(() => _items = (jsonDecode(response.body) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('לא ניתן לעדכן את התגובה כרגע')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (widget.client == null) _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final item in _items)
            ActionChip(
                label: Text('${item['emoji']} ${item['count']}'),
                visualDensity: VisualDensity.compact,
                backgroundColor:
                    item['mine'] == true ? const Color(0xFFD4E9F7) : null,
                onPressed:
                    _busy ? null : () => _react(item['emoji'] as String)),
          PopupMenuButton<String>(
            tooltip: 'תגובה להודעה',
            enabled: !_busy,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 70),
            icon: const Icon(Icons.add_reaction_outlined, size: 18),
            onSelected: _react,
            itemBuilder: (_) => [
              for (final emoji in messageReactionEmoji)
                PopupMenuItem(
                    value: emoji,
                    child: Text(emoji, style: const TextStyle(fontSize: 24)))
            ],
          ),
        ],
      );
}
