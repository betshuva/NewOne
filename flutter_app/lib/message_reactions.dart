import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show parseHttpDate;
import 'inline_custom_emoji.dart';
import 'message_reaction_details.dart';
import 'message_reaction_picker.dart';

const messageReactionEmoji = ['👍', '❤️', '😂', '🙏', '😮', '😢'];
const _reactionAssets = {
  '👍': '1f44d',
  '❤️': '2764',
  '😂': '1f602',
  '🙏': '1f64f',
  '😮': '1f62e',
  '😢': '1f622'
};
final _customReactionToken = RegExp(r'^\[\[bt-emoji:([0-9]{3})\]\]$');

bool _isCustomReaction(String emoji) {
  final match = _customReactionToken.firstMatch(emoji);
  if (match == null || match[0] != emoji) return false;
  final id = int.tryParse(match[1]!);
  return id != null && id >= 1 && id <= 150;
}

String _reactionDescription(String emoji) =>
    _isCustomReaction(emoji) ? 'אימוג׳י' : emoji;

typedef _ReactionKey = (String, String, String);
typedef _ReactionScope = (String, String);

class _ReactionEntry {
  _ReactionEntry(this.lastAccess);
  List<Map<String, dynamic>>? items;
  DateTime? refreshAfter;
  DateTime lastAccess;
  Future<List<Map<String, dynamic>>?>? pending;
  int revision = 0;
  String? lastEventId;
}

/// Reuses recent results when messages scroll out of view and back in. All
/// entries, pending reads and server cooldowns are scoped to the signed-in token.
class MessageReactionsCache extends ChangeNotifier {
  MessageReactionsCache({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static const refreshInterval = Duration(minutes: 1);
  static final shared = MessageReactionsCache();
  final DateTime Function() _now;
  final _entries = <_ReactionKey, _ReactionEntry>{};
  final _cooldowns = <_ReactionScope, DateTime>{};

  /// Socket activity invalidates only this account's message. A late read
  /// cannot overwrite the refresh, and duplicate events share one request.
  void invalidate({
    required String api,
    required String token,
    required String messageId,
    required String eventId,
  }) {
    final key = (api, token, messageId);
    final entry = _entries[key];
    if (entry == null || entry.lastEventId == eventId) return;
    entry.lastEventId = eventId;
    entry.revision++;
    entry.refreshAfter = null;
    notifyListeners();
  }

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
    notifyListeners();
  }
}

/// Owned by the caller, so closing an emoji picker cannot cancel its write.
Future<void> updateMessageReaction({
  required String api,
  required String token,
  required String messageId,
  required String emoji,
  http.Client? client,
  MessageReactionsCache? cache,
}) async {
  final connection = client ?? http.Client();
  final reactionCache = cache ?? MessageReactionsCache.shared;
  final key = (api, token, messageId);
  final url = Uri.parse('$api/messages/$messageId/reactions');
  final headers = {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json'
  };
  try {
    final items = await reactionCache._load(key, connection, url, headers);
    if (reactionCache._isCoolingDown(key))
      throw StateError('reaction cooldown');
    final mine =
        items?.any((item) => item['emoji'] == emoji && item['mine'] == true) ??
            false;
    final entry = reactionCache._beginWrite(key);
    final revision = entry.revision;
    final response = await connection
        .put(url,
            headers: headers, body: jsonEncode({'emoji': mine ? null : emoji}))
        .timeout(const Duration(seconds: 10));
    reactionCache._observeRateLimit(key, response);
    if (response.statusCode != 200) throw StateError('reaction rejected');
    reactionCache._save(entry, revision, reactionCache._decode(response));
  } finally {
    if (client == null) connection.close();
  }
}

class MessageReactions extends StatefulWidget {
  final String api, token, messageId;
  final http.Client? client;
  final MessageReactionsCache? cache;
  final bool showAddButton;
  final bool quickChoices;
  final bool showExistingReactions;
  final bool compact;
  final ValueChanged<String>? onReactionSelected;
  const MessageReactions(
      {super.key,
      required this.api,
      required this.token,
      required this.messageId,
      this.client,
      this.cache,
      this.showAddButton = true,
      this.quickChoices = false,
      this.compact = false,
      this.showExistingReactions = true,
      this.onReactionSelected});
  @override
  State<MessageReactions> createState() => _MessageReactionsState();
}

class _ReactionScopeChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

class _MessageReactionsState extends State<MessageReactions> {
  late http.Client _client = widget.client ?? http.Client();
  List<Map<String, dynamic>> _items = [];
  Timer? _timer;
  bool _busy = false;
  Object? _loadingRequest;
  int _revision = 0;
  bool _refreshNeeded = false;
  final _scopeChanges = _ReactionScopeChanges();
  int _scopeRevision = 0;
  bool _detailsOpen = false;
  bool _libraryPickerOpen = false;
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
    _cache.addListener(_syncCache);
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
    if (oldWidget.cache != widget.cache) {
      (oldWidget.cache ?? MessageReactionsCache.shared)
          .removeListener(_syncCache);
      _cache.addListener(_syncCache);
    }
    if (oldWidget.api == widget.api &&
        oldWidget.token == widget.token &&
        oldWidget.messageId == widget.messageId &&
        oldWidget.client == widget.client &&
        oldWidget.cache == widget.cache) {
      return;
    }
    _scopeRevision++;
    _scopeChanges.changed();
    if (oldWidget.client != widget.client) {
      if (oldWidget.client == null) _client.close();
      _client = widget.client ?? http.Client();
    }
    _revision++;
    _loadingRequest = null;
    _refreshNeeded = false;
    _busy = false;
    _items = [];
    _load();
  }

  void _syncCache() {
    final entry = _cache._entries[_key];
    final items = entry?.items;
    if (mounted && items != null && !identical(items, _items)) {
      setState(() => _items = items);
    }
    if (mounted && entry != null && entry.refreshAfter == null) {
      _refreshNeeded = true;
      _load();
    }
  }

  Future<void> _load() async {
    if (_loadingRequest != null || _busy) return;
    final request = Object();
    _loadingRequest = request;
    _refreshNeeded = false;
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
      if (identical(_loadingRequest, request)) {
        _loadingRequest = null;
        if (mounted &&
            revision == _revision &&
            !_cache._isCoolingDown(_key) &&
            (_refreshNeeded || _cache._entries[_key]?.refreshAfter == null)) {
          _load();
        }
      }
    }
  }

  Future<void> _react(String? emoji, {bool toggleOwn = true}) async {
    if (_busy) return;
    if (_cache._isCoolingDown(_key)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('בוצעו יותר מדי בקשות. נסה שוב בעוד מספר דקות.')));
      return;
    }
    final mine = toggleOwn &&
        emoji != null &&
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
      if (mounted && revision == _revision) {
        setState(() => _busy = false);
        if (_refreshNeeded || _cache._entries[_key]?.refreshAfter == null)
          _load();
      }
    }
  }

  void _selectReaction(String emoji) {
    final onSelected = widget.onReactionSelected;
    if (onSelected != null) {
      onSelected(emoji);
    } else {
      _react(emoji);
    }
  }

  Future<void> _chooseAdditionalReaction() async {
    if (_busy || _libraryPickerOpen) return;
    final scope = _key;
    final scopeRevision = _scopeRevision;
    final own = _items.where((item) => item['mine'] == true).firstOrNull;
    _libraryPickerOpen = true;
    try {
      final selected = await showMessageReactionEmojiPicker(context,
          selectedEmoji: own?['emoji']?.toString());
      if (!mounted ||
          selected == null ||
          _key != scope ||
          _scopeRevision != scopeRevision) {
        return;
      }
      // The picker only returns a value. Its owning caller decides when and
      // where the authenticated user's reaction is written.
      _selectReaction(selected);
    } finally {
      _libraryPickerOpen = false;
    }
  }

  Future<void> _chooseReaction(BuildContext anchorContext,
      {String? ownEmojiOverride, bool ownershipKnown = false}) async {
    if (_busy) return;
    final scope = _key;
    final scopeRevision = _scopeRevision;
    final entry = _cache._entry(scope);
    final entryRevision = entry.revision;
    final own = _items.where((item) => item['mine'] == true).firstOrNull;
    final ownEmoji =
        ownershipKnown ? ownEmojiOverride : own?['emoji']?.toString();
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    final anchor = anchorContext.findRenderObject();
    if (overlay is! RenderBox || anchor is! RenderBox) return;
    var selected = await showMenu<String>(
      context: context,
      useRootNavigator: false,
      routeSettings: const RouteSettings(name: 'message-reaction-picker'),
      position: RelativeRect.fromRect(
          anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size,
          Offset.zero & overlay.size),
      items: [
        for (final emoji in messageReactionEmoji)
          PopupMenuItem(
            key: ValueKey('change-reaction-$emoji'),
            value: emoji,
            child: Semantics(
              label: 'תגובה $emoji',
              child: Row(children: [
                SvgPicture.asset(
                    'assets/twemoji/svg/${_reactionAssets[emoji]}.svg',
                    width: 24,
                    height: 24,
                    excludeFromSemantics: true),
                const SizedBox(width: 12),
                if (emoji == ownEmoji) const Icon(Icons.check, size: 18),
              ]),
            ),
          ),
        const PopupMenuItem(
          key: ValueKey('more-message-reactions'),
          value: '__more_message_reactions__',
          child: Row(children: [
            Icon(Icons.add_reaction_outlined, size: 24),
            SizedBox(width: 12),
            Text('אימוג׳י נוספים'),
          ]),
        ),
        if (ownEmoji != null)
          const PopupMenuItem(
            key: ValueKey('remove-own-reaction'),
            value: '__remove_own_reaction__',
            child: Text('הסר את התגובה שלי'),
          ),
      ],
    );
    if (!mounted ||
        selected == null ||
        _key != scope ||
        _scopeRevision != scopeRevision) return;
    if (selected == '__more_message_reactions__') {
      selected = await showMessageReactionEmojiPicker(context,
          selectedEmoji: ownEmoji);
      if (!mounted ||
          selected == null ||
          _key != scope ||
          _scopeRevision != scopeRevision) {
        return;
      }
    }
    if (selected == '__remove_own_reaction__') {
      await _react(null, toggleOwn: false);
    } else {
      final currentOwn = ownershipKnown && entry.revision == entryRevision
          ? ownEmojiOverride
          : _items.where((item) => item['mine'] == true).firstOrNull?['emoji'];
      if (selected != currentOwn ||
          _cache._entries[_key]?.refreshAfter == null) {
        await _react(selected, toggleOwn: false);
      }
    }
  }

  Widget _detailsEmoji(String emoji, double size) {
    if (_isCustomReaction(emoji)) {
      // Reuse the immutable, same-origin artwork and its Hebrew semantics.
      // Inline text scales images by 1.35; compensate here to keep reactions
      // at the exact 20px/24px glyph size regardless of text accessibility size.
      return SizedBox.square(
        dimension: size,
        child: Center(
          child: MediaQuery.withNoTextScaling(
            child: InlineEmojiText(emoji,
                style: TextStyle(fontSize: size / 1.35, height: 1),
                textDirection: TextDirection.ltr,
                maxLines: 1),
          ),
        ),
      );
    }
    final asset = _reactionAssets[emoji];
    return asset == null
        ? Text(emoji, style: TextStyle(fontSize: size, height: 1))
        : SvgPicture.asset('assets/twemoji/svg/$asset.svg',
            width: size, height: size, excludeFromSemantics: true);
  }

  Future<void> _showDetails() async {
    if (_busy || _detailsOpen) return;
    final scope = _key;
    final scopeRevision = _scopeRevision;
    bool isCurrent() =>
        mounted && _key == scope && _scopeRevision == scopeRevision;
    final connection = _client;
    final headers = Map<String, String>.from(_headers);
    final url = Uri.parse('${scope.$1}/messages/${scope.$3}/reactions/details');
    _detailsOpen = true;
    try {
      await showDialog<void>(
          context: context,
          builder: (_) => MessageReactionDetailsDialog(
                api: scope.$1,
                scopeChanges: _scopeChanges,
                reactionChanges: _cache,
                currentReactionRevision: () =>
                    _cache._entries[scope]?.revision ?? 0,
                isCurrentScope: isCurrent,
                emojiBuilder: _detailsEmoji,
                loadDetails: () async {
                  for (var attempt = 0; attempt < 2; attempt++) {
                    if (!isCurrent() || _cache._isCoolingDown(scope)) {
                      throw StateError('reaction details unavailable');
                    }
                    final entry = _cache._entry(scope);
                    final revision = entry.revision;
                    final response = await connection
                        .get(url, headers: headers)
                        .timeout(const Duration(seconds: 8));
                    if (!isCurrent())
                      throw StateError('reaction account changed');
                    _cache._observeRateLimit(scope, response);
                    if (response.statusCode != 200) {
                      throw StateError('reaction details rejected');
                    }
                    if (entry.revision != revision) continue;
                    // Details never overwrite summary/cache state. A delayed
                    // snapshot cannot undo a newer write or socket refresh.
                    return Map<String, dynamic>.from(
                        jsonDecode(response.body) as Map);
                  }
                  throw StateError('reaction details changed during load');
                },
                onChooseOwn: (anchor, ownEmoji) async {
                  if (isCurrent() && anchor.mounted)
                    await _chooseReaction(anchor,
                        ownEmojiOverride: ownEmoji, ownershipKnown: true);
                },
              ));
    } finally {
      _detailsOpen = false;
    }
  }

  Widget _compactReaction(Map<String, dynamic> item) {
    final emoji = item['emoji'].toString();
    final count = int.tryParse('${item['count']}') ?? 0;
    final description = _reactionDescription(emoji);
    return Builder(
        builder: (anchorContext) => Semantics(
              button: true,
              selected: item['mine'] == true,
              label: 'תגובה $description${count >= 2 ? ', $count תגובות' : ''}',
              child: Tooltip(
                message: 'הצגת תגובות $description',
                child: TextButton(
                  key: ValueKey('compact-reaction-$emoji'),
                  onPressed: _busy ? null : _showDetails,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(32, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: Colors.transparent,
                    overlayColor: Colors.transparent,
                    elevation: 0,
                    side: BorderSide.none,
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    _detailsEmoji(emoji, 20),
                    if (count >= 2) ...[
                      const SizedBox(width: 3),
                      Text('$count',
                          style: const TextStyle(fontSize: 11, height: 1)),
                    ],
                  ]),
                ),
              ),
            ));
  }

  @override
  void dispose() {
    _scopeRevision++;
    _scopeChanges.changed();
    _scopeChanges.dispose();
    _timer?.cancel();
    _cache.removeListener(_syncCache);
    if (widget.client == null) _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 4,
        runSpacing: 2,
        textDirection: widget.compact ? TextDirection.rtl : null,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (widget.quickChoices)
            for (final emoji in messageReactionEmoji)
              IconButton(
                tooltip: 'תגובה $emoji',
                onPressed: _busy ? null : () => _selectReaction(emoji),
                isSelected: widget.showExistingReactions &&
                    _items.any((item) =>
                        item['emoji'] == emoji && item['mine'] == true),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 30, height: 30),
                style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                icon: SvgPicture.asset(
                    'assets/twemoji/svg/${_reactionAssets[emoji]}.svg',
                    width: 16,
                    height: 16,
                    excludeFromSemantics: true),
              ),
          if (widget.showExistingReactions)
            for (final item in _items)
              if (widget.compact)
                _compactReaction(item)
              else
                ActionChip(
                    label: _isCustomReaction(item['emoji'].toString())
                        ? Row(mainAxisSize: MainAxisSize.min, children: [
                            _detailsEmoji(item['emoji'].toString(), 20),
                            if ((int.tryParse('${item['count']}') ?? 0) >=
                                2) ...[
                              const SizedBox(width: 4),
                              Text('${item['count']}'),
                            ],
                          ])
                        : Text((int.tryParse('${item['count']}') ?? 0) >= 2
                            ? '${item['emoji']} ${item['count']}'
                            : '${item['emoji']}'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor:
                        item['mine'] == true ? const Color(0xFFD4E9F7) : null,
                    onPressed:
                        _busy ? null : () => _react(item['emoji'] as String)),
          if (widget.showAddButton)
            IconButton(
              key: const ValueKey('add-message-reaction'),
              tooltip: 'הוספת תגובה',
              onPressed: _busy ? null : _chooseAdditionalReaction,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
              style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              icon: const Icon(Icons.add, size: 18),
            ),
        ],
      );
}
