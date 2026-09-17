import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// Read-only audit timeline. Server authorization applies to both endpoints.
class FilterAuditScreen extends StatefulWidget {
  const FilterAuditScreen({super.key, required this.api, required this.token});

  final String api;
  final String token;

  @override
  State<FilterAuditScreen> createState() => _FilterAuditScreenState();
}

class _FilterAuditScreenState extends State<FilterAuditScreen> {
  final _message = TextEditingController();
  final _file = TextEditingController();
  List<Map<String, dynamic>> _users = [];
  final List<Map<String, dynamic>> _events = [];
  Map<String, String> _query = {};
  String? _userId;
  String? _cursor;
  String? _error;
  String? _usersError;
  String? _startedAt;
  bool _loading = false;
  bool _usersLoading = true;
  int _request = 0;

  Map<String, String> get _headers =>
      {'Authorization': 'Bearer ${widget.token}'};

  @override
  void initState() {
    super.initState();
    unawaited(_loadUsers());
    unawaited(_load());
  }

  @override
  void dispose() {
    _request++;
    _message.dispose();
    _file.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    try {
      final response = await http
          .get(Uri.parse('${widget.api}/admin/users'), headers: _headers)
          .timeout(const Duration(seconds: 20));
      final data = jsonDecode(response.body);
      if (response.statusCode != 200 || data is! List) {
        throw Exception(data is Map ? data['error'] : 'לא ניתן לטעון משתמשים');
      }
      if (!mounted) return;
      setState(() {
        _users = data
            .whereType<Map>()
            .map((row) => <String, dynamic>{
                  'id': row['id'],
                  'name': row['name'],
                  'email': row['email'],
                })
            .toList();
        _usersLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _usersLoading = false;
        _usersError = 'לא ניתן לטעון את המשתמשים. אפשר לרענן ולנסות שוב.';
      });
    }
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_loading || _cursor == null)) return;
    final request = ++_request;
    if (!more) {
      _query = {
        if (_userId != null && _userId!.isNotEmpty) 'userId': _userId!,
        if (_message.text.trim().isNotEmpty) 'messageId': _message.text.trim(),
        if (_file.text.trim().isNotEmpty) 'fileId': _file.text.trim(),
      };
    }
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        _events.clear();
        _cursor = null;
      }
    });
    final uri = Uri.parse('${widget.api}/admin/filter-timeline')
        .replace(queryParameters: {
      ..._query,
      'limit': '50',
      if (more) 'before': _cursor!,
    });
    try {
      final response = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 20));
      final decoded = jsonDecode(response.body);
      if (response.statusCode != 200 ||
          decoded is! Map ||
          decoded['events'] is! List) {
        throw Exception(decoded is Map
            ? decoded['error'] ?? 'טעינת ההיסטוריה נכשלה'
            : 'טעינת ההיסטוריה נכשלה');
      }
      if (!mounted || request != _request) return;
      setState(() {
        final existing = _events.map((event) => event['id'].toString()).toSet();
        for (final row in (decoded['events'] as List).whereType<Map>()) {
          if (existing.add(row['id'].toString())) {
            _events.add(Map<String, dynamic>.from(row));
          }
        }
        _cursor = decoded['nextCursor']?.toString();
        _startedAt = decoded['recordingStartedAt']?.toString() ?? _startedAt;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error is TimeoutException
            ? 'השרת לא השיב בזמן. נסה שוב.'
            : error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _selectUser() async {
    var search = '';
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final matches = _users
              .where((user) => [
                    user['name'],
                    user['email'],
                    user['id'],
                  ].any((value) => (value?.toString() ?? '')
                      .toLowerCase()
                      .contains(search.toLowerCase())))
              .toList();
          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('בחירת משתמש'),
              content: SizedBox(
                width: 450,
                height: 380,
                child: Column(
                  children: [
                    TextField(
                      key: const ValueKey('filter-audit-user-search'),
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'חיפוש לפי שם או אימייל',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (value) =>
                          setDialogState(() => search = value.trim()),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView(
                        children: [
                          ListTile(
                            title: const Text('כל המשתמשים'),
                            onTap: () => Navigator.pop(dialogContext, ''),
                          ),
                          for (final user in matches)
                            ListTile(
                              key: ValueKey('filter-audit-user-${user['id']}'),
                              title: Text(user['name']?.toString() ?? 'ללא שם'),
                              subtitle: Text(user['email']?.toString() ??
                                  user['id'].toString()),
                              onTap: () => Navigator.pop(
                                  dialogContext, user['id'].toString()),
                            ),
                          if (matches.isEmpty)
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text('לא נמצאו משתמשים'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('ביטול'),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _userId = selected.isEmpty ? null : selected);
    await _load();
  }

  String get _selectedName {
    if (_userId == null) return 'כל המשתמשים';
    for (final user in _users) {
      if (user['id'] == _userId) return user['name']?.toString() ?? _userId!;
    }
    return _userId!;
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('היסטוריית סינון'),
            actions: [
              IconButton(
                tooltip: 'רענן היסטוריה',
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  if (_usersError != null) {
                    setState(() {
                      _usersError = null;
                      _usersLoading = true;
                    });
                    unawaited(_loadUsers());
                  }
                  unawaited(_load());
                },
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth > 650
                        ? 210.0
                        : constraints.maxWidth;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: width,
                          child: OutlinedButton.icon(
                            key: const ValueKey('filter-audit-select-user'),
                            onPressed: _usersLoading ? null : _selectUser,
                            icon: const Icon(Icons.person_search_outlined),
                            label: Text(
                              _usersLoading ? 'טוען משתמשים...' : _selectedName,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: TextField(
                            key: const ValueKey('filter-audit-message-id'),
                            controller: _message,
                            textDirection: TextDirection.ltr,
                            decoration: const InputDecoration(
                              labelText: 'מזהה הודעה (אופציונלי)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _load(),
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: TextField(
                            key: const ValueKey('filter-audit-file-id'),
                            controller: _file,
                            textDirection: TextDirection.ltr,
                            decoration: const InputDecoration(
                              labelText: 'מזהה קובץ (אופציונלי)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _load(),
                          ),
                        ),
                        FilledButton(
                          onPressed: () => _load(),
                          child: const Text('הצג היסטוריה'),
                        ),
                      ],
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'מהחדש לישן לפי רישום השרת; הזמנים מוצגים לפי המכשיר. '
                  'מצב התחלתי אינו משחזר שינויים קודמים. '
                  'דיווח מהדפדפן אינו הוכחה לצפייה של המשתמש.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (_usersError != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_usersError!),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: _loading && _events.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          Text(
                            '${_events.length} אירועים'
                            '${_startedAt == null ? '' : ' · התיעוד החל: ${_localTime(_startedAt)}'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (_events.isEmpty && _error == null)
                            const Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                  'לא נמצאו אירועים מתועדים לבחירה זו. פעולות שקדמו להפעלת היומן אינן משוחזרות.'),
                            ),
                          for (final event in _events)
                            _FilterAuditEvent(
                              key:
                                  ValueKey('filter-audit-event-${event['id']}'),
                              event: event,
                            ),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(_error!,
                                  style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error)),
                            ),
                          if (_cursor != null)
                            TextButton(
                              key: const ValueKey('filter-audit-more'),
                              onPressed:
                                  _loading ? null : () => _load(more: true),
                              child:
                                  Text(_loading ? 'טוען...' : 'אירועים קודמים'),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      );
}

const _categoryLabels = {
  'text': 'טקסט',
  'nonHumanImages': 'נוף וחפצים',
  'men': 'גברים',
  'women': 'נשים',
  'children': 'ילדים',
  'video': 'וידאו',
  'enforceGeneralFilter': 'אכיפת הסינון הכללי',
};
const _kindLabels = {
  'filter_baseline': 'תיעוד מצב התחלתי',
  'filter_changed': 'הגדרות הסינון השתנו',
  'image_classified': 'סיווג התמונה עודכן',
  'decision_allowed': 'השרת אישר את התוכן לפי הסינון',
  'decision_blocked': 'השרת חסם את התוכן לפי הסינון',
  'delivery_persisted': 'הודעה נשמרה בשרת',
  'delivery_blocked_persisted': 'נרשמה חסימת הודעה עבור המשתמש',
  'client_displayed': 'דיווח מהדפדפן: תמונה הוצגה',
  'client_hidden': 'דיווח מהדפדפן: תמונה הוסתרה',
  'history_action': 'בחירה לגבי תמונות קיימות',
  'history_image_action': 'הבחירה הוחלה על תמונה קיימת',
  'history_restored': 'תמונה מוסתרת הוחזרה לתצוגה',
  'history_cleanup': 'תוצאת ניקוי קבצים לאחר מחיקה מההיסטוריה',
};
const _cleanupLabels = {
  'affectedCount': 'תמונות שנמחקו מההיסטוריה',
  'deletedPersonalFiles': 'קבצים אישיים שנוקו',
  'retainedSharedFiles': 'קבצים שדולגו (משותפים או חסרים)',
  'failedFiles': 'קבצים שניקוים נכשל',
};
const _actions = {
  'hide': 'הסתרה',
  'delete': 'מחיקה עבור המשתמש',
  'keep': 'השארה בתצוגה',
  'restore': 'החזרה לתצוגה',
};

String _localTime(Object? raw) {
  final date = DateTime.tryParse(raw?.toString() ?? '')?.toLocal();
  if (date == null) return 'זמן לא ידוע';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year} '
      '${two(date.hour)}:${two(date.minute)}:${two(date.second)}.'
      '${date.millisecond.toString().padLeft(3, '0')}';
}

class _FilterAuditEvent extends StatelessWidget {
  const _FilterAuditEvent({super.key, required this.event});
  final Map<String, dynamic> event;

  @override
  Widget build(BuildContext context) {
    final detail = event['details'] is Map
        ? Map<String, dynamic>.from(event['details'] as Map)
        : <String, dynamic>{};
    final kind = event['kind']?.toString() ?? '';
    final scope = detail['level'] == 'member'
        ? 'הסינון האישי בקבוצה'
        : const {
              'general': 'כללי',
              'contact': 'חבר',
              'group': 'קבוצה',
            }[event['scope_type']] ??
            event['scope_type']?.toString() ??
            '—';
    final before = detail['before'] is Map ? detail['before'] as Map : const {};
    final rawAfter =
        detail['after'] ?? detail['effectiveFilter'] ?? detail['policy'];
    final after = rawAfter is Map ? rawAfter : const {};
    final action = _actions[detail['action']];
    final count = detail['affectedCount'];
    final explanations = <String, String>{
      'history_cleanup':
          'ניקוי הקבצים מתבצע לאחר המחיקה מההיסטוריה. כשל בניקוי קובץ אינו מבטל את המחיקה עבור המשתמש.',
      'filter_baseline':
          'מצב ההגדרות בעת יצירת הרשומה או הפעלת היומן. אין כאן מידע על מועד שינוי ההגדרות בעבר.',
      'delivery_persisted':
          'ההודעה נרשמה בשרת. אירוע זה אינו אישור שהגיעה למכשיר או הוצגה.',
      'decision_allowed': 'זו החלטת סינון בשרת, ואינה הוכחה למסירה או לתצוגה.',
      'client_displayed':
          'דיווח מהדפדפן. זמן השרת מתעד את קליטת הדיווח; זמן המכשיר אינו מאומת.',
      'client_hidden':
          'דיווח מהדפדפן. זמן השרת מתעד את קליטת הדיווח; זמן המכשיר אינו מאומת.',
    };
    final classification = detail['classification'];
    final categories = classification is Map
        ? classification['detectedCategories'] ??
            [if (classification['category'] != null) classification['category']]
        : null;
    final snapshot = {
      'serverTime': event['created_at'],
      'kind': kind,
      'scopeId': event['scope_id'],
      'actorId': event['actor_id'],
      'messageId': event['message_id'],
      'fileId': event['file_id'],
      'details': detail,
    };
    String state(String key, bool value) => key == 'enforceGeneralFilter'
        ? (value ? 'פעילה' : 'כבויה')
        : (value ? 'מותר' : 'חסום');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_kindLabels[kind] ?? 'אירוע סינון נוסף',
                style: Theme.of(context).textTheme.titleMedium),
            Text(_localTime(event['created_at']),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text('${event['user_name'] ?? 'משתמש ללא שם'} · סינון: $scope'),
            if (event['actor_name'] != null)
              Text('בוצע על ידי: ${event['actor_name']}'),
            if (explanations[kind] != null) Text(explanations[kind]!),
            if (action != null && kind != 'history_cleanup')
              Text('בחירת המשתמש: $action'
                  '${count is int ? ' · $count תמונות' : ''}'),
            if (kind == 'history_cleanup')
              for (final entry in _cleanupLabels.entries)
                if (detail[entry.key] is int && (detail[entry.key] as int) >= 0)
                  Text('${entry.value}: ${detail[entry.key]}'),
            if (categories is List && categories.isNotEmpty)
              Text(
                  'סיווג: ${categories.map((value) => _categoryLabels[value] ?? value).join(', ')}'),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final entry in _categoryLabels.entries)
                  if (after[entry.key] is bool)
                    Chip(
                      label: Text('${entry.value}: '
                          '${before[entry.key] is bool && before[entry.key] != after[entry.key] ? '${state(entry.key, before[entry.key] as bool)} ← ' : ''}'
                          '${state(entry.key, after[entry.key] as bool)}'),
                    ),
              ],
            ),
            Text('אירוע #${event['id']}',
                style: Theme.of(context).textTheme.bodySmall),
            if (event['message_id'] != null)
              SelectableText('הודעה: ${event['message_id']}'),
            if (event['file_id'] != null)
              SelectableText('קובץ: ${event['file_id']}'),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('פרטי האירוע, גרסאות הסינון וזמן UTC'),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(snapshot),
                    textDirection: TextDirection.ltr,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
