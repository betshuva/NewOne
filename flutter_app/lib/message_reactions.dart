import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show parseHttpDate;

const messageReactionEmoji = ['👍', '❤️', '😂', '🙏', '😮', '😢'];

typedef _ReactionKey = (String, String, String);
typedef _ReactionScope = (String, String);

class _ReactionEntry {
  _ReactionEntry(this.lastAccess);
  List<Map<String, dynamic>>? items;
  DateTime? refreshAfter;
  DateTime lastAccess;
  Future<List<Map<String, dynamic>>?>? pending;
  int revision = 0;
}

/// Reuses recent results when messages scroll out of view and back in. All
/// entries, pending reads and server cooldowns are scoped to the signed-in token.
class MessageReactionsCache {
  MessageReactionsCache({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static const refreshInterval = Duration(minutes: 1);
  static final shared = MessageReactionsCache();
  final DateTime Function() _now;
  final _entries = <_ReactionKey, _ReactionEntry>{};
  final _cooldowns = <_ReactionScope, DateTime>{};

  _ReactionEntry _entry(_ReactionKey key) {
    final now = _now();
    _entries.removeWhere((_, entry) =>
        entry.pending == null &&
        now.difference(entry.lastAccess) >= const Duration(minutes: 10));
    final entry = _entries.remove(key) ?? _ReactionEntry(now);
    entry.lastAccess = now;
    // A long history must not retain an unbounded collection of reaction data.
    if (_entries.length >= 500) _entries.remove(_entries.keys.first);
    _entries[key] = entry;
    return entry;
  }

  bool _isCoolingDown(_ReactionKey key) {
    final now = _now();
    _cooldowns.removeWhere((_, until) => !until.isAfter(now));
    return _cooldowns.containsKey((key.$1, key.$2));
  }

  void _observeRateLimit(_ReactionKey key, http.Response response) {
    if (response.statusCode != 429) return;
    final now = _now();
    DateTime? until;
    final retryAfter = response.headers['retry-after'];
    final seconds = int.tryParse(retryAfter ?? '');
    if (seconds != null && seconds > 0) {
      until = now.add(Duration(seconds: seconds));
    } else if (retryAfter != null) {
      try {
        final parsed = parseHttpDate(retryAfter);
        if (parsed.isAfter(now)) until = parsed;
      } catch (_) {}
    }
    if (until == null) {
      try {
        final body = jsonDecode(response.body);
        final seconds = body is Map
            ? int.tryParse(body['retryAfterSeconds']?.toString() ?? '')
            : null;
        if (seconds != null && seconds > 0) {
          until = now.add(Duration(seconds: seconds));
        }
      } catch (_) {}
    }
    until ??= now.add(refreshInterval);
    final scope = (key.$1, key.$2);
    final previous = _cooldowns[scope];
    if (previous == null || until.isAfter(previous)) _cooldowns[scope] = until;
  }

  List<Map<String, dynamic>> _decode(http.Response response) =>
      (jsonDecode(response.body) as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();

  Future<List<Map<String, dynamic>>?> _load(_ReactionKey key,
      http.Client client, Uri url, Map<String, String> headers) async {
    final entry = _entry(key);
    if (_isCoolingDown(key) || (entry.refreshAfter?.isAfter(_now()) ?? false)) {
      return entry.items;
    }
    if (entry.pending != null) return entry.pending!;
    final revision = entry.revision;
    Future<List<Map<String, dynamic>>?> request() async {
      final response = await client
          .get(url, headers: headers)
          .timeout(const Duration(seconds: 8));
      _observeRateLimit(key, response);
      if (revision != entry.revision) return entry.items;
      if (response.statusCode == 200) entry.items = _decode(response);
      if (response.statusCode == 403 || response.statusCode == 404) {
        entry.items = [];
      }
      entry.refreshAfter = _now().add(refreshInterval);
      return entry.items;
    }

    entry.pending = request();
    try {
      return await entry.pending;
    } catch (_) {
      // A slow/offline connection must not turn every scroll remount into a
      // fresh network attempt either.
      entry.refreshAfter = _now().add(refreshInterval);
      rethrow;
    } finally {
      entry.pending = null;
    }
  }

  _ReactionEntry _beginWrite(_ReactionKey key) {
    final entry = _entry(key);
    entry.revision++;
    return entry;
  }

  void _save(
      _ReactionEntry entry, int revision, List<Map<String, dynamic>> items) {
    if (entry.revision != revision) return;
    entry.items = items;
    entry.refreshAfter = _now().add(refreshInterval);
  }
}

class MessageReactions extends StatefulWidget {
  final String api, token, messageId;
  final http.Client? client;
  final MessageReactionsCache? cache;
  final bool showAddButton;
  const MessageReactions(
      {super.key,
      required this.api,
      required this.token,
      required this.messageId,
      this.client,
      this.cache,
      this.showAddButton = true});
  @override
  State<MessageReactions> createState() => _MessageReactionsState();
}

class _MessageReactionsState extends State<MessageReactions> {
  late http.Client _client = widget.client ?? http.Client();
  List<Map<String, dynamic>> _items = [];
  Timer? _timer;
  bool _busy = false;
  Object? _loadingRequest;
  int _revision = 0;
  _ReactionKey get _key => (widget.api, widget.token, widget.messageId);
  MessageReactionsCache get _cache =>
      widget.cache ?? MessageReactionsCache.shared;
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
    // Check freshness more often than the cache lifetime so a slow response
    // does not accidentally delay the next real refresh by another minute.
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _load();
      }
    });
  }

  @override
  void didUpdateWidget(covariant MessageReactions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api == widget.api &&
        oldWidget.token == widget.token &&
        oldWidget.messageId == widget.messageId &&
        oldWidget.client == widget.client &&
        oldWidget.cache == widget.cache) {
      return;
    }
    if (oldWidget.client != widget.client) {
      if (oldWidget.client == null) _client.close();
      _client = widget.client ?? http.Client();
    }
    _revision++;
    _loadingRequest = null;
    _busy = false;
    _items = [];
    _load();
  }

  Future<void> _load() async {
    if (_loadingRequest != null || _busy) return;
    final request = Object();
    _loadingRequest = request;
    final revision = _revision;
    try {
      final items = await _cache._load(_key, _client, _url, _headers);
      if (mounted &&
          revision == _revision &&
          items != null &&
          !identical(_items, items)) {
        setState(() => _items = items);
      }
    } catch (_) {
    } finally {
      if (identical(_loadingRequest, request)) _loadingRequest = null;
    }
  }

  Future<void> _react(String emoji) async {
    if (_busy) return;
    if (_cache._isCoolingDown(_key)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('בוצעו יותר מדי בקשות. נסה שוב בעוד מספר דקות.')));
      return;
    }
    final mine =
        _items.any((item) => item['emoji'] == emoji && item['mine'] == true);
    _revision++;
    final revision = _revision;
    final key = _key;
    final cache = _cache;
    final entry = cache._beginWrite(key);
    final entryRevision = entry.revision;
    setState(() => _busy = true);
    try {
      final response = await _client
          .put(_url,
              headers: _headers,
              body: jsonEncode({'emoji': mine ? null : emoji}))
          .timeout(const Duration(seconds: 10));
      cache._observeRateLimit(key, response);
      if (response.statusCode != 200) throw StateError('reaction rejected');
      final items = cache._decode(response);
      cache._save(entry, entryRevision, items);
      if (!mounted || revision != _revision) return;
      setState(() => _items = entry.items ?? []);
    } catch (_) {
      if (mounted && revision == _revision) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('לא ניתן לעדכן את התגובה כרגע')));
      }
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
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
          if (widget.showAddButton)
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
