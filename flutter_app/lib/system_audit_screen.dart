import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'file_download.dart';

class SystemAuditScreen extends StatefulWidget {
  const SystemAuditScreen({super.key, required this.api, required this.token});

  final String api;
  final String token;

  @override
  State<SystemAuditScreen> createState() => _SystemAuditScreenState();
}

class _EventPage {
  final rows = <Map<String, dynamic>>[];
  String? cursor;
  String? error;
  bool loading = false;
  bool loaded = false;
  bool failedMore = false;
  int request = 0;
  Map<String, dynamic>? boundary;
  Object? eventCount;
}

class _RefreshBudget {
  int remaining = 20;
}

class _AuditWindow {
  const _AuditWindow(this.rows, this.cursor, this.metadata);
  final List<Map<String, dynamic>> rows;
  final String? cursor;
  final Map<String, dynamic> metadata;
}

class _AuditAnchor {
  const _AuditAnchor(this.key, this.offset);
  final GlobalKey key;
  final double offset;
}

class _SystemAuditScreenState extends State<SystemAuditScreen>
    with WidgetsBindingObserver {
  final _user = TextEditingController();
  final _target = TextEditingController();
  final _source = TextEditingController();
  final _targetType = TextEditingController();
  final _rows = <Map<String, dynamic>>[];
  final _expanded = <String>{};
  final _eventPages = <String, _EventPage>{};
  List<Map<String, dynamic>> _actions = [];
  List<String> _statuses = [];
  List<String> _categories = [];
  Map<String, String> _categoryNames = {};
  Map<String, String> _statusNames = {};
  Map<String, String> _applied = {};
  final _columnFilters = <String, Map<String, Map<String, dynamic>>>{
    'operations': {},
    'events': {},
  };
  late DateTimeRange _dates;
  String? _action;
  String? _status;
  String? _category;
  String? _cursor;
  String? _error;
  String? _catalogError;
  String? _startedAt;
  Object? _coverage;
  bool _eventsMode = false;
  bool _loading = false;
  bool _failedMore = false;
  bool _exporting = false;
  int _request = 0;
  int _epoch = 0;
  int _catalogRequest = 0;
  BuildContext? _columnDialogContext;
  final _scroll = ScrollController();
  final _viewportKey = GlobalKey();
  final _rowKeys = <String, GlobalKey>{};
  Map<String, dynamic>? _boundary;
  Timer? _refreshTimer;
  bool _refreshRunning = false;
  bool _foregroundLoaded = false;
  bool _resumed = true;
  bool _routeCurrent = true;
  int _refreshGeneration = 0;
  int _refreshFailures = 0;
  int _dialogs = 0;
  String? _refreshError;
  final _selected = <String, Map<String, dynamic>>{};
  bool _canDelete = false;
  bool _deleting = false;
  int _deleteRequest = 0;
  BuildContext? _deleteDialogContext;
  BuildContext? _previewDialogContext;
  final _previewLoads = <String, Future<Uint8List?>>{};
  int _previewGeneration = 0;
  String? _deleteError;

  Map<String, String> get _headers =>
      {'Authorization': 'Bearer ${widget.token}'};
  String get _mode => _eventsMode ? 'events' : 'operations';
  Map<String, Map<String, dynamic>> get _activeColumns =>
      _columnFilters[_mode]!;
  Map<String, String> get _appliedQuery => {
        ..._applied,
        'previews': '1',
        if (!_eventsMode) 'scope': 'user',
        if (!_eventsMode) 'match': 'items',
        if (!_eventsMode) 'steps': '1',
        if (_activeColumns.isNotEmpty)
          'columnFilters': jsonEncode(_activeColumns),
      };

  Map<String, String> get _childFilters {
    final filters = <String, Map<String, dynamic>>{};
    for (final entry in _columnFilters['operations']!.entries) {
      if (['action', 'event_count', 'duration_ms'].contains(entry.key)) {
        continue;
      }
      filters[entry.key == 'initiator_id' ? 'executor_id' : entry.key] =
          entry.value;
    }
    return {
      'steps': '1',
      'previews': '1',
      if (filters.isNotEmpty) 'columnFilters': jsonEncode(filters)
    };
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final today = DateUtils.dateOnly(DateTime.now());
    _dates = DateTimeRange(
        start: DateTime(today.year, today.month, today.day - 6), end: today);
    _applied = _filters();
    unawaited(_catalog());
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    if (current != _routeCurrent) {
      _routeCurrent = current;
      _invalidateRefresh();
      if (current) _scheduleRefresh();
    }
  }

  @override
  void didUpdateWidget(covariant SystemAuditScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api || oldWidget.token != widget.token) {
      for (final dialogContext in [
        _columnDialogContext,
        _deleteDialogContext,
        _previewDialogContext,
      ]) {
        if (dialogContext != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!dialogContext.mounted) return;
            final route = ModalRoute.of(dialogContext);
            if (route != null) Navigator.of(dialogContext).removeRoute(route);
          });
        }
      }
      _selected.clear();
      _deleteRequest++;
      _previewGeneration++;
      _previewLoads.clear();
      _canDelete = false;
      _deleting = false;
      _deleteError = null;
      _actions = [];
      _statuses = [];
      _categories = [];
      _startedAt = null;
      _coverage = null;
      unawaited(_catalog());
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _invalidateRefresh();
    _scroll.dispose();
    _request++;
    _catalogRequest++;
    _epoch++;
    for (final controller in [_user, _target, _source, _targetType]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _invalidateRefresh();
    if (_resumed) _scheduleRefresh();
  }

  bool get _canPoll =>
      mounted &&
      _resumed &&
      !_loading &&
      !_exporting &&
      !_deleting &&
      _selected.isEmpty &&
      _dialogs == 0 &&
      !_eventPages.values.any((page) => page.loading) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  bool get _canRefresh => _canPoll && _foregroundLoaded;

  void _invalidateRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _refreshGeneration++;
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    if (!mounted || !_resumed || _refreshRunning || _loading) return;
    final seconds = _refreshFailures == 0
        ? 5
        : [10, 20, 40, 60][(_refreshFailures - 1).clamp(0, 3)];
    _refreshTimer = Timer(Duration(seconds: seconds), () {
      _refreshTimer = null;
      if (_canRefresh) {
        unawaited(_refresh());
      } else if (_canPoll && !_foregroundLoaded) {
        unawaited(_load(automatic: true));
      } else {
        _scheduleRefresh();
      }
    });
  }

  void _openDialog() {
    _dialogs++;
    _invalidateRefresh();
  }

  void _closeDialog() {
    _dialogs--;
    _scheduleRefresh();
  }

  int _compareRows(
      Map<String, dynamic> a, Map<String, dynamic> b, String mode) {
    if (mode == 'events') {
      return BigInt.parse(a['id'].toString())
          .compareTo(BigInt.parse(b['id'].toString()));
    }
    final time = DateTime.parse(a['created_at'].toString())
        .compareTo(DateTime.parse(b['created_at'].toString()));
    return time != 0 ? time : a['id'].toString().compareTo(b['id'].toString());
  }

  Future<_AuditWindow> _readWindow(
      String path,
      String mode,
      Map<String, String> query,
      String? oldCursor,
      Map<String, dynamic>? boundary,
      _RefreshBudget budget,
      bool Function() current) async {
    final rows = <Map<String, dynamic>>[];
    final seenCursors = <String>{};
    String? before;
    Map<String, dynamic> metadata = {};
    if (oldCursor != null && boundary == null) throw const FormatException();
    // The foreground boundary survives filtered-out rows; its opaque cursor
    // still owns the next page even when a larger refresh page overshoots it.
    while (true) {
      if (!current()) throw const FormatException();
      if (budget.remaining-- <= 0) {
        throw 'העדכון האוטומטי לא הושלם: היומן גדול מדי. רענן את הרשימה';
      }
      final data = await _get(path, {
        ...query,
        'limit': '200',
        if (before != null) 'before': before,
      });
      if (!current()) throw const FormatException();
      if (data[mode] is! List) throw const FormatException();
      metadata = data;
      final incoming = _maps(data[mode]);
      _append(rows, incoming);
      final next = _cursorValue(data['nextCursor']);
      final reached = oldCursor != null &&
          incoming.isNotEmpty &&
          _compareRows(incoming.last, boundary!, mode) <= 0;
      if (next == null || reached) {
        var trimmed = false;
        if (oldCursor != null) {
          rows.removeWhere((row) {
            final older = _compareRows(row, boundary!, mode) < 0;
            trimmed = trimmed || older;
            return older;
          });
        }
        return _AuditWindow(
            rows,
            oldCursor != null && (trimmed || next != null) ? oldCursor : null,
            metadata);
      }
      if (incoming.isEmpty || !seenCursors.add(next)) {
        throw const FormatException();
      }
      before = next;
    }
  }

  List<_AuditAnchor> _captureAnchors() {
    if (!_scroll.hasClients || _scroll.offset <= 1) return [];
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return [];
    final top = viewport.localToGlobal(Offset.zero).dy;
    final anchors = <_AuditAnchor>[];
    for (final key in _rowKeys.values) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final offset = box.localToGlobal(Offset.zero).dy - top;
      if (offset + box.size.height > 0 && offset < viewport.size.height) {
        anchors.add(_AuditAnchor(key, offset));
      }
    }
    anchors.sort((a, b) => a.offset.compareTo(b.offset));
    return anchors;
  }

  void _restoreAnchors(
      List<_AuditAnchor> anchors, bool atTop, bool Function() current) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!current() || !_scroll.hasClients) return;
      if (atTop) {
        _scroll.jumpTo(0);
        return;
      }
      final viewport = _viewportKey.currentContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) return;
      final top = viewport.localToGlobal(Offset.zero).dy;
      for (final anchor in anchors) {
        final box = anchor.key.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) continue;
        final delta = box.localToGlobal(Offset.zero).dy - top - anchor.offset;
        _scroll.jumpTo((_scroll.offset + delta).clamp(
            _scroll.position.minScrollExtent,
            _scroll.position.maxScrollExtent));
        break;
      }
    });
  }

  Future<void> _refresh() async {
    if (_refreshRunning || !_canRefresh) return;
    _refreshTimer?.cancel();
    _refreshRunning = true;
    final generation = _refreshGeneration;
    final mode = _mode;
    bool current() =>
        _canRefresh && generation == _refreshGeneration && mode == _mode;
    try {
      await _refreshRows(mode, current);
    } catch (error) {
      if (current()) {
        _refreshFailures++;
        final message =
            'העדכון האוטומטי נכשל. הנתונים המוצגים עשויים להיות ישנים. ${_errorText(error)}';
        if (_refreshError != message) setState(() => _refreshError = message);
      }
    } finally {
      _refreshRunning = false;
      _scheduleRefresh();
    }
  }

  Future<void> _refreshRows(String mode, bool Function() current,
      {bool forceChildren = false}) async {
    final budget = _RefreshBudget();
    final root = await _readWindow(
        mode, mode, _appliedQuery, _cursor, _boundary, budget, current);
    final children = <String, _AuditWindow>{};
    if (mode == 'operations') {
      for (final row in root.rows) {
        final id = row['id'].toString();
        if (!_expanded.contains(id)) continue;
        final page = _eventPages[id];
        if (!forceChildren &&
            page != null &&
            page.loaded &&
            page.error == null &&
            row['event_count'] == page.eventCount) {
          continue;
        }
        children[id] = await _readWindow(
            'operations/${Uri.encodeComponent(id)}/events',
            'events',
            _childFilters,
            page?.cursor,
            page?.boundary,
            budget,
            current);
      }
    }
    if (!current()) return;
    final changed = _refreshError != null ||
        jsonEncode(_rows) != jsonEncode(root.rows) ||
        _cursor != root.cursor ||
        children.entries.any((entry) {
          final page = _eventPages[entry.key];
          return page == null ||
              page.error != null ||
              jsonEncode(page.rows) != jsonEncode(entry.value.rows) ||
              page.cursor != entry.value.cursor;
        });
    _refreshFailures = 0;
    if (!changed) return;
    final atTop = !_scroll.hasClients || _scroll.offset <= 1;
    final anchors = _captureAnchors();
    setState(() {
      _rowKeys.removeWhere((_, key) => key.currentContext == null);
      _rows
        ..clear()
        ..addAll(root.rows);
      _cursor = root.cursor;
      _refreshError = null;
      _metadata(root.metadata);
      final ids = _rows.map((row) => row['id'].toString()).toSet();
      _expanded.removeWhere((id) => !ids.contains(id));
      _eventPages.removeWhere((id, _) => !ids.contains(id));
      for (final entry in children.entries) {
        final page = _eventPages.putIfAbsent(entry.key, _EventPage.new);
        page.rows
          ..clear()
          ..addAll(entry.value.rows);
        page.cursor = entry.value.cursor;
        page.loaded = true;
        page.error = null;
        page.eventCount = root.rows.firstWhere(
            (row) => row['id'].toString() == entry.key)['event_count'];
      }
    });
    _restoreAnchors(anchors, atTop, current);
  }

  Uri _uri(String path, Map<String, String> query) =>
      Uri.parse('${widget.api}/admin/audit/$path')
          .replace(queryParameters: query);

  Map<String, String> _filters() {
    final end = _dates.end;
    return {
      'from': _dates.start.toUtc().toIso8601String(),
      'to':
          DateTime(end.year, end.month, end.day + 1).toUtc().toIso8601String(),
      if (_user.text.trim().isNotEmpty) 'userId': _user.text.trim(),
      if (_target.text.trim().isNotEmpty) 'targetId': _target.text.trim(),
      if (_targetType.text.trim().isNotEmpty)
        'targetType': _targetType.text.trim(),
      if (_source.text.trim().isNotEmpty) 'source': _source.text.trim(),
      if (_action != null) 'action': _action!,
      if (_status != null) 'status': _status!,
      if (_category != null) 'category': _category!,
    };
  }

  Future<Map<String, dynamic>> _get(
      String path, Map<String, String> query) async {
    final response = await http
        .get(_uri(path, query), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw _requestError(response.statusCode);
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) throw const FormatException();
    return body;
  }

  Future<void> _catalog() async {
    final request = ++_catalogRequest;
    setState(() {
      _catalogError = null;
      _canDelete = false;
    });
    try {
      final data = await _get('catalog', {});
      if (!mounted || request != _catalogRequest) return;
      setState(() {
        _canDelete = data['canDelete'] == true;
        _actions = _maps(data['actions']);
        _statuses = _codes(data['statuses']);
        _statusNames = {
          for (final row in _maps(data['statuses']))
            row['code'].toString():
                row['label']?.toString() ?? row['code'].toString(),
        };
        _categories = _codes(data['categories']);
        _categoryNames = {
          for (final row in _maps(data['categories']))
            row['code'].toString():
                row['label']?.toString() ?? row['code'].toString(),
        };
        _metadata(data);
      });
    } catch (_) {
      if (!mounted || request != _catalogRequest) return;
      setState(() => _catalogError = 'טעינת קטלוג הפעולות נכשלה');
    }
  }

  void _metadata(Map<String, dynamic> data) {
    _startedAt = data['recordingStartedAt']?.toString() ?? _startedAt;
    _coverage = data['coverage'] ?? _coverage;
  }

  Future<void> _load(
      {bool more = false, bool apply = false, bool automatic = false}) async {
    if (more && (_loading || _cursor == null)) return;
    _invalidateRefresh();
    final request = ++_request;
    if (apply) _applied = _filters();
    final mode = _mode;
    final query = {
      ..._appliedQuery,
      'limit': '50',
      if (more) 'before': _cursor!
    };
    setState(() {
      _loading = true;
      _error = null;
      _deleteError = null;
      _refreshError = null;
      if (!automatic) _refreshFailures = 0;
      _failedMore = more;
      if (!more) {
        _selected.clear();
        _epoch++;
        _rows.clear();
        _expanded.clear();
        _eventPages.clear();
        _cursor = null;
        _boundary = null;
        _foregroundLoaded = false;
        _rowKeys.clear();
      }
    });
    try {
      final data = await _get(mode, query);
      if (data[mode] is! List) throw const FormatException();
      if (!mounted || request != _request) return;
      setState(() {
        _append(_rows, _maps(data[mode]));
        _cursor = _cursorValue(data['nextCursor']);
        _boundary = _rows.isEmpty ? null : Map.of(_rows.last);
        _foregroundLoaded = true;
        _refreshFailures = 0;
        _metadata(data);
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _error = _errorText(error);
        if (!_foregroundLoaded) _refreshFailures++;
      });
    } finally {
      if (mounted && request == _request) _scheduleRefresh();
    }
  }

  Future<void> _loadEvents(String id, {bool more = false}) async {
    final page = _eventPages.putIfAbsent(id, _EventPage.new);
    if (page.loading || (more && page.cursor == null)) return;
    _invalidateRefresh();
    final epoch = _epoch;
    final request = ++page.request;
    final query = {
      ..._childFilters,
      'limit': '50',
      if (more) 'before': page.cursor!
    };
    setState(() {
      page.loading = true;
      page.error = null;
      page.failedMore = more;
    });
    try {
      final data =
          await _get('operations/${Uri.encodeComponent(id)}/events', query);
      if (data['events'] is! List) throw const FormatException();
      if (!mounted || epoch != _epoch || request != page.request) return;
      final atTop = !_scroll.hasClients || _scroll.offset <= 1;
      final anchors = more ? _captureAnchors() : <_AuditAnchor>[];
      setState(() {
        if (!more) page.rows.clear();
        _append(page.rows, _maps(data['events']));
        page.cursor = _cursorValue(data['nextCursor']);
        page.boundary = page.rows.isEmpty ? null : Map.of(page.rows.last);
        page.loaded = true;
        page.loading = false;
        page.eventCount = _rows
            .firstWhere((row) => row['id'].toString() == id)['event_count'];
      });
      if (more) {
        _restoreAnchors(anchors, atTop,
            () => mounted && epoch == _epoch && request == page.request);
      }
    } catch (error) {
      if (!mounted || epoch != _epoch || request != page.request) return;
      setState(() {
        page.loading = false;
        page.error = _errorText(error);
      });
    } finally {
      if (mounted && epoch == _epoch && request == page.request) {
        _scheduleRefresh();
      }
    }
  }

  void _toggle(String id) {
    _invalidateRefresh();
    setState(() {
      if (!_expanded.remove(id)) _expanded.add(id);
    });
    if (_expanded.contains(id) && _eventPages[id]?.loaded != true) {
      unawaited(_loadEvents(id));
    }
    _scheduleRefresh();
  }

  Future<void> _chooseDates() async {
    _openDialog();
    try {
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime(DateTime.now().year + 1, 12, 31),
        initialDateRange: _dates,
        helpText: 'טווח תאריכים',
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
      );
      if (picked != null && mounted) setState(() => _dates = picked);
    } finally {
      _closeDialog();
    }
  }

  Future<void> _export() async {
    if (_exporting) return;
    final from = DateTime.tryParse(_applied['from'] ?? '');
    final to = DateTime.tryParse(_applied['to'] ?? '');
    if (from == null ||
        to == null ||
        to.difference(from) > const Duration(days: 31)) {
      _notice('ייצוא מוגבל לטווח של עד 31 ימים');
      return;
    }
    final epoch = _epoch;
    final mode = _mode;
    _invalidateRefresh();
    setState(() => _exporting = true);
    try {
      final response = await http
          .get(_uri('export.csv', {..._appliedQuery, 'mode': mode}),
              headers: _headers)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw _requestError(response.statusCode);
      if (response.bodyBytes.length > 5 * 1024 * 1024) {
        throw const FormatException();
      }
      if (!mounted || epoch != _epoch) return;
      final saved = await triggerBytesDownload(response.bodyBytes,
          'betshuva-audit-$mode-${_date(from.toLocal())}.csv', 'text/csv');
      if (!mounted) return;
      _notice(!saved
          ? 'שמירת קובץ הייצוא לא הושלמה'
          : response.headers['x-audit-export-truncated'] == 'true'
              ? 'הייצוא הוגבל ל-5,000 רשומות'
              : 'קובץ הייצוא נוצר');
    } catch (error) {
      if (mounted && epoch == _epoch) _notice(_errorText(error));
    } finally {
      if (mounted) setState(() => _exporting = false);
      _scheduleRefresh();
    }
  }

  void _notice(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _copy(String id) async {
    await Clipboard.setData(ClipboardData(text: id));
    if (mounted) _notice('מזהה הפעולה הועתק');
  }

  bool _isRootEvent(Map<String, dynamic> row) => row['root_event_id'] != null
      ? row['id'].toString() == row['root_event_id'].toString()
      : row['kind'] == 'operation_started';

  bool get _deleteBlocked =>
      _deleting ||
      _loading ||
      _exporting ||
      _eventPages.values.any((page) => page.loading);

  Widget _selectionBox(Map<String, dynamic> row, {required bool operation}) {
    final key = '${operation ? 'operations' : 'events'}:${row['id']}';
    return Checkbox(
        key: ValueKey('system-audit-select-$key'),
        value: _selected.containsKey(key),
        semanticLabel: 'סמן רשומת תיעוד למחיקה',
        onChanged: _deleteBlocked
            ? null
            : (value) {
                if (value == true && _selected.length >= 200) {
                  _notice('אפשר לסמן עד 200 רשומות');
                  return;
                }
                setState(() {
                  if (value == true) {
                    _selected[key] = {
                      'kind': operation ? 'operations' : 'events',
                      'id': row['id'].toString()
                    };
                  } else {
                    _selected.remove(key);
                  }
                });
              });
  }

  void _selectVisible() {
    void add(Map<String, dynamic> row, bool operation) {
      if (_selected.length >= 200 || (!operation && _isRootEvent(row))) return;
      final kind = operation ? 'operations' : 'events';
      _selected['$kind:${row['id']}'] = {
        'kind': kind,
        'id': row['id'].toString()
      };
    }

    setState(() {
      for (final row in _rows) {
        if (_eventsMode) {
          add(row, false);
          continue;
        }
        final first = _firstStep(row);
        add(first ?? row, first == null);
        if (_expanded.contains(row['id'].toString())) {
          for (final event in _eventPages[row['id'].toString()]?.rows ??
              <Map<String, dynamic>>[]) {
            add(event, false);
          }
        }
      }
    });
  }

  Future<void> _deleteBulk(bool all) async {
    if (!_canDelete || _deleteBlocked || (!all && _selected.isEmpty)) return;
    final request = ++_deleteRequest,
        epoch = _epoch,
        api = widget.api,
        token = widget.token;
    bool current() =>
        mounted &&
        request == _deleteRequest &&
        epoch == _epoch &&
        api == widget.api &&
        token == widget.token;
    final payload = <String, dynamic>{
      'scope': all ? 'all' : 'selected',
      'confirm': all ? 'DELETE_ALL_AUDIT' : 'DELETE_SELECTED_AUDIT'
    };
    _invalidateRefresh();
    setState(() {
      _deleting = true;
      _deleteError = null;
    });
    var removed = 0;
    try {
      String description;
      if (all) {
        final preview = await _get('deletion-preview', {});
        if (!current()) return;
        if (preview['through'] == null) {
          _notice('היומן ריק');
          return;
        }
        payload['through'] = preview['through'];
        description =
            '${preview['operations']} פעולות ו־${preview['events']} רשומות יימחקו מכל היומן, גם מחוץ לסינון. תיעוד המחיקה יישאר.';
      } else {
        payload['operations'] = <String>[];
        payload['events'] = <String>[];
        for (final row in _selected.values) {
          (payload[row['kind']] as List<String>).add(row['id'] as String);
        }
        description =
            '${_selected.length} רשומות מסומנות יימחקו לצמיתות. פעולה ראשית שנבחרה תימחק עם פעולות המשנה שלה.';
      }
      if (!mounted) return;
      _openDialog();
      bool? confirmed;
      try {
        confirmed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) {
              _deleteDialogContext = dialogContext;
              return Directionality(
                  textDirection: TextDirection.rtl,
                  child: AlertDialog(
                      key: const ValueKey('system-audit-bulk-dialog'),
                      title: Text(all ? 'מחיקת כל היומן' : 'מחיקת המסומנות'),
                      content: Text('$description\nהודעות וקבצים לא יימחקו.'),
                      actions: [
                        TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('ביטול')),
                        FilledButton(
                            key: const ValueKey('system-audit-bulk-confirm'),
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: const Text('מחק מהיומן'))
                      ]));
            });
      } finally {
        _deleteDialogContext = null;
        _closeDialog();
      }
      if (confirmed != true || !current()) return;
      var remaining = BigInt.zero;
      do {
        final response = await http
            .delete(Uri.parse('$api/admin/audit/records'),
                headers: {
                  'Authorization': 'Bearer $token',
                  'Content-Type': 'application/json'
                },
                body: jsonEncode(payload))
            .timeout(const Duration(seconds: 60));
        if (!current()) return;
        if (response.statusCode != 200) {
          if (response.statusCode == 401 || response.statusCode == 403) {
            _canDelete = false;
          }
          throw 'המחיקה לא אושרה. יש לרענן לפני ניסיון נוסף';
        }
        final result = jsonDecode(response.body);
        if (result is! Map || result['deleted'] != true) {
          throw 'השרת לא אישר את המחיקה';
        }
        remaining = BigInt.parse(result['remaining'].toString());
        removed += (result['deletedEvents'] as num).toInt();
        if (remaining > BigInt.zero && result['deletedOperations'] == 0) {
          throw 'המחיקה נעצרה. יש לרענן את היומן';
        }
      } while (all && remaining > BigInt.zero && current());
      if (!current()) return;
      setState(() {
        _selected.clear();
        _deleting = false;
      });
      _notice('נמחקו $removed רשומות תיעוד');
      await _load();
    } catch (error) {
      if (current()) {
        setState(() => _deleteError =
            '${removed > 0 ? 'נמחקו $removed רשומות לפני העצירה. ' : ''}${error is String ? error : 'המחיקה לא אושרה. יש לרענן את היומן'}');
      }
    } finally {
      if (mounted && request == _deleteRequest) {
        setState(() => _deleting = false);
        _scheduleRefresh();
      }
    }
  }

  Future<void> _deleteAuditRow(Map<String, dynamic> row,
      {required bool operation}) async {
    if (!_canDelete || _deleteBlocked || (!operation && _isRootEvent(row))) {
      return;
    }
    final id = row['id'].toString();
    final request = ++_deleteRequest;
    final epoch = _epoch;
    final api = widget.api;
    final token = widget.token;
    final mode = _mode;
    bool current() =>
        mounted &&
        request == _deleteRequest &&
        epoch == _epoch &&
        api == widget.api &&
        token == widget.token &&
        mode == _mode;
    _invalidateRefresh();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _deleting = true;
      _deleteError = null;
    });
    var deletionConfirmed = false;
    try {
      if (!mounted) return;
      _openDialog();
      bool? confirmed;
      var decisionMade = false;
      try {
        confirmed = await showDialog<bool>(
          context: context,
          builder: (context) {
            _deleteDialogContext = context;
            return Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                key: const ValueKey('system-audit-delete-dialog'),
                scrollable: true,
                title: Text(operation
                    ? 'מחיקת פעולה מהיומן'
                    : 'מחיקת פעולת משנה מהיומן'),
                content: SizedBox(
                  width: 480,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(operation
                          ? _operationLabel(row)
                          : _actionLabel(row['kind'])),
                      const SizedBox(height: 8),
                      SelectableText('ID $id',
                          textDirection: TextDirection.ltr),
                      const SizedBox(height: 16),
                      Text(operation
                          ? 'הפעולה וכל פעולות המשנה שלה יימחקו מהיומן בלבד. הודעות וקבצים לא יימחקו.'
                          : 'רק פעולת המשנה שנבחרה תימחק מהיומן. הפעולה הראשית, פעולות משנה אחרות, הודעות וקבצים לא יימחקו.'),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    key: const ValueKey('system-audit-delete-cancel'),
                    onPressed: () {
                      if (decisionMade) return;
                      decisionMade = true;
                      Navigator.pop(context, false);
                    },
                    child: const Text('ביטול'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('system-audit-delete-confirm'),
                    style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Theme.of(context).colorScheme.onError),
                    onPressed: () {
                      if (decisionMade) return;
                      decisionMade = true;
                      Navigator.pop(context, true);
                    },
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('מחק מהיומן'),
                  ),
                ],
              ),
            );
          },
        );
      } finally {
        _deleteDialogContext = null;
        _closeDialog();
      }
      if (confirmed != true || !current()) return;
      final path = operation ? 'operations' : 'events';
      final response = await http
          .delete(
            Uri.parse('$api/admin/audit/$path/${Uri.encodeComponent(id)}'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json'
            },
            body: jsonEncode({'confirmId': id}),
          )
          .timeout(const Duration(seconds: 30));
      if (!current()) return;
      final missing = response.statusCode == 404;
      if (!missing) {
        if (response.statusCode == 401 || response.statusCode == 403) {
          setState(() => _canDelete = false);
          throw 'אין הרשאה למחיקת רשומות מהיומן';
        }
        if (response.statusCode == 409) {
          throw 'לא ניתן למחוק אירוע ראשי בנפרד. יש למחוק את הפעולה הראשית';
        }
        if (response.statusCode != 200) throw 'מחיקת הרישום נכשלה. נסה שוב';
        final result = jsonDecode(response.body);
        if (result is! Map || result['deleted'] != true) {
          throw 'השרת לא אישר את מחיקת הרישום';
        }
      }
      deletionConfirmed = true;
      await _refreshRows(mode, current, forceChildren: true);
      if (current()) {
        _notice(missing
            ? 'הרישום כבר אינו קיים. היומן עודכן'
            : 'הרישום נמחק מהיומן');
      }
    } catch (error) {
      if (!current()) return;
      setState(() => _deleteError = deletionConfirmed
          ? 'הרישום אינו קיים, אך עדכון הטבלה נכשל. הנתונים המוצגים עשויים להיות ישנים'
          : error is TimeoutException
              ? 'השרת לא אישר את המחיקה בזמן. יש לעדכן את היומן לפני ניסיון נוסף'
              : error is String
                  ? error
                  : 'מחיקת הרישום לא אושרה. יש לעדכן את היומן');
    } finally {
      if (mounted && request == _deleteRequest) {
        setState(() => _deleting = false);
        _scheduleRefresh();
      }
    }
  }

  Future<void> _details(Map<String, dynamic> row) async {
    final root = (row['operation_id'] ?? row['id'])?.toString() ?? '';
    _openDialog();
    try {
      await showDialog<void>(
          context: context,
          builder: (context) => Directionality(
                textDirection: TextDirection.rtl,
                child: AlertDialog(
                  title: const Text('פרטי רישום'),
                  content: SizedBox(
                      width: 720,
                      child: SingleChildScrollView(
                        child: SelectableText(
                            const JsonEncoder.withIndent('  ')
                                .convert(_safe(row)),
                            key: const ValueKey('system-audit-details-json'),
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 12)),
                      )),
                  actions: [
                    IconButton(
                        tooltip: 'העתק מזהה פעולה',
                        icon: const Icon(Icons.copy),
                        onPressed: root.isEmpty ? null : () => _copy(root)),
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('סגור')),
                  ],
                ),
              ));
    } finally {
      _closeDialog();
    }
  }

  String _actionLabel(Object? raw) {
    final code = raw?.toString() ?? '';
    for (final entry in _actions) {
      if ((entry['action'] ?? entry['code']) == code) {
        return entry['label']?.toString() ?? code;
      }
    }
    return _kindLabels[code] ?? (code.isEmpty ? 'לא ידוע' : code);
  }

  String _statusText(Object? raw) =>
      _statusNames[raw] ?? _statusLabels[raw] ?? _value(raw);

  String _operationLabel(Map<String, dynamic> row) {
    if (row['action'] != 'upload_file') return _actionLabel(row['action']);
    return switch ((row['capture_kind'], row['media_type'])) {
      ('camera_video', 'video') => 'צילום וידאו',
      ('camera_image', 'image') => 'צילום תמונה',
      ('microphone', 'audio') => 'הקלטת קול',
      (_, 'video') => 'העלאת וידאו',
      (_, 'image') => 'העלאת תמונה',
      (_, 'audio') => 'העלאת קובץ קול',
      (_, 'document') => 'העלאת מסמך',
      _ => _actionLabel(row['action']),
    };
  }

  Widget _field(String key, String label, TextEditingController controller) =>
      SizedBox(
          width: 205,
          child: TextField(
            key: ValueKey('system-audit-$key'),
            controller: controller,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
                labelText: label,
                isDense: true,
                border: const OutlineInputBorder()),
            onSubmitted: (_) => _load(apply: true),
          ));

  Widget _select(String key, String label, String? value, List<String> options,
          void Function(String?) changed,
          {String Function(String)? display}) =>
      SizedBox(
          width: 205,
          child: DropdownButtonFormField<String>(
            key: ValueKey('system-audit-$key'),
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(
                labelText: label,
                isDense: true,
                border: const OutlineInputBorder()),
            items: [
              const DropdownMenuItem(value: '', child: Text('הכול')),
              for (final code in {...options, if (value != null) value})
                DropdownMenuItem(
                    value: code,
                    child: Text(display?.call(code) ?? code,
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => changed(v == '' ? null : v)),
          ));

  Widget _filtersPanel() => ExpansionTile(
        key: const ValueKey('system-audit-filters'),
        initiallyExpanded: MediaQuery.sizeOf(context).width >= 900,
        leading: const Icon(Icons.filter_alt_outlined),
        title: const Text('סינון'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                      width: 205,
                      child: OutlinedButton.icon(
                        key: const ValueKey('system-audit-dates'),
                        onPressed: _chooseDates,
                        icon: const Icon(Icons.date_range),
                        label: Text(
                            '${_date(_dates.start)} - ${_date(_dates.end)}',
                            textDirection: TextDirection.ltr,
                            style: const TextStyle(fontSize: 12)),
                      )),
                  _field('user-id', 'מזהה משתמש / מספר קצר', _user),
                  _select(
                      'action',
                      'פעולה',
                      _action,
                      _actions
                          .map((a) => (a['action'] ?? a['code']).toString())
                          .toList(),
                      (v) => _action = v,
                      display: _actionLabel),
                  _select(
                      'status', 'מצב', _status, _statuses, (v) => _status = v,
                      display: _statusText),
                  _select('category', 'קטגוריה', _category, _categories,
                      (v) => _category = v,
                      display: (v) => _categoryNames[v] ?? v),
                  _field('target-type', 'סוג יעד', _targetType),
                  _field('target-id', 'מזהה יעד', _target),
                  _field('source', 'מקור', _source),
                  FilledButton.icon(
                      key: const ValueKey('system-audit-apply'),
                      onPressed: () => _load(apply: true),
                      icon: const Icon(Icons.search),
                      label: const Text('הצג')),
                ],
              ))
        ],
      );

  Widget _errorRow(String text, VoidCallback retry, String key) => Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          const Icon(Icons.error_outline),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
          IconButton(
              key: ValueKey(key),
              tooltip: 'נסה שוב',
              onPressed: retry,
              icon: const Icon(Icons.refresh)),
        ]),
      );

  Widget _cell(String text, {bool code = false}) => Tooltip(
        message: text,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Text(text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textDirection: code ? TextDirection.ltr : TextDirection.rtl,
              style: const TextStyle(fontSize: 12)),
        ),
      );

  Future<void> _chooseColumn(List<_AuditColumn> columns) async {
    final mode = _mode;
    final epoch = _epoch;
    final api = widget.api;
    final token = widget.token;
    final query = _appliedQuery;
    bool current() =>
        mounted &&
        epoch == _epoch &&
        mode == _mode &&
        api == widget.api &&
        token == widget.token;
    _openDialog();
    _ColumnFilterResult? result;
    try {
      result = await showDialog<_ColumnFilterResult>(
        context: context,
        builder: (context) {
          _columnDialogContext = context;
          return _ColumnFilterDialog(
            columns: columns,
            filters: _columnFilters[mode]!,
            isCurrent: current,
            loadOptions: (column, search) async {
              if (!current()) throw 'היומן השתנה. פתח שוב את המסנן';
              return _get('filter-options', {
                ...query,
                'mode': mode,
                'column': column,
                if (search.isNotEmpty) 'search': search,
              });
            },
          );
        },
      );
    } finally {
      _columnDialogContext = null;
      _closeDialog();
    }
    if (result == null || !current()) return;
    setState(() {
      if (result!.filter == null) {
        _columnFilters[mode]!.remove(result.column);
      } else {
        _columnFilters[mode]![result.column] = result.filter!;
      }
    });
    unawaited(_load());
  }

  Widget _columnHeader(String title, List<_AuditColumn> columns) {
    final active =
        columns.any((column) => _activeColumns.containsKey(column.id));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Row(children: [
        Expanded(child: Text(title, style: const TextStyle(fontSize: 12))),
        IconButton(
          key: ValueKey('system-audit-column-${columns.first.id}'),
          tooltip: active ? 'סינון $title (פעיל)' : 'סינון $title',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 36),
          padding: const EdgeInsets.all(6),
          color: active ? Theme.of(context).colorScheme.primary : null,
          icon: Icon(active ? Icons.filter_alt : Icons.filter_alt_outlined,
              size: 18),
          onPressed: () => _chooseColumn(columns),
        ),
      ]),
    );
  }

  Widget _grid(List<Widget> cells, List<double> widths,
          {Key? key,
          bool header = false,
          Color? groupColor,
          bool child = false}) =>
      KeyedSubtree(
          key: key == null
              ? null
              : _rowKeys.putIfAbsent(key.toString(), GlobalKey.new),
          child: DecoratedBox(
            key: key,
            decoration: BoxDecoration(
              color: header
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : groupColor?.withValues(
                      alpha: Theme.of(context).brightness == Brightness.dark
                          ? (child ? .06 : .14)
                          : (child ? .035 : .09)),
              border: Border(
                  right: BorderSide(
                      color: groupColor ?? Colors.transparent, width: 4),
                  bottom: BorderSide(color: Theme.of(context).dividerColor)),
            ),
            child: Table(
              columnWidths: {
                for (var i = 0; i < widths.length; i++)
                  i: FixedColumnWidth(widths[i])
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [TableRow(children: cells)],
            ),
          ));

  Widget _rowActions(Map<String, dynamic> row, {bool operation = false}) =>
      Wrap(
        children: [
          if (_canDelete && (operation || !_isRootEvent(row)))
            _selectionBox(row, operation: operation),
          IconButton(
              key: ValueKey('system-audit-details-${row['id']}'),
              tooltip: 'פרטי רישום',
              icon: const Icon(Icons.data_object, size: 18),
              onPressed: () => _details(row)),
          IconButton(
              key: ValueKey('system-audit-copy-${row['id']}'),
              tooltip: 'העתק מזהה פעולה',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () =>
                  _copy((row['operation_id'] ?? row['id']).toString())),
          if (_canDelete)
            IconButton(
              key: ValueKey(
                  'system-audit-delete-${operation ? 'operation' : 'event'}-${row['id']}'),
              tooltip: !operation && _isRootEvent(row)
                  ? 'מחיקת אירוע ראשי נעשית דרך הפעולה הראשית'
                  : operation
                      ? 'מחק פעולה ופעולות משנה מהיומן'
                      : 'מחק פעולת משנה מהיומן',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: _deleteBlocked || (!operation && _isRootEvent(row))
                  ? null
                  : () => _deleteAuditRow(row, operation: operation),
            ),
        ],
      );

  Widget _eventTable(List<Map<String, dynamic>> events,
          {bool filterable = false}) =>
      Column(children: [
        _grid([
          for (final entry in _eventColumns)
            filterable
                ? _columnHeader(entry.title, entry.columns)
                : _cell(entry.title),
          _cell('פרטים'),
        ], _eventWidths, header: true),
        for (final event in events)
          _grid([
            _cell(_localTime(event['created_at']), code: true),
            _cell(_actionLabel(event['kind'])),
            _checkCell(event),
            _checkResultCell(event),
            _cell(_executor(event)),
            _recipientCell(event),
            _cell(_value(event['source'])),
            _cell(_statusText(event['status'])),
            _cell(
                '${_value(event['target_type'])}\n${_value(event['target_id'])}'),
            _cell(_value(event['reason_code']), code: true),
            _cell(_value(event['attempt']), code: true),
            _cell(
                '${_value(event['operation_id'])}\n${_value(event['parent_event_id'])}',
                code: true),
            _rowActions(event),
          ], _eventWidths, key: ValueKey('system-audit-event-${event['id']}')),
      ]);

  Map<String, dynamic>? _firstStep(Map<String, dynamic> root) =>
      root['first_sub_event'] is Map
          ? Map<String, dynamic>.from(root['first_sub_event'] as Map)
          : null;
  Widget _stepRow(Map<String, dynamic>? event, Map<String, dynamic> root,
      {bool first = false}) {
    final evidence = event ?? root, id = root['id'].toString();
    return _grid([
      first
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  key: ValueKey('system-audit-expand-$id'),
                  tooltip: _expanded.contains(id)
                      ? 'כווץ לשורה הראשונה'
                      : 'הרחב פעולות משנה',
                  icon: Icon(_expanded.contains(id)
                      ? Icons.expand_less
                      : Icons.expand_more),
                  onPressed: () => _toggle(id)),
              if (_canDelete && event != null)
                IconButton(
                    key: ValueKey('system-audit-delete-operation-$id'),
                    tooltip: 'מחק פעולה וכל פעולות המשנה',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: _deleteBlocked
                        ? null
                        : () => _deleteAuditRow(root, operation: true)),
            ])
          : const SizedBox.shrink(),
      _cell(_localTime(evidence['created_at']), code: true),
      _actionCell(root),
      _cell(event == null
          ? (root['sub_event_count'].toString() == '0'
              ? 'טרם תועדו פעולות משנה'
              : 'אין פעולות משנה התואמות לסינון')
          : '${_actionLabel(event['kind'])}${event['sub_event_index'] != null ? '\n${event['sub_event_index']} מתוך ${event['sub_event_total']}' : ''}'),
      _checkCell(evidence, root: root),
      _checkResultCell(evidence),
      _actorCell(event == null ? _initiator(root) : _executor(event),
          evidence[event == null ? 'initiator_id' : 'executor_id']),
      _recipientCell(root),
      _cell(
          '${_value(evidence['target_type'])}\n${_value(evidence['target_id'])}'),
      _cell(_value(evidence['source'])),
      _statusCell(evidence['status']),
      _cell(_value(evidence['reason_code']), code: true),
      _cell(event?['attempt'] == null ? '-' : 'ניסיון ${event!['attempt']}'),
      _cell(event == null ? '-' : _elapsedFromRoot(root, event)),
      _rowActions(evidence, operation: event == null),
    ], _operationWidths,
        key: ValueKey(first
            ? 'system-audit-operation-$id'
            : 'system-audit-event-${event!['id']}'),
        groupColor: _operationColor(id),
        child: !first);
  }

  Widget _operationTable() => Column(children: [
        _grid([
          _cell(''),
          for (final entry in _operationColumns)
            _columnHeader(entry.title, entry.columns),
          _cell('פרטים')
        ], _operationWidths, header: true),
        for (final root in _rows) ...[
          _stepRow(_firstStep(root), root, first: true),
          if (_expanded.contains(root['id'].toString())) ..._inlineEvents(root),
        ],
      ]);

  Widget _checkCell(Map<String, dynamic> row, {Map<String, dynamic>? root}) {
    final owner = root?.containsKey('operationPreview') == true ? root! : row;
    final representative = owner['operationPreview'];
    final preview = owner.containsKey('operationPreview')
        ? <String, dynamic>{
            if (representative is Map) ...{
              'checkPreviewUrl': representative['url'],
              'checkPreviewFullUrl': representative['fullUrl'],
            },
          }
        : row;
    final label = _checkLabel(row) ?? '-';
    final contextLabel = _checkContext(row);
    return Tooltip(
      key: ValueKey('system-audit-check-${row['id']}'),
      message: contextLabel.isEmpty ? label : '$label\n$contextLabel',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_recordedLabel(preview['checkPreviewUrl']) != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _AuditCheckThumbnail(
                  key: ValueKey('system-audit-preview-${row['id']}'),
                  url: preview['checkPreviewUrl'].toString(),
                  generation: _previewGeneration,
                  verticalScroll: _scroll,
                  viewportKey: _viewportKey,
                  load: () =>
                      _loadPreview(preview['checkPreviewUrl'].toString()),
                  open: _recordedLabel(preview['checkPreviewFullUrl']) == null
                      ? null
                      : () => _showCheckPreview(preview),
                ),
              ),
            Text(label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
            if (contextLabel.isNotEmpty)
              Text(contextLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }

  Widget _checkResultCell(Map<String, dynamic> row) => KeyedSubtree(
        key: ValueKey('system-audit-check-result-${row['id']}'),
        child: _cell(_checkResultLabel(row)),
      );

  Future<Uint8List?> _loadPreview(String path) {
    final base = Uri.parse(widget.api);
    final relative = Uri.tryParse(path);
    if (relative == null) return Future.value(null);
    var uri = base.resolveUri(relative);
    if (!relative.hasScheme &&
        !relative.hasAuthority &&
        relative.path.startsWith('/api/admin/audit/')) {
      uri = base.replace(
          path: '${base.path}${relative.path.substring(4)}',
          query: relative.query);
    }
    if (uri.scheme != base.scheme ||
        uri.host != base.host ||
        uri.port != base.port ||
        !uri.path.startsWith('${base.path}/admin/audit/events/') ||
        !RegExp(r'/events/[0-9]+/preview$').hasMatch(uri.path)) {
      return Future.value(null);
    }
    uri = uri.replace(queryParameters: {
      'size': uri.queryParameters['size'] == 'full' ? 'full' : 'thumb',
    });
    final cacheKey = uri.toString();
    final cached = _previewLoads[cacheKey];
    if (cached != null) return cached;
    final headers = _headers;
    final future = () async {
      try {
        final response = await http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200 ||
            response.headers['content-type']?.startsWith('image/') != true ||
            response.bodyBytes.isEmpty ||
            response.bodyBytes.length > 8 * 1024 * 1024) {
          return null;
        }
        return response.bodyBytes;
      } catch (_) {
        return null;
      }
    }();
    if (_previewLoads.length >= 64) {
      _previewLoads.remove(_previewLoads.keys.first);
    }
    _previewLoads[cacheKey] = future;
    return future;
  }

  Future<void> _showCheckPreview(Map<String, dynamic> row) async {
    final path = _recordedLabel(row['checkPreviewFullUrl']);
    if (path == null) return;
    _openDialog();
    final image = _loadPreview(path);
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          _previewDialogContext = dialogContext;
          return _AuditCheckPreviewDialog(image: image);
        },
      );
    } finally {
      _previewDialogContext = null;
      _closeDialog();
    }
  }

  Widget _actionCell(Map<String, dynamic> row, {bool child = false}) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(child ? 22 : 10, 12, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(child ? _actionLabel(row['kind']) : _operationLabel(row),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: child ? FontWeight.normal : FontWeight.w600)),
            if (!child)
              Tooltip(
                message: row['id'].toString(),
                child: Text('ID ${_shortId(row['id'])}',
                    textDirection: TextDirection.ltr,
                    style: Theme.of(context).textTheme.labelSmall),
              ),
          ],
        ),
      );

  Widget _recipientCell(Map<String, dynamic> row) {
    final id = row['recipient_id']?.toString();
    if (id == null || id.isEmpty) return _cell('-');
    final name = row['recipient_name']?.toString().trim();
    final type = switch (row['recipient_type']) {
      'user' => 'משתמש',
      'group' => 'קבוצה',
      _ => 'נמען',
    };
    final shortId = row['recipient_short_id'];
    final identity = shortId == null ? _shortId(id) : shortId.toString();
    return Tooltip(
      message: 'נמען מיועד: ${name?.isNotEmpty == true ? name : type}\nID $id',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name?.isNotEmpty == true ? name! : type,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
            Text('מיועד ל$type · ID $identity',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }

  Widget _actorCell(String label, Object? id) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            if (id != null)
              Tooltip(
                message: id.toString(),
                child: Text('ID ${_shortId(id)}',
                    textDirection: TextDirection.ltr,
                    style: Theme.of(context).textTheme.labelSmall),
              ),
          ],
        ),
      );

  Widget _statusCell(Object? status) {
    final (icon, color) = switch (status) {
      'failed' || 'blocked' || 'rejected' => (
          Icons.error_outline,
          Theme.of(context).colorScheme.error
        ),
      'completed' ||
      'succeeded' ||
      'approved' ||
      'stored' ||
      'persisted' ||
      'delivered' ||
      'read' =>
        (Icons.check_circle_outline, Colors.teal),
      'running' => (Icons.sync, Theme.of(context).colorScheme.primary),
      'queued' || 'pending' => (Icons.schedule, Colors.deepOrange),
      _ => (Icons.info_outline, Theme.of(context).colorScheme.onSurfaceVariant),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      child: Row(children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 5),
        Expanded(
            child: Text(_statusText(status),
                style: const TextStyle(fontSize: 12))),
      ]),
    );
  }

  List<Widget> _inlineEvents(Map<String, dynamic> operation) {
    final id = operation['id'].toString();
    final page = _eventPages[id];
    if (page == null) return [];
    final color = _operationColor(id);
    final events = page.rows
        .where((event) =>
            operation['root_event_id'] == null ||
            event['id'].toString() != operation['root_event_id'].toString())
        .toList()
      ..sort(_compareChronologically);
    return [
      for (final event in events)
        if (event['id'].toString() != _firstStep(operation)?['id'].toString())
          _stepRow(event, operation),
      DecoratedBox(
          decoration: BoxDecoration(
              color: color.withValues(alpha: .035),
              border: Border(right: BorderSide(color: color, width: 4))),
          child: Column(children: [
            if (page.loading) const LinearProgressIndicator(),
            if (page.loaded &&
                events.isEmpty &&
                _firstStep(operation) == null &&
                !page.loading)
              const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('אין פעולות משנה מתועדות')),
            if (page.error != null)
              _errorRow(
                  page.error!,
                  () => _loadEvents(id, more: page.failedMore),
                  'system-audit-event-retry-$id'),
            if (page.cursor != null)
              TextButton.icon(
                  key: ValueKey('system-audit-events-more-$id'),
                  onPressed:
                      page.loading ? null : () => _loadEvents(id, more: true),
                  icon: const Icon(Icons.history),
                  label: const Text('פעולות משנה קודמות')),
          ])),
    ];
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('יומן פעולות מערכת'), actions: [
            IconButton(
                key: const ValueKey('system-audit-export'),
                tooltip: 'ייצוא CSV',
                onPressed: _exporting || _deleting ? null : _export,
                icon: const Icon(Icons.download)),
            IconButton(
                key: const ValueKey('system-audit-refresh'),
                tooltip: 'רענן יומן',
                onPressed: _deleting
                    ? null
                    : () {
                        unawaited(_catalog());
                        unawaited(_load());
                      },
                icon: const Icon(Icons.refresh)),
          ]),
          body: AbsorbPointer(
              absorbing: _deleting,
              child: Column(children: [
                _filtersPanel(),
                if (_catalogError != null)
                  _errorRow(_catalogError!, () => _catalog(),
                      'system-audit-catalog-retry'),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(
                                value: false,
                                label: Text('פעולות'),
                                icon: Icon(Icons.account_tree_outlined)),
                            ButtonSegment(
                                value: true,
                                label: Text('כל האירועים'),
                                icon: Icon(Icons.table_rows_outlined)),
                          ],
                          selected: {
                            _eventsMode
                          },
                          onSelectionChanged: (values) {
                            setState(() => _eventsMode = values.single);
                            unawaited(_load());
                          }),
                      if (_canDelete) ...[
                        TextButton(
                            key: const ValueKey('system-audit-select-visible'),
                            onPressed: _deleteBlocked ? null : _selectVisible,
                            child: const Text('סמן מוצגות')),
                        TextButton(
                            onPressed: () => setState(_selected.clear),
                            child: const Text('נקה סימון')),
                        TextButton(
                            key: const ValueKey('system-audit-delete-selected'),
                            onPressed: _deleteBlocked || _selected.isEmpty
                                ? null
                                : () => _deleteBulk(false),
                            child: Text('מחק מסומנות (${_selected.length})')),
                        TextButton(
                            key: const ValueKey('system-audit-delete-all'),
                            onPressed:
                                _deleteBlocked ? null : () => _deleteBulk(true),
                            child: const Text('מחק את כל היומן')),
                      ],
                      Text('${_rows.length} רשומות',
                          style: Theme.of(context).textTheme.bodySmall),
                      if (!_eventsMode && _expanded.isNotEmpty)
                        IconButton(
                            key: const ValueKey('system-audit-collapse-all'),
                            tooltip: 'כווץ את כל הפעולות',
                            onPressed: () {
                              _invalidateRefresh();
                              setState(_expanded.clear);
                              _scheduleRefresh();
                            },
                            icon: const Icon(Icons.unfold_less)),
                      if (_activeColumns.isNotEmpty)
                        IconButton(
                          key: const ValueKey('system-audit-clear-columns'),
                          tooltip:
                              'נקה מסנני עמודות (${_activeColumns.length})',
                          icon: const Icon(Icons.filter_alt_off),
                          onPressed: () {
                            setState(() => _activeColumns.clear());
                            unawaited(_load());
                          },
                        ),
                      if (_startedAt != null)
                        Text('תחילת תיעוד: ${_localTime(_startedAt)}',
                            style: Theme.of(context).textTheme.bodySmall),
                      if (_coverage != null)
                        IconButton(
                            tooltip: 'היקף התיעוד',
                            icon: const Icon(Icons.info_outline),
                            onPressed: () => _details({
                                  'coverage': _coverage,
                                  'recordingStartedAt': _startedAt
                                })),
                    ],
                  ),
                ),
                if (_loading || _exporting || (_deleting && _dialogs == 0))
                  const LinearProgressIndicator(),
                if (_deleteError != null)
                  _errorRow(_deleteError!, () {
                    setState(() => _deleteError = null);
                    unawaited(_refresh());
                  }, 'system-audit-delete-refresh'),
                if (_refreshError != null)
                  _errorRow(_refreshError!, () => _refresh(),
                      'system-audit-auto-retry'),
                Expanded(
                    child: SizedBox(
                        key: _viewportKey,
                        child: SingleChildScrollView(
                          controller: _scroll,
                          key: const ValueKey('system-audit-vertical-scroll'),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    key: const ValueKey(
                                        'system-audit-table-scroll'),
                                    child: SizedBox(
                                        width: (_eventsMode
                                                ? _eventWidths
                                                : _operationWidths)
                                            .reduce((a, b) => a + b),
                                        child: _eventsMode
                                            ? _eventTable(_rows,
                                                filterable: true)
                                            : _operationTable())),
                                if (_rows.isEmpty &&
                                    !_loading &&
                                    _error == null)
                                  const Padding(
                                      padding: EdgeInsets.all(32),
                                      child: Text('אין רשומות בטווח שנבחר',
                                          textAlign: TextAlign.center)),
                                if (_error != null)
                                  _errorRow(
                                      _error!,
                                      () => _load(more: _failedMore),
                                      'system-audit-retry'),
                                if (_cursor != null)
                                  TextButton.icon(
                                      key: const ValueKey('system-audit-more'),
                                      onPressed: _loading
                                          ? null
                                          : () => _load(more: true),
                                      icon: const Icon(Icons.expand_more),
                                      label: const Text('רשומות נוספות')),
                              ]),
                        ))),
              ])),
        ),
      );
}

class _AuditCheckThumbnail extends StatefulWidget {
  const _AuditCheckThumbnail({
    super.key,
    required this.url,
    required this.generation,
    required this.verticalScroll,
    required this.viewportKey,
    required this.load,
    required this.open,
  });

  final String url;
  final int generation;
  final ScrollController verticalScroll;
  final GlobalKey viewportKey;
  final Future<Uint8List?> Function() load;
  final VoidCallback? open;

  @override
  State<_AuditCheckThumbnail> createState() => _AuditCheckThumbnailState();
}

class _AuditCheckThumbnailState extends State<_AuditCheckThumbnail> {
  Future<Uint8List?>? _image;
  ScrollPosition? _horizontalScroll;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    widget.verticalScroll.addListener(_observeVisibility);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _horizontalScroll?.removeListener(_observeVisibility);
    _horizontalScroll = Scrollable.maybeOf(context)?.position;
    _horizontalScroll?.addListener(_observeVisibility);
    _observeVisibility();
  }

  @override
  void didUpdateWidget(covariant _AuditCheckThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.generation != widget.generation) {
      _image = null;
    }
    if (oldWidget.verticalScroll != widget.verticalScroll) {
      oldWidget.verticalScroll.removeListener(_observeVisibility);
      widget.verticalScroll.addListener(_observeVisibility);
    }
    _observeVisibility();
  }

  void _observeVisibility() {
    if (_image != null || _scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted ||
          _image != null ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      final box = context.findRenderObject();
      final viewport = widget.viewportKey.currentContext?.findRenderObject();
      if (box is! RenderBox ||
          !box.hasSize ||
          !box.attached ||
          viewport is! RenderBox ||
          !viewport.hasSize) {
        return;
      }
      final bounds = box.localToGlobal(Offset.zero) & box.size;
      final visible = viewport.localToGlobal(Offset.zero) & viewport.size;
      if (bounds.overlaps(visible)) {
        final image = widget.load();
        setState(() {
          _image = image;
        });
      }
    });
  }

  @override
  void dispose() {
    widget.verticalScroll.removeListener(_observeVisibility);
    _horizontalScroll?.removeListener(_observeVisibility);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _observeVisibility();
    return SizedBox(
      width: 56,
      height: 42,
      child: FutureBuilder<Uint8List?>(
        future: _image,
        builder: (context, snapshot) {
          if (_image == null) return const SizedBox.shrink();
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)));
          }
          final bytes = snapshot.data;
          if (bytes == null) {
            return const Tooltip(
                message: 'התמונה אינה זמינה',
                child: Icon(Icons.image_not_supported_outlined, size: 20));
          }
          return Tooltip(
            message: 'הגדל את התמונה שנבדקה',
            child: InkWell(
              onTap: widget.open,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  semanticLabel: 'התמונה שנבדקה',
                  errorBuilder: (_, __, ___) => const Tooltip(
                      message: 'התמונה אינה זמינה',
                      child:
                          Icon(Icons.image_not_supported_outlined, size: 20)),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AuditCheckPreviewDialog extends StatelessWidget {
  const _AuditCheckPreviewDialog({required this.image});

  final Future<Uint8List?> image;

  @override
  Widget build(BuildContext context) => Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        key: const ValueKey('system-audit-preview-dialog'),
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(
          width: 960,
          height: (MediaQuery.sizeOf(context).height - 80)
              .clamp(0.0, 800.0)
              .toDouble(),
          child: Column(children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
              child: Row(children: [
                const Expanded(
                    child: Text('התמונה שנבדקה',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600))),
                IconButton(
                  key: const ValueKey('system-audit-preview-close'),
                  tooltip: 'סגור',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ]),
            ),
            Expanded(
                child: FutureBuilder<Uint8List?>(
              future: image,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final bytes = snapshot.data;
                if (bytes == null) {
                  return const Center(child: Text('התמונה אינה זמינה'));
                }
                return InteractiveViewer(
                  key: const ValueKey('system-audit-preview-zoom'),
                  minScale: 1,
                  maxScale: 5,
                  child: SizedBox.expand(
                      child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    semanticLabel: 'התמונה שנבדקה',
                    errorBuilder: (_, __, ___) =>
                        const Center(child: Text('התמונה אינה זמינה')),
                  )),
                );
              },
            )),
          ]),
        ),
      ));
}

enum _ColumnKind { choices, date, number }

class _AuditColumn {
  const _AuditColumn(this.id, this.label, [this.kind = _ColumnKind.choices]);
  final String id;
  final String label;
  final _ColumnKind kind;
}

const _createdColumn =
    _AuditColumn('created_at', 'זמן מקומי', _ColumnKind.date);
const _targetColumns = [
  _AuditColumn('target_type', 'סוג יעד'),
  _AuditColumn('target_id', 'מזהה יעד'),
];
const _recipientColumns = [
  _AuditColumn('recipient_id', 'נמען / קבוצה'),
  _AuditColumn('recipient_type', 'סוג נמען'),
];
const _checkColumns = [
  (title: 'מה נבדק', columns: [_AuditColumn('check_type', 'מה נבדק')]),
  (
    title: 'תוצאת הבדיקה',
    columns: [_AuditColumn('check_outcome', 'תוצאת הבדיקה')]
  ),
];
const _operationColumns = [
  (title: 'זמן מקומי', columns: [_createdColumn]),
  (
    title: 'פעולה',
    columns: [
      _AuditColumn('action', 'פעולה'),
      _AuditColumn('media_type', 'סוג מדיה'),
      _AuditColumn('capture_kind', 'מקור צילום / הקלטה'),
    ]
  ),
  (title: 'פעולת משנה', columns: [_AuditColumn('kind', 'פעולת משנה')]),
  ..._checkColumns,
  (title: 'יוזם / מבצע', columns: [_AuditColumn('initiator_id', 'יוזם')]),
  (title: 'נמען / קבוצה', columns: _recipientColumns),
  (title: 'יעד', columns: _targetColumns),
  (title: 'מקור', columns: [_AuditColumn('source', 'מקור')]),
  (title: 'מצב', columns: [_AuditColumn('status', 'מצב')]),
  (title: 'סיבה', columns: [_AuditColumn('reason_code', 'סיבה')]),
  (
    title: 'תיעוד / ניסיון',
    columns: [_AuditColumn('event_count', 'מספר אירועים', _ColumnKind.number)]
  ),
  (
    title: 'זמנים',
    columns: [
      _AuditColumn(
          'duration_ms', 'טווח האירועים (אלפיות שנייה)', _ColumnKind.number)
    ]
  ),
];
const _eventColumns = [
  (title: 'זמן מקומי', columns: [_createdColumn]),
  (title: 'אירוע', columns: [_AuditColumn('kind', 'אירוע')]),
  ..._checkColumns,
  (title: 'מבצע', columns: [_AuditColumn('executor_id', 'מבצע')]),
  (title: 'נמען / קבוצה', columns: _recipientColumns),
  (title: 'מקור', columns: [_AuditColumn('source', 'מקור')]),
  (title: 'מצב', columns: [_AuditColumn('status', 'מצב')]),
  (title: 'יעד', columns: _targetColumns),
  (title: 'סיבה', columns: [_AuditColumn('reason_code', 'סיבה')]),
  (
    title: 'ניסיון',
    columns: [_AuditColumn('attempt', 'ניסיון', _ColumnKind.number)]
  ),
  (
    title: 'פעולה / אירוע קודם',
    columns: [
      _AuditColumn('operation_id', 'מזהה פעולה'),
      _AuditColumn('parent_event_id', 'מזהה אירוע קודם'),
    ]
  ),
];

class _ColumnFilterResult {
  const _ColumnFilterResult(this.column, this.filter);
  final String column;
  final Map<String, dynamic>? filter;
}

class _ColumnFilterDialog extends StatefulWidget {
  const _ColumnFilterDialog({
    required this.columns,
    required this.filters,
    required this.loadOptions,
    required this.isCurrent,
  });
  final List<_AuditColumn> columns;
  final Map<String, Map<String, dynamic>> filters;
  final Future<Map<String, dynamic>> Function(String column, String search)
      loadOptions;
  final bool Function() isCurrent;

  @override
  State<_ColumnFilterDialog> createState() => _ColumnFilterDialogState();
}

class _ColumnFilterDialogState extends State<_ColumnFilterDialog> {
  final _search = TextEditingController();
  final _lower = TextEditingController();
  final _upper = TextEditingController();
  late _AuditColumn _column;
  Set<String?> _values = {};
  List<Map<String, dynamic>> _options = [];
  bool _exclude = true;
  bool _loading = false;
  bool _hasMore = false;
  String? _error;
  String? _validation;
  int _request = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _setColumn(widget.columns.firstWhere(
      (column) => widget.filters.containsKey(column.id),
      orElse: () => widget.columns.first,
    ));
  }

  void _setColumn(_AuditColumn column) {
    _debounce?.cancel();
    _request++;
    _column = column;
    final filter = widget.filters[column.id] ?? {};
    _search.clear();
    _values = (filter['values'] as List? ?? [])
        .map((value) => value?.toString())
        .toSet();
    _exclude = filter['exclude'] != false;
    String dateValue(Object? raw) =>
        DateTime.tryParse(raw?.toString() ?? '')
            ?.toLocal()
            .toIso8601String()
            .replaceFirst('T', ' ') ??
        '';
    _lower.text = column.kind == _ColumnKind.date
        ? dateValue(filter['from'])
        : filter['min']?.toString() ?? '';
    _upper.text = column.kind == _ColumnKind.date
        ? dateValue(filter['to'])
        : filter['max']?.toString() ?? '';
    _error = null;
    _validation = null;
    _options = [];
    _hasMore = false;
    _loading = false;
    if (column.kind == _ColumnKind.choices) unawaited(_loadOptions());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _request++;
    _search.dispose();
    _lower.dispose();
    _upper.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.loadOptions(_column.id, _search.text.trim());
      if (data['options'] is! List) throw const FormatException();
      if (!mounted || request != _request) return;
      if (!widget.isCurrent()) throw 'היומן השתנה. פתח שוב את המסנן';
      setState(() {
        _options = _maps(data['options']);
        _hasMore = data['hasMore'] == true;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _error = _errorText(error);
      });
    }
  }

  void _searchChanged(String value) {
    _debounce?.cancel();
    _request++;
    setState(() {
      _loading = true;
      _error = null;
      _options = [];
    });
    _debounce = Timer(const Duration(milliseconds: 250), _loadOptions);
  }

  void _toggle(String? value) {
    setState(() {
      _validation = null;
      if (_values.contains(value)) {
        _values.remove(value);
      } else if (_values.length < 100) {
        _values.add(value);
      } else {
        _validation = 'ניתן לבחור או להחריג עד 100 ערכים';
      }
    });
  }

  DateTime? _parseDate(String text) {
    final parts = RegExp(
            r'^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?)?$')
        .firstMatch(text);
    if (parts == null) return null;
    int part(int index) => int.parse(parts[index] ?? '0');
    final millisecond = int.parse((parts[7] ?? '').padRight(3, '0'));
    final parsed = DateTime(
        part(1), part(2), part(3), part(4), part(5), part(6), millisecond);
    if (parsed.year != part(1) ||
        parsed.month != part(2) ||
        parsed.day != part(3) ||
        parsed.hour != part(4) ||
        parsed.minute != part(5) ||
        parsed.second != part(6)) {
      return null;
    }
    return parsed;
  }

  void _finish({bool clear = false}) {
    if (!widget.isCurrent()) {
      setState(() => _validation = 'היומן השתנה. פתח שוב את המסנן');
      return;
    }
    Map<String, dynamic>? filter;
    String? error;
    if (!clear) {
      switch (_column.kind) {
        case _ColumnKind.choices:
          if (_loading || _error != null) return;
          if (!_exclude || _values.isNotEmpty) {
            filter = {'values': _values.toList(), 'exclude': _exclude};
          }
        case _ColumnKind.date:
          final lower = _lower.text.trim();
          final upper = _upper.text.trim();
          final from = lower.isEmpty ? null : _parseDate(lower);
          final to = upper.isEmpty ? null : _parseDate(upper);
          if ((lower.isNotEmpty && from == null) ||
              (upper.isNotEmpty && to == null)) {
            error = 'יש להזין תאריך ושעה תקינים';
          } else if (from != null && to != null && !to.isAfter(from)) {
            error = 'סוף הטווח חייב להיות מאוחר מתחילתו';
          } else if (from != null || to != null) {
            filter = {
              if (from != null) 'from': from.toUtc().toIso8601String(),
              if (to != null) 'to': to.toUtc().toIso8601String(),
            };
          }
        case _ColumnKind.number:
          final lower = _lower.text.trim();
          final upper = _upper.text.trim();
          final valid = RegExp(r'^\d+$');
          final min = BigInt.tryParse(lower);
          final max = BigInt.tryParse(upper);
          final limit = BigInt.parse('9223372036854775807');
          if ((lower.isNotEmpty &&
                  (!valid.hasMatch(lower) || min == null || min > limit)) ||
              (upper.isNotEmpty &&
                  (!valid.hasMatch(upper) || max == null || max > limit))) {
            error = 'יש להזין מספרים שלמים בטווח תקין';
          } else if (min != null && max != null && min > max) {
            error = 'הערך המרבי חייב להיות גדול או שווה לערך המזערי';
          } else if (min != null || max != null) {
            filter = {
              if (min != null) 'min': min.toString(),
              if (max != null) 'max': max.toString(),
            };
          }
      }
    }
    if (error != null) {
      setState(() => _validation = error);
      return;
    }
    Navigator.pop(context, _ColumnFilterResult(_column.id, filter));
  }

  Widget _bounds() => Column(mainAxisSize: MainAxisSize.min, children: [
        for (final lower in [true, false])
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextField(
              key: ValueKey('system-audit-column-${lower ? 'min' : 'max'}'),
              controller: lower ? _lower : _upper,
              textDirection: TextDirection.ltr,
              keyboardType: _column.kind == _ColumnKind.number
                  ? TextInputType.number
                  : TextInputType.datetime,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: _column.kind == _ColumnKind.number
                    ? (lower ? 'ערך מזערי (כולל)' : 'ערך מרבי (כולל)')
                    : (lower
                        ? 'מתאריך ושעה (כולל)'
                        : 'עד תאריך ושעה (לא כולל)'),
                hintText: _column.kind == _ColumnKind.date
                    ? 'YYYY-MM-DD HH:mm:ss.SSS'
                    : null,
              ),
              onChanged: (_) => setState(() => _validation = null),
            ),
          ),
      ]);

  Widget _choices() => Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          key: const ValueKey('system-audit-column-search'),
          controller: _search,
          decoration: const InputDecoration(
            labelText: 'חיפוש ערכים',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
          onChanged: _searchChanged,
        ),
        CheckboxListTile(
          key: const ValueKey('system-audit-column-all'),
          contentPadding: EdgeInsets.zero,
          title: const Text('הכול'),
          subtitle: Text(_exclude
              ? (_values.isEmpty ? 'כל הערכים' : 'הכול, למעט ${_values.length}')
              : '${_values.length} ערכים נבחרו'),
          tristate: true,
          value: _values.isEmpty ? _exclude : null,
          onChanged: (_) => setState(() {
            _exclude = !(_exclude && _values.isEmpty);
            _values.clear();
            _validation = null;
          }),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Row(children: [
            Expanded(child: Text(_error!)),
            IconButton(
              key: const ValueKey('system-audit-column-retry'),
              tooltip: 'נסה שוב',
              onPressed: _loadOptions,
              icon: const Icon(Icons.refresh),
            ),
          ])
        else if (!_loading && _options.isEmpty)
          const Padding(padding: EdgeInsets.all(12), child: Text('אין ערכים')),
        if (!_loading && _error == null)
          for (var index = 0; index < _options.length; index++)
            CheckboxListTile(
              key: ValueKey('system-audit-column-option-$index'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(_options[index]['label']?.toString() ??
                  _options[index]['value']?.toString() ??
                  '(ריק)'),
              value: _exclude
                  ? !_values.contains(_options[index]['value']?.toString())
                  : _values.contains(_options[index]['value']?.toString()),
              onChanged: (_) => _toggle(_options[index]['value']?.toString()),
            ),
        if (_hasMore && !_loading && _error == null)
          const Padding(
              padding: EdgeInsets.all(8), child: Text('קיימים ערכים נוספים')),
      ]);

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          key: const ValueKey('system-audit-column-dialog'),
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          title: Text('סינון ${_column.label}'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.columns.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey('system-audit-column-field'),
                      initialValue: _column.id,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'שדה'),
                      items: [
                        for (final column in widget.columns)
                          DropdownMenuItem(
                              value: column.id, child: Text(column.label))
                      ],
                      onChanged: (value) => setState(() => _setColumn(widget
                          .columns
                          .firstWhere((column) => column.id == value))),
                    ),
                  ),
                _column.kind == _ColumnKind.choices ? _choices() : _bounds(),
                if (_validation != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_validation!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
              ],
            )),
          ),
          actions: [
            TextButton.icon(
              key: const ValueKey('system-audit-column-clear'),
              onPressed: () => _finish(clear: true),
              icon: const Icon(Icons.filter_alt_off, size: 18),
              label: Text(widget.columns.length > 1 ? 'נקה שדה' : 'נקה מסנן'),
            ),
            TextButton(
              key: const ValueKey('system-audit-column-cancel'),
              onPressed: () => Navigator.pop(context),
              child: const Text('ביטול'),
            ),
            FilledButton(
              key: const ValueKey('system-audit-column-apply'),
              onPressed: _loading || _error != null ? null : _finish,
              child: const Text('החל'),
            ),
          ],
        ),
      );
}

const _operationWidths = [
  48.0,
  178.0,
  190.0,
  220.0,
  230.0,
  210.0,
  170.0,
  195.0,
  190.0,
  110.0,
  110.0,
  130.0,
  210.0,
  160.0,
  192.0
];
const _eventWidths = [
  178.0,
  185.0,
  230.0,
  210.0,
  175.0,
  195.0,
  110.0,
  110.0,
  185.0,
  130.0,
  100.0,
  153.0,
  192.0
];
const _statusLabels = {
  'accepted': 'התקבל',
  'queued': 'בתור',
  'running': 'בעיבוד',
  'pending': 'ממתין',
  'stored': 'נשמר בשרת',
  'persisted': 'נשמר בשרת',
  'completed': 'הושלם',
  'succeeded': 'הצליח',
  'cancelled': 'בוטל',
  'partial': 'הושלם חלקית',
  'observed': 'תועד',
  'approved': 'אושר',
  'delivered': 'נמסר',
  'read': 'נקרא',
  'failed': 'נכשל',
  'blocked': 'נחסם',
  'rejected': 'נדחה',
  'skipped': 'דולג',
  'unknown': 'לא ידוע',
};
const _kindLabels = {
  'message_persisted': 'הודעה נשמרה בשרת',
  'delivery_persisted': 'הודעה נשמרה בשרת',
  'operation_started': 'הפעולה החלה',
  'operation_completed': 'הפעולה הושלמה',
  'operation_failed': 'הפעולה נכשלה',
  'client_displayed': 'דיווח תצוגה מהמכשיר',
  'media_stored': 'מדיה נשמרה בשרת',
  'upload_context': 'פרטי המדיה והנמען',
  'blob_upload_started': 'תחילת העלאה לאחסון',
  'blob_upload_finished': 'העלאה לאחסון הסתיימה',
  'media_moderation_changed': 'מצב סינון המדיה עודכן',
  'scan_queued': 'סריקה נוספה לתור',
  'scan_attempt_started': 'ניסיון סריקה החל',
  'scan_waiting': 'סריקה ממתינה',
  'scan_attempt_failed': 'ניסיון סריקה נכשל',
  'scan_workflow_finished': 'תהליך הסריקה הסתיים',
  'scan_queue_removed': 'רשומת הסריקה הוסרה מהתור',
  'http_response': 'תגובת שרת לבקשה',
  'http_connection_closed': 'חיבור הבקשה נסגר',
  'provider_call_finished': 'קריאה לספק הסתיימה',
  'moderation_check_finished': 'בדיקת תוכן הסתיימה',
  'scan_cache_used': 'תוצאת סריקה מהמטמון',
  'push_provider_result': 'תשובת ספק ההתראות',
  'push_skipped': 'שליחת התראה דולגה',
  'message_retry_reused': 'ניסיון חוזר השתמש בהודעה קיימת',
  'server_message_status_changed': 'מצב הודעה בשרת עודכן',
  'message_delivery_state_changed': 'מצב מסירת הודעה עודכן',
  'contact_request_pending': 'בקשת קשר ממתינה',
  'contact_request_status_changed': 'מצב בקשת קשר עודכן',
};

String _value(Object? value) =>
    value?.toString().isNotEmpty == true ? value.toString() : '-';

const _checkTypeLabels = {
  'safe_search': 'תוכן למבוגרים, חשיפה, אלימות, רפואה וזיוף',
  'object_localization': 'איתור אנשים באמצעות זיהוי אובייקטים',
  'face_detection': 'איתור וספירת פנים',
  'person_presence': 'אימות נוכחות אנשים וסיווג גברים, נשים וילדים',
  'modesty': 'בדיקת צניעות הלבוש',
  'modesty_format_repair': 'פענוח חוזר של תשובת בדיקת הצניעות',
  'local_safety': 'בדיקת בטיחות מקומית להשוואה',
  'local_explicit_content': 'בדיקה מקומית של עירום ותוכן מיני מפורש',
  'local_classification': 'סיווג מקומי של אנשים וסוג התמונה',
  'video_frames': 'בדיקת התמונות שנדגמו מהסרטון',
  'audio_transcription': 'פענוח הדיבור ובדיקת תוכן ההקלטה',
  'document_content': 'בדיקת הטקסט והתמונות במסמך',
  'media_moderation': 'בדיקת תוכן הקובץ',
};
const _checkOutcomeLabels = {
  'passed': 'הבדיקה הושלמה',
  'blocked': 'נמצא ממצא לחסימה',
  'uncertain': 'תוצאה לא ודאית',
  'failed': 'הבדיקה נכשלה',
  'stopped': 'הבדיקה נעצרה',
  'skipped': 'הבדיקה לא בוצעה',
  'not_recorded': 'תוצאה לא תועדה',
};

Map _checkDetails(Map<String, dynamic> row) =>
    row['details'] is Map ? row['details'] as Map : const {};

String? _recordedLabel(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return value.trim();
}

String? _checkLabel(Map<String, dynamic> row) {
  final label = _recordedLabel(row['checkLabel']);
  if (label != null) return label;
  final details = _checkDetails(row);
  final type = details['checkType'];
  if (_checkTypeLabels.containsKey(type)) return _checkTypeLabels[type];
  if (const [
    'provider_call_finished',
    'scan_cache_used',
    'moderation_check_finished'
  ].contains(row['kind'])) {
    const legacyTypes = {
      'safe_search': 'safe_search',
      'google_safe_search_reuse': 'safe_search',
      'object_localization': 'object_localization',
      'face_detection': 'face_detection',
      'person_presence': 'person_presence',
      'modesty': 'modesty',
      'modesty_format_repair': 'modesty_format_repair',
    };
    return _checkTypeLabels[legacyTypes[details['operation']]];
  }
  return null;
}

String _checkResultLabel(Map<String, dynamic> row) {
  final label = _recordedLabel(row['checkResultLabel']);
  if (label != null) return label;
  final outcome = _checkDetails(row)['checkOutcome'];
  return _checkOutcomeLabels[outcome] ??
      (_checkLabel(row) == null ? '-' : 'תוצאה לא תועדה');
}

String _checkContext(Map<String, dynamic> row) {
  if (_checkLabel(row) == null) return '';
  final details = _checkDetails(row);
  const providers = {
    'google_vision': 'Google Vision',
    'openai': 'OpenAI',
    'gemini': 'Gemini',
  };
  final provider = providers[details['provider']];
  final frameIndex = details['frameIndex'];
  final timestamp = details['frameTimestampMs'];
  return [
    if (provider != null) provider,
    if (frameIndex is int && frameIndex >= 0) 'פריים ${frameIndex + 1}',
    if (timestamp is int && timestamp >= 0)
      '${(timestamp / 1000).toStringAsFixed(3)} שניות',
  ].join(' · ');
}

String _shortId(Object? raw) {
  final id = _value(raw);
  return id.length <= 16
      ? id
      : '${id.substring(0, 8)}...${id.substring(id.length - 4)}';
}

Color _operationColor(String id) {
  var hash = 0;
  for (final unit in id.codeUnits) {
    hash = (hash * 31 + unit) % 65521;
  }
  return HSLColor.fromAHSL(1, (hash * 137.508) % 360, .6, .55).toColor();
}

int _compareChronologically(Map<String, dynamic> a, Map<String, dynamic> b) {
  final aTime = DateTime.tryParse(a['created_at']?.toString() ?? '');
  final bTime = DateTime.tryParse(b['created_at']?.toString() ?? '');
  if (aTime != null && bTime != null) {
    final time = aTime.compareTo(bTime);
    if (time != 0) return time;
  }
  final aId = a['id'].toString();
  final bId = b['id'].toString();
  final aNumber = BigInt.tryParse(aId);
  final bNumber = BigInt.tryParse(bId);
  return aNumber != null && bNumber != null
      ? aNumber.compareTo(bNumber)
      : aId.compareTo(bId);
}

String _elapsedFromRoot(
    Map<String, dynamic> operation, Map<String, dynamic> event) {
  final start = DateTime.tryParse(operation['created_at']?.toString() ?? '');
  final time = DateTime.tryParse(event['created_at']?.toString() ?? '');
  if (start == null || time == null || time.isBefore(start)) return '-';
  final elapsed = time.difference(start).inMilliseconds;
  return 'מתחילת הפעולה: $elapsed ms';
}

String? _cursorValue(Object? value) =>
    value == null || value.toString().isEmpty ? null : value.toString();
List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList()
    : [];
List<String> _codes(Object? value) => value is List
    ? value
        .map((entry) => entry is Map
            ? (entry['code'] ?? entry['status'] ?? entry['category']).toString()
            : entry.toString())
        .toSet()
        .toList()
    : [];
void _append(
    List<Map<String, dynamic>> target, List<Map<String, dynamic>> rows) {
  final ids = target.map((row) => row['id'].toString()).toSet();
  for (final row in rows) {
    if (row['id'] != null && ids.add(row['id'].toString())) target.add(row);
  }
}

String _date(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
String _localTime(Object? raw) {
  final date = DateTime.tryParse(raw?.toString() ?? '')?.toLocal();
  if (date == null) return 'זמן לא ידוע';
  String two(int n) => n.toString().padLeft(2, '0');
  final offset = date.timeZoneOffset.inMinutes;
  final zone =
      '${offset < 0 ? '-' : '+'}${two(offset.abs() ~/ 60)}:${two(offset.abs() % 60)}';
  return '${_date(date)} ${two(date.hour)}:${two(date.minute)}:${two(date.second)}.${date.millisecond.toString().padLeft(3, '0')} UTC$zone';
}

String _initiator(Map<String, dynamic> row) {
  if (row['initiator_id'] != null) {
    return 'משתמש: ${row['initiator_name'] ?? row['initiator_id']}'
        '${row['initiator_short_id'] == null ? '' : ' (#${row['initiator_short_id']})'}';
  }
  return row['initiator_type'] == 'service'
      ? 'שירות: ${_value(row['initiator_name'])}'
      : 'יוזם לא ידוע';
}

String _executor(Map<String, dynamic> row) => switch (row['executor_type']) {
      'user' => 'משתמש: ${row['executor_name'] ?? _value(row['executor_id'])}',
      'admin' => 'מנהל: ${row['executor_name'] ?? _value(row['executor_id'])}',
      'service' ||
      'worker' =>
        'שירות: ${row['executor_name'] ?? _value(row['executor_id'])}',
      'system' =>
        'מערכת: ${row['executor_name'] ?? _value(row['executor_id'])}',
      'provider' =>
        'ספק: ${row['executor_name'] ?? _value(row['executor_id'])}',
      'client' =>
        'מכשיר: ${row['executor_name'] ?? _value(row['executor_id'])}',
      _ => 'מבצע לא ידוע',
    };
String _requestError(int status) => switch (status) {
      401 || 403 => 'אין הרשאה לצפייה ביומן',
      400 => 'המסננים אינם תקינים',
      _ => 'טעינת היומן נכשלה',
    };
String _errorText(Object error) => error is TimeoutException
    ? 'השרת לא השיב בזמן'
    : error is String
        ? error
        : 'טעינת היומן נכשלה';

Object? _safe(Object? value, [int depth = 0]) {
  if (depth > 6) return '[omitted]';
  if (value is Map) {
    return {
      for (final entry in value.entries.take(100))
        entry.key.toString():
            RegExp(r'password|secret|token|authorization|cookie|transcript|encrypted|email|phone|(^|_)(body|text|prompt|payload|url|headers)($|_)',
                        caseSensitive: false)
                    .hasMatch(entry.key.toString())
                ? '[redacted]'
                : _safe(entry.value, depth + 1),
    };
  }
  if (value is List) {
    return value.take(100).map((v) => _safe(v, depth + 1)).toList();
  }
  if (value is String && value.length > 500) {
    return '${value.substring(0, 500)}...';
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  return '[omitted]';
}
