import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A read-only list of actors, with editing offered only for the server's
/// authenticated `mine` row. No actor identifier is passed to the write path.
class MessageReactionDetailsDialog extends StatefulWidget {
  const MessageReactionDetailsDialog({
    super.key,
    required this.api,
    required this.loadDetails,
    required this.onChooseOwn,
    required this.isCurrentScope,
    required this.scopeChanges,
    required this.reactionChanges,
    required this.currentReactionRevision,
    required this.emojiBuilder,
  });

  final String api;
  final Future<Map<String, dynamic>> Function() loadDetails;
  final Future<void> Function(BuildContext anchor, String? ownEmoji)
      onChooseOwn;
  final bool Function() isCurrentScope;
  final Listenable scopeChanges;
  final Listenable reactionChanges;
  final int Function() currentReactionRevision;
  final Widget Function(String emoji, double size) emojiBuilder;

  @override
  State<MessageReactionDetailsDialog> createState() =>
      _MessageReactionDetailsDialogState();
}

class _MessageReactionDetailsDialogState
    extends State<MessageReactionDetailsDialog> {
  List<Map<String, dynamic>> _reactions = [];
  List<Map<String, dynamic>> _users = [];
  String? _filter;
  bool _loading = true;
  bool _editing = false;
  bool _failed = false;
  int _revision = 0;
  late int _reactionRevision;

  @override
  void initState() {
    super.initState();
    widget.scopeChanges.addListener(_scopeChanged);
    _reactionRevision = widget.currentReactionRevision();
    widget.reactionChanges.addListener(_reactionChanged);
    _load();
  }

  void _reactionChanged() {
    final revision = widget.currentReactionRevision();
    if (!widget.isCurrentScope() || revision == _reactionRevision) return;
    _reactionRevision = revision;
    // Pending reads have their own revision guard. An open picker refreshes
    // after it closes; unrelated messages must not trigger another request.
    if (!_loading && !_editing) _load();
  }

  void _scopeChanged() {
    if (widget.isCurrentScope()) return;
    _revision++;
    // Scope changes can originate during a parent build. Close only this
    // dialog and its own picker after that frame, leaving other routes alone.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final navigator = Navigator.of(context);
      navigator.popUntil((candidate) =>
          candidate == route ||
          candidate.settings.name != 'message-reaction-picker');
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  List<Map<String, dynamic>> _rows(dynamic value) {
    if (value is! List) throw const FormatException('Invalid reaction details');
    return value.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  Future<void> _load() async {
    if (!widget.isCurrentScope()) return;
    final revision = ++_revision;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final data = await widget.loadDetails();
      if (!mounted || !widget.isCurrentScope() || revision != _revision) return;
      final reactions = _rows(data['reactions']);
      final users = _rows(data['users']);
      if (users.any((user) =>
              user['mine'] is! bool ||
              user['user_id'] is! String ||
              user['emoji'] is! String) ||
          users.where((user) => user['mine'] == true).length > 1) {
        throw const FormatException('Invalid reaction actors');
      }
      setState(() {
        _reactions = reactions;
        _users = users;
        if (_filter != null &&
            !reactions.any((reaction) => reaction['emoji'] == _filter)) {
          _filter = null;
        }
      });
    } catch (_) {
      if (mounted && widget.isCurrentScope() && revision == _revision) {
        setState(() {
          _reactions = [];
          _users = [];
          _failed = true;
        });
      }
    } finally {
      if (mounted && widget.isCurrentScope() && revision == _revision) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _chooseOwn(BuildContext anchor) async {
    if (_loading || _failed || _editing || !widget.isCurrentScope()) return;
    setState(() => _editing = true);
    try {
      final own =
          _reactions.where((reaction) => reaction['mine'] == true).firstOrNull;
      await widget.onChooseOwn(anchor, own?['emoji']?.toString());
      if (mounted && widget.isCurrentScope()) await _load();
    } finally {
      if (mounted && widget.isCurrentScope()) {
        setState(() => _editing = false);
      }
    }
  }

  Widget _avatar(Map<String, dynamic> user) {
    final name = user['name']?.toString().trim() ?? '';
    final photo = user['photo_url']?.toString();
    Widget fallback() => Text(name.isEmpty ? '?' : name.characters.first,
        style: const TextStyle(fontSize: 18));
    if (photo != null && photo.startsWith('emoji:')) {
      return CircleAvatar(
          radius: 20,
          child:
              Text(photo.substring(6), style: const TextStyle(fontSize: 23)));
    }
    final uri = photo == null ? null : Uri.tryParse(widget.api)?.resolve(photo);
    final allowed =
        uri != null && (uri.scheme == 'https' || uri.scheme == 'http');
    return CircleAvatar(
      radius: 20,
      child: allowed
          ? ClipOval(
              child: Image.network(uri.toString(),
                  width: 40,
                  height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => fallback()))
          : fallback(),
    );
  }

  Widget _person(Map<String, dynamic> user) {
    final mine = user['mine'] == true;
    return Builder(
        builder: (anchor) => ListTile(
              key: ValueKey('reaction-person-${user['user_id']}'),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              leading: _avatar(user),
              title: Text(mine ? 'את/ה' : user['name']?.toString() ?? 'משתמש',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: mine
                  ? const Text('יש ללחוץ כדי לשנות או להסיר',
                      style: TextStyle(fontSize: 12))
                  : null,
              trailing: widget.emojiBuilder(user['emoji'].toString(), 24),
              onTap: mine && !_editing ? () => _chooseOwn(anchor) : null,
            ));
  }

  @override
  Widget build(BuildContext context) {
    final total = _reactions.fold<int>(0,
        (sum, reaction) => sum + (int.tryParse('${reaction['count']}') ?? 0));
    final users = _users
        .where((user) => _filter == null || user['emoji'] == _filter)
        .toList()
      ..sort(
          (a, b) => (b['mine'] == true ? 1 : 0) - (a['mine'] == true ? 1 : 0));
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        key: const ValueKey('reaction-details-dialog'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: 380,
              maxHeight: MediaQuery.sizeOf(context).height * .75),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(children: [
                Expanded(
                    child: Text(
                        _loading ? 'תגובות אימוג׳י' : '$total תגובות אימוג׳י',
                        style: const TextStyle(fontSize: 15))),
                IconButton(
                    tooltip: 'סגור',
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context)),
              ]),
            ),
            if (!_loading && !_failed) ...[
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ChoiceChip(
                          key: const ValueKey('reaction-filter-all'),
                          label: Text('הכול $total'),
                          selected: _filter == null,
                          showCheckmark: false,
                          onSelected: (_) => setState(() => _filter = null)),
                      for (final reaction in _reactions)
                        ChoiceChip(
                            key: ValueKey(
                                'reaction-filter-${reaction['emoji']}'),
                            label: Row(
                                mainAxisSize: MainAxisSize.min,
                                textDirection: TextDirection.ltr,
                                children: [
                                  Text('${reaction['count']}'),
                                  const SizedBox(width: 4),
                                  widget.emojiBuilder(
                                      reaction['emoji'].toString(), 20),
                                ]),
                            selected: _filter == reaction['emoji'],
                            showCheckmark: false,
                            backgroundColor: reaction['mine'] == true
                                ? const Color(0xFFDEFADE)
                                : Colors.white,
                            onSelected: (_) => setState(() => _filter =
                                _filter == reaction['emoji']
                                    ? null
                                    : reaction['emoji'].toString())),
                      Builder(
                          builder: (anchor) => IconButton(
                                key: const ValueKey('reaction-details-add-own'),
                                tooltip: 'הוסף או שנה את התגובה שלי',
                                onPressed:
                                    _editing ? null : () => _chooseOwn(anchor),
                                icon: const Icon(Icons.add_reaction_outlined,
                                    size: 22),
                              )),
                    ]),
              ),
              const Divider(height: 1),
            ],
            if (_loading)
              const Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(strokeWidth: 2))
            else if (_failed)
              Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('לא ניתן לטעון את התגובות כרגע'),
                    TextButton(onPressed: _load, child: const Text('נסה שוב')),
                  ]))
            else if (users.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(24), child: Text('אין תגובות להצגה'))
            else
              Flexible(
                  child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      children: users.map(_person).toList())),
          ]),
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.scopeChanges.removeListener(_scopeChanged);
    widget.reactionChanges.removeListener(_reactionChanged);
    _revision++;
    super.dispose();
  }
}
