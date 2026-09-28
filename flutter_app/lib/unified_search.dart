import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

String contactSearchText(Object? value) => (value ?? '')
    .toString()
    .toLowerCase()
    .replaceAll(RegExp(r'[\u0591-\u05bd\u05bf-\u05c7]'), '');

bool contactMatches(Map<String, dynamic> item, String query) {
  final text = [item['name'], item['device_name'], item['phone'], item['email']]
      .whereType<Object>()
      .join(' ');
  if (contactSearchText(text).contains(contactSearchText(query))) return true;
  final digits = query.replaceAll(RegExp(r'\D'), '');
  return digits.length >= 3 &&
      RegExp(r'^[+\d ()-]+$').hasMatch(query) &&
      (item['phone'] ?? '')
          .toString()
          .replaceAll(RegExp(r'\D'), '')
          .contains(digits);
}

class UnifiedSearchResults extends StatefulWidget {
  final String api, token, query;
  final List<Map<String, dynamic>> users, groups;
  final Future<List<Map<String, dynamic>>> Function() loadDeviceContacts;
  final Future<void> Function(Map<String, dynamic>) saveUser;
  final void Function(Map<String, dynamic>, bool) openConversation;
  final void Function(Map<String, dynamic>) openMessage;
  final void Function(List<Map<String, dynamic>>, int) approvePictures;
  final int pictureRevision;
  final int deviceContactsRevision;
  const UnifiedSearchResults(
      {super.key,
      required this.api,
      required this.token,
      required this.query,
      required this.users,
      required this.groups,
      required this.loadDeviceContacts,
      required this.saveUser,
      required this.openConversation,
      required this.openMessage,
      required this.approvePictures,
      required this.pictureRevision, this.deviceContactsRevision = 0});
  @override
  State<UnifiedSearchResults> createState() => _UnifiedSearchResultsState();
}

class _UnifiedSearchResultsState extends State<UnifiedSearchResults> {
  List<Map<String, dynamic>> _directory = [], _device = [], _messages = [];
  final Set<String> _saving = {};
  Timer? _debounce;
  int _generation = 0;
  bool _usersLoading = false, _messagesLoading = false;
  String? _usersError, _messagesError, _cursor;
  Map<String, String> get _headers =>
      {'Authorization': 'Bearer ${widget.token}'};

  @override
  void initState() {
    super.initState();
    widget.loadDeviceContacts().then((rows) {
      if (mounted) setState(() => _device = rows);
    }).catchError((_) {});
    _schedule();
  }

  @override
  void didUpdateWidget(UnifiedSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) _schedule();
    if (oldWidget.deviceContactsRevision != widget.deviceContactsRevision) {
      widget.loadDeviceContacts().then((rows) {
        if (mounted) setState(() => _device = rows);
      }).catchError((_) {});
    }
  }

  void _schedule() {
    _debounce?.cancel();
    final generation = ++_generation;
    _directory = [];
    _messages = [];
    _cursor = null;
    _usersError = _messagesError = null;
    _usersLoading = _messagesLoading = true;
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _searchUsers(generation);
      _searchMessages(generation);
    });
  }

  Future<void> _searchUsers(int generation) async {
    final revision = widget.pictureRevision;
    try {
      final response = await http
          .get(
              Uri.parse('${widget.api}/users/search')
                  .replace(queryParameters: {'q': widget.query}),
              headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (!mounted || generation != _generation) return;
      if (response.statusCode != 200) throw Exception();
      final rows =
          (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
      widget.approvePictures(rows, revision);
      setState(() {
        _directory = rows;
        _usersLoading = false;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _usersLoading = false;
          _usersError = 'חיפוש המשתמשים לא הושלם. נסה שוב';
        });
      }
    }
  }

  Future<void> _searchMessages(int generation, {bool more = false}) async {
    final query = widget.query;
    var cursor = more ? _cursor : null;
    setState(() {
      _messagesLoading = true;
      _messagesError = null;
    });
    try {
      // Search bounded pages of encrypted history. Keep requesting until a
      // matching page is found, with a bounded budget per interaction.
      var pages = 0;
      do {
        pages++;
        final response = await http
            .get(
                Uri.parse('${widget.api}/conversations/search').replace(
                    queryParameters: {
                      'q': query,
                      if (cursor != null) 'cursor': cursor
                    }),
                headers: _headers)
            .timeout(const Duration(seconds: 30));
        if (!mounted || generation != _generation) return;
        if (response.statusCode != 200) throw Exception();
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rows = (data['messages'] as List).cast<Map<String, dynamic>>();
        cursor = data['nextCursor'] as String?;
        setState(() {
          _messages.addAll(rows);
          _cursor = cursor;
        });
        if (rows.isNotEmpty) break;
      } while (cursor != null && pages < 4);
      if (mounted && generation == _generation) {
        setState(() => _messagesLoading = false);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _messagesLoading = false;
          _messagesError = 'חיפוש ההודעות לא הושלם. נסה שוב';
        });
      }
    }
  }

  Future<void> _save(Map<String, dynamic> user) async {
    final id = user['id'].toString();
    setState(() => _saving.add(id));
    try {
      await widget.saveUser(user);
      if (mounted) setState(() => user['saved'] = true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('שמירת החבר נכשלה. נסה שוב')));
      }
    } finally {
      if (mounted) setState(() => _saving.remove(id));
    }
  }

  Widget _heading(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)));

  Widget _person(Map<String, dynamic> user, {bool saved = false}) {
    final deviceOnly = user['device_only'] == true;
    return ListTile(
      leading: Icon(
          deviceOnly ? Icons.contact_phone_outlined : Icons.person_outline),
      title: Text((user['device_name'] ?? user['name'] ?? '').toString()),
      subtitle: Text(deviceOnly
          ? 'איש קשר מהטלפון'
          : saved || user['saved'] == true
              ? 'חבר שמור'
              : 'משתמש בתשובה'),
      onTap: deviceOnly ? null : () => widget.openConversation(user, false),
      trailing: deviceOnly || saved || user['saved'] == true
          ? null
          : TextButton(
              onPressed: _saving.contains(user['id'].toString())
                  ? null
                  : () => _save(user),
              child: Text(_saving.contains(user['id'].toString())
                  ? 'שומר...'
                  : 'שמור')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final savedIds = widget.users.map((u) => u['id']).toSet();
    final deviceIds = _device.map((u) => u['id']).whereType<String>().toSet();
    final users =
        widget.users.where((u) => contactMatches(u, widget.query)).toList();
    final groups = widget.groups
        .where((g) => contactMatches({'name': g['name']}, widget.query))
        .toList();
    final devices = _device
        .where((u) =>
            !savedIds.contains(u['id']) && contactMatches(u, widget.query))
        .toList();
    final directory = _directory
        .where(
            (u) => !savedIds.contains(u['id']) && !deviceIds.contains(u['id']))
        .toList();
    final rows = <Widget>[
      _heading('חברים וקבוצות'),
      ...users.map((u) => _person(u, saved: true)),
      ...groups.map((g) => ListTile(
          leading: const Icon(Icons.group_outlined),
          title: Text((g['name'] ?? '').toString()),
          subtitle: const Text('קבוצה'),
          onTap: () => widget.openConversation(g, true))),
      ...directory.map(_person),
      if (_usersLoading) const LinearProgressIndicator(minHeight: 2),
      if (_usersError != null)
        TextButton(
            onPressed: () => _searchUsers(_generation),
            child: Text(_usersError!)),
      if (!_usersLoading &&
          _usersError == null &&
          users.isEmpty &&
          groups.isEmpty &&
          directory.isEmpty)
        const ListTile(title: Text('לא נמצאו חברים או קבוצות')),
      if (devices.isNotEmpty) ...[
        _heading('אנשי קשר מהטלפון'),
        ...devices.map(_person),
      ],
      _heading('בתוך שיחות'),
      ..._messages.map((m) => ListTile(
          leading: Icon(m['kind'] == 'group'
              ? Icons.forum_outlined
              : Icons.chat_bubble_outline),
          title: Text((m['conversation_name'] ?? '').toString()),
          subtitle: Text('${m['sender_name'] ?? ''}: ${m['body'] ?? ''}',
              maxLines: 3, overflow: TextOverflow.ellipsis),
          onTap: () => widget.openMessage(m))),
      if (_messagesLoading)
        const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator())),
      if (_messagesError != null)
        TextButton(
            onPressed: () =>
                _searchMessages(_generation, more: _cursor != null),
            child: Text(_messagesError!)),
      if (!_messagesLoading && _messagesError == null && _messages.isEmpty)
        ListTile(
            title: Text(_cursor == null
                ? 'לא נמצאו הודעות תואמות'
                : 'לא נמצאו התאמות בהודעות שנבדקו')),
      if (!_messagesLoading && _messagesError == null && _cursor != null)
        TextButton(
            onPressed: () => _searchMessages(_generation, more: true),
            child: const Text('חפש בהודעות ישנות יותר')),
    ];
    return ListView.builder(
        itemCount: rows.length, itemBuilder: (_, i) => rows[i]);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _generation++;
    super.dispose();
  }
}
