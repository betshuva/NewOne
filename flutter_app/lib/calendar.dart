import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const _blue = Color(0xFF1B6CA8);
const _colors = <String, Color>{
  'blue': _blue,
  'green': Color(0xFF25835B),
  'purple': Color(0xFF8059AA),
  'orange': Color(0xFFB96A16),
  'red': Color(0xFFBA4343)
};
const _weekdays = ['ראשון', 'שני', 'שלישי', 'רביעי', 'חמישי', 'שישי', 'שבת'];
String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _time(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
String _local(DateTime d) => '${_date(d)}T${_time(d)}';
DateTime _day(DateTime d) => DateTime.utc(d.year, d.month, d.day);
DateTime _wall(String value) => DateTime.parse('${value}Z');
String _dayLabel(DateTime d) => '${d.day}/${d.month}/${d.year}';
List<Map<String, dynamic>> _maps(dynamic v) =>
    (v as List? ?? []).map((x) => Map<String, dynamic>.from(x as Map)).toList();

class CalendarApi {
  final String base, token;
  const CalendarApi(this.base, this.token);
  Future<dynamic> call(String path,
      {String method = 'GET', Map<String, dynamic>? body}) async {
    final uri = Uri.parse('$base/calendar/$path');
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json'
    };
    final http.Response r;
    switch (method) {
      case 'POST':
        r = await http
            .post(uri, headers: headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 25));
      case 'PUT':
        r = await http
            .put(uri, headers: headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 25));
      case 'DELETE':
        r = await http
            .delete(uri, headers: headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 25));
      default:
        r = await http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 25));
    }
    final data = jsonDecode(r.body);
    if (r.statusCode >= 400) {
      throw Exception(data is Map ? data['error'] : 'הפעולה נכשלה');
    }
    return data;
  }
}

class CalendarFriendTile extends StatefulWidget {
  final String api, token;
  final bool selected;
  final Future<void> Function() onTap;
  const CalendarFriendTile(
      {super.key,
      required this.api,
      required this.token,
      required this.onTap,
      this.selected = false});
  @override
  State<CalendarFriendTile> createState() => _CalendarFriendTileState();
}

class _CalendarFriendTileState extends State<CalendarFriendTile>
    with WidgetsBindingObserver {
  Timer? _timer;
  String _label = 'אירועים, חגים וזמני שבת';
  int _pending = 0;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _load();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void didUpdateWidget(covariant CalendarFriendTile old) {
    super.didUpdateWidget(old);
    if (old.token != widget.token) {
      _label = 'אירועים, חגים וזמני שבת';
      _pending = 0;
      _load();
    } else if (old.selected != widget.selected) {
      _load();
    }
  }

  Future<void> _load() async {
    if (_busy) return;
    _busy = true;
    final token = widget.token;
    try {
      final b = await CalendarApi(widget.api, token).call('summary');
      if (!mounted || token != widget.token) return;
      final n = b['next'];
      setState(() {
        _pending = (b['pending'] as num?)?.toInt() ?? 0;
        _label = n == null
            ? 'אירועים, חגים וזמני שבת'
            : '${n['title']} · ${_dayLabel(_wall(n['start_local']))} ${n['all_day'] == true ? 'כל היום' : _time(_wall(n['start_local']))}';
      });
    } catch (_) {
    } finally {
      _busy = false;
      if (mounted && token != widget.token) _load();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
      color: widget.selected ? const Color(0xFFDCEFFC) : Colors.white,
      child: ListTile(
        key: const ValueKey('calendar-friend'),
        leading: const CircleAvatar(
            backgroundColor: _blue,
            child: Icon(Icons.calendar_month, color: Colors.white)),
        title: const Text('לוח שנה',
            style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(_label, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: _pending > 0
            ? Badge(
                label: Text('$_pending'),
                child: const Icon(Icons.mail_outline, color: _blue))
            : const Icon(Icons.chevron_right, color: _blue),
        onTap: () async {
          await widget.onTap();
          if (mounted) _load();
        },
      ));
}

class CalendarScreen extends StatefulWidget {
  final String api, token;
  final VoidCallback? onClose;
  const CalendarScreen(
      {super.key, required this.api, required this.token, this.onClose});
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen>
    with WidgetsBindingObserver {
  CalendarApi get api => CalendarApi(widget.api, widget.token);
  Map<String, dynamic>? _settings;
  List<Map<String, dynamic>> _cities = [],
      _events = [],
      _holidays = [],
      _invitations = [],
      _notices = [];
  DateTime _selected = _day(DateTime.now());
  String _view = 'month';
  bool _loading = true, _configured = false;
  String? _error, _holidayError;
  int _generation = 0;
  DateTime _today = _day(DateTime.now());
  Timer? _timer;
  final _hoursScroll = ScrollController(initialScrollOffset: 7 * 60);
  DateTime get _start => _view == 'month'
      ? DateTime.utc(_selected.year, _selected.month, 1).subtract(Duration(
          days: DateTime.utc(_selected.year, _selected.month, 1).weekday % 7))
      : _view == 'week'
          ? _day(_selected).subtract(Duration(days: _selected.weekday % 7))
          : _day(_selected);
  int get _days => _view == 'month'
      ? 42
      : _view == 'week'
          ? 7
          : 1;
  DateTime get _end => _start.add(Duration(days: _days));
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
          !_loading) {
        _load(silent: true);
      }
    });
  }

  @override
  void didUpdateWidget(covariant CalendarScreen old) {
    super.didUpdateWidget(old);
    if (old.token != widget.token) {
      _generation++;
      _events = [];
      _holidays = [];
      _invitations = [];
      _notices = [];
      _settings = null;
      _init();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _load(silent: true);
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _hoursScroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _message(Object e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> _init() async {
    final token = widget.token;
    try {
      final b = await api.call('settings');
      if (!mounted || token != widget.token) return;
      setState(() {
        final firstLoad = _settings == null;
        _settings = Map<String, dynamic>.from(b['settings']);
        _today = _day(DateTime.parse(b['today'] ?? _date(DateTime.now())));
        if (firstLoad) _selected = _today;
        _configured = b['configured'] == true;
        _cities = _maps(b['cities']);
      });
      await _load();
    } catch (e) {
      if (mounted && token == widget.token) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (_settings == null) return;
    final gen = ++_generation;
    final start = _start, end = _end;
    final client = api;
    if (!silent) setState(() => _loading = true);
    try {
      final results = await Future.wait([
        client.call('events?start=${_date(start)}&end=${_date(end)}'),
        client.call('inbox'),
        client
            .call(
                'holidays?start=${_date(start)}&end=${_date(end.subtract(const Duration(days: 1)))}')
            .catchError(
                (Object e) => <String, dynamic>{'items': [], 'failed': true})
      ]);
      if (!mounted || gen != _generation) return;
      setState(() {
        _events = _maps(results[0]['events']);
        _invitations = _maps(results[1]['invitations']);
        _notices = _maps(results[1]['notices']);
        _holidays = _maps(results[2]['items']);
        _holidayError = results[2]['failed'] == true
            ? 'החגים והזמנים אינם זמינים כרגע. אפשר לנסות לרענן.'
            : null;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted && gen == _generation) {
        setState(() {
          _error = 'לא ניתן לטעון את היומן. בדקו את החיבור ונסו שוב.';
          _loading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> _onDay(DateTime d) => _events.where((e) {
        final a = _wall(e['start_local']), b = _wall(e['end_local']);
        return a.isBefore(d.add(const Duration(days: 1))) && b.isAfter(d);
      }).toList();
  List<Map<String, dynamic>> _holidaysOn(DateTime d) => _holidays
      .where((h) =>
          h['date'].toString().startsWith(_date(d)) &&
          h['category'] != 'hebdate')
      .toList();
  String _hebrew(DateTime d) {
    final found = _holidays.where((h) =>
        h['category'] == 'hebdate' &&
        h['date'].toString().startsWith(_date(d)));
    return found.isEmpty ? '' : found.first['title'].toString();
  }

  String _holidayLabel(Map<String, dynamic> h) {
    final raw = h['date'].toString();
    final t = raw.length > 10 ? raw.substring(11, 16) : '';
    final title = h['category'] == 'havdalah'
        ? 'יציאת שבת / חג'
        : h['category'] == 'candles'
            ? (_wall('${raw.substring(0, 10)}T12:00').weekday == DateTime.friday
                ? 'כניסת שבת · הדלקת נרות'
                : 'הדלקת נרות לחג')
            : h['title'].toString();
    return '$title${t.isEmpty ? '' : ' · $t'}';
  }

  void _move(int n) {
    setState(() {
      _selected = _view == 'month'
          ? DateTime.utc(_selected.year, _selected.month + n, 1)
          : _selected.add(Duration(days: n * (_view == 'week' ? 7 : 1)));
    });
    _load();
  }

  Future<void> _preferences() async {
    if (_settings == null) return;
    final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) =>
            _CalendarSettings(settings: _settings!, cities: _cities));
    if (result == null || !mounted) return;
    try {
      await api.call('settings', method: 'PUT', body: result);
      if (!mounted) return;
      setState(() {
        _settings = result;
        _configured = true;
      });
      await _init();
    } catch (e) {
      _message(e);
    }
  }

  Future<void> _edit({Map<String, dynamic>? event, DateTime? at}) async {
    if (_settings == null) return;
    final token = widget.token;
    final client = api;
    try {
      final contacts = _maps(await client.call('contacts'));
      final attendees = event == null
          ? <Map<String, dynamic>>[]
          : _maps(await client.call('events/${event['id']}/attendees'));
      if (!mounted || token != widget.token) return;
      final result = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _EventEditor(
              api: client,
              settings: _settings!,
              contacts: contacts,
              attendees: attendees,
              event: event,
              at: at ?? _selected.add(const Duration(hours: 9))));
      if (result == true) await _load();
    } catch (e) {
      _message(e);
    }
  }

  Future<void> _respond(Map<String, dynamic> e, String response) async {
    try {
      await api.call('events/${e['id']}/respond',
          method: 'POST',
          body: {'response': response, 'version': e['version']});
      await _load();
    } catch (err) {
      _message(err);
    }
  }

  Future<void> _details(Map<String, dynamic> e) async {
    // Only owners receive a null response from the joined attendee row.
    final owner = e['response'] == null;
    final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(e['title']),
                content: SingleChildScrollView(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(
                          '${_dayLabel(_wall(e['start_local']))} · ${e['all_day'] == true ? 'כל היום' : '${_time(_wall(e['start_local']))}–${_time(_wall(e['end_local']))}'}'),
                      Text(
                          'עד ${_dayLabel(_wall(e['end_local']))} · ${_settings?['timezone']}'),
                      if (e['series_id'] != null)
                        const Text('מופע מתוך סדרה — שינויים חלים על מופע זה'),
                      Text('יוצר האירוע: ${e['owner_name']}'),
                      if (e['location'].toString().isNotEmpty)
                        Text('מקום: ${e['location']}'),
                      if (e['notes'].toString().isNotEmpty)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(e['notes'])),
                      if (!owner)
                        Text('תשובתך: ${{
                          'accepted': 'אישור',
                          'maybe': 'אולי',
                          'pending': 'טרם נענתה',
                          'declined': 'דחייה'
                        }[e['response']]}'),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('סגירה')),
                  if (owner) ...[
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, 'delete'),
                        child: const Text('ביטול האירוע',
                            style: TextStyle(color: Colors.red))),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, 'edit'),
                        child: const Text('עריכה ומוזמנים'))
                  ] else ...[
                    for (final r in ['accepted', 'maybe', 'declined'])
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, r),
                          child: Text({
                            'accepted': 'אישור',
                            'maybe': 'אולי',
                            'declined': 'דחייה'
                          }[r]!))
                  ],
                ]));
    if (!mounted || result == null) return;
    if (result == 'edit') {
      await _edit(event: e);
      return;
    }
    if (result == 'delete') {
      final confirm = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
                  title: const Text('לבטל את האירוע?'),
                  content: const Text(
                      'המוזמנים יקבלו עדכון והאירוע יוסר מהיומנים שלהם. בסדרה, רק מופע זה יבוטל.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('חזרה')),
                    FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('ביטול האירוע'))
                  ]));
      if (confirm != true) return;
      try {
        await api.call('events/${e['id']}',
            method: 'DELETE', body: {'version': e['version']});
        await _load();
      } catch (err) {
        _message(err);
      }
    } else {
      await _respond(e, result);
    }
  }

  Future<void> _inbox() async {
    final invitations = List<Map<String, dynamic>>.from(_invitations),
        notices = List<Map<String, dynamic>>.from(_notices);
    await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('הזמנות ועדכונים'),
                content: SizedBox(
                    width: 550,
                    child: SingleChildScrollView(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (invitations.isEmpty && notices.isEmpty)
                        const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('אין הזמנות או עדכונים חדשים')),
                      for (final e in invitations)
                        Card(
                            child: ListTile(
                                leading: const Icon(Icons.event_available,
                                    color: _blue),
                                title: Text(e['title']),
                                subtitle: Text(
                                    '${e['owner_name']} · ${_dayLabel(_wall(e['start_local']))} ${_time(_wall(e['start_local']))}'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _details(e);
                                })),
                      for (final n in notices)
                        ListTile(
                            leading: const Icon(Icons.notifications_outlined),
                            title: Text(n['message'])),
                    ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('סגירה'))
                ]));
    if (notices.isNotEmpty) {
      try {
        await api.call('notices/read',
            method: 'POST',
            body: {'ids': notices.map((n) => n['id']).toList()});
        if (mounted) _load(silent: true);
      } catch (e) {
        _message(e);
      }
    }
  }

  Widget _eventChip(Map<String, dynamic> e, {bool compact = false}) => InkWell(
      onTap: () => _details(e),
      child: Container(
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          decoration: BoxDecoration(
              color: (_colors[e['color']] ?? _blue).withValues(alpha: .12),
              border: Border(
                  right: BorderSide(
                      color: _colors[e['color']] ?? _blue, width: 3)),
              borderRadius: BorderRadius.circular(4)),
          child: Text(
              '${e['all_day'] == true ? '' : '${_time(_wall(e['start_local']))} '}${e['title']}${e['response'] == 'maybe' ? ' · אולי' : ''}',
              maxLines: compact ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: compact ? 11 : 13,
                  color: _colors[e['color']] ?? _blue))));
  Widget _month() => LayoutBuilder(builder: (context, box) {
        final small = box.maxWidth < 600;
        final cellHeight =
            math.max(small ? 106.0 : 108.0, (box.maxHeight - 34) / 6);
        final maxItems = small || cellHeight < 135 ? 1 : 2;
        return Column(children: [
          Row(children: [
            for (final d in _weekdays)
              Expanded(
                  child: Center(
                      child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Text(small ? d.substring(0, 1) : d,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)))))
          ]),
          Expanded(
              child: ListView(children: [
            for (int week = 0; week < 6; week++)
              SizedBox(
                  height: cellHeight,
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (int day = 0; day < 7; day++)
                          Expanded(child: Builder(builder: (ctx) {
                            final date =
                                _start.add(Duration(days: week * 7 + day));
                            final entries = _onDay(date),
                                holidays = _holidaysOn(date);
                            return InkWell(
                                onTap: () {
                                  setState(() {
                                    _selected = date;
                                    _view = 'day';
                                  });
                                  _load();
                                },
                                child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                        color: _date(date) == _date(_today)
                                            ? const Color(0xFFEAF5FE)
                                            : date.month != _selected.month
                                                ? const Color(0xFFF5F6F8)
                                                : Colors.white,
                                        border: Border.all(
                                            color: const Color(0xFFE1E8ED),
                                            width: .5)),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text('${date.day}',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                          Text(_hebrew(date),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.blueGrey)),
                                          for (final h
                                              in holidays.take(maxItems))
                                            Text(_holidayLabel(h),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    fontSize: 10,
                                                    color: Color(0xFF8B6419))),
                                          for (final e
                                              in entries.take(maxItems))
                                            _eventChip(e, compact: true),
                                          if (entries.length > (maxItems) ||
                                              holidays.length > (maxItems))
                                            const Text('עוד…',
                                                style: TextStyle(
                                                    fontSize: 10,
                                                    color: _blue)),
                                        ])));
                          }))
                      ]))
          ]))
        ]);
      });
  Widget _timeline() => LayoutBuilder(builder: (context, box) {
        final width = math.max(box.maxWidth, _days == 7 ? 900.0 : box.maxWidth);
        final col = (width - 48) / _days;
        return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
                width: width,
                child: Column(children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const SizedBox(width: 48),
                    for (int i = 0; i < _days; i++)
                      SizedBox(
                          width: col,
                          child: Builder(builder: (_) {
                            final d = _start.add(Duration(days: i));
                            return Container(
                                padding: const EdgeInsets.all(5),
                                color: const Color(0xFFF1F7FC),
                                child: Column(children: [
                                  Text(
                                      '${_weekdays[d.weekday % 7]} ${d.day}/${d.month}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  Text(_hebrew(d),
                                      style: const TextStyle(fontSize: 11)),
                                  for (final h in _holidaysOn(d))
                                    Text(_holidayLabel(h),
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Color(0xFF8B6419))),
                                  for (final e in _onDay(d)
                                      .where((e) => e['all_day'] == true))
                                    _eventChip(e, compact: true)
                                ]));
                          }))
                  ]),
                  Expanded(
                      child: SingleChildScrollView(
                          controller: _hoursScroll,
                          child: SizedBox(
                              height: 1440,
                              child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                        width: 48,
                                        child: Stack(children: [
                                          for (int hour = 0; hour < 24; hour++)
                                            Positioned(
                                                top: hour * 60.0,
                                                child: Text(
                                                    '${hour.toString().padLeft(2, '0')}:00',
                                                    style: const TextStyle(
                                                        fontSize: 11,
                                                        color:
                                                            Colors.blueGrey)))
                                        ])),
                                    for (int i = 0; i < _days; i++)
                                      SizedBox(
                                          width: col,
                                          height: 1440,
                                          child: _dayColumn(
                                              _start.add(Duration(days: i)),
                                              col))
                                  ])))),
                ])));
      });
  Widget _dayColumn(DateTime day, double width) {
    final events = _onDay(day).where((e) => e['all_day'] != true).toList()
      ..sort((a, b) =>
          a['start_local'].toString().compareTo(b['start_local'].toString()));
    final placements = <Map<String, dynamic>>[];
    var group = <Map<String, dynamic>>[];
    var ends = <double>[];
    double groupEnd = -1;
    void flush() {
      for (final p in group) {
        p['columns'] = ends.length;
        placements.add(p);
      }
      group = [];
      ends = [];
      groupEnd = -1;
    }

    for (final e in events) {
      final a = _wall(e['start_local']), b = _wall(e['end_local']);
      final start = math.max(0, a.difference(day).inMinutes).toDouble(),
          end = math.min(1440, b.difference(day).inMinutes).toDouble();
      if (start >= groupEnd && group.isNotEmpty) flush();
      int lane = ends.indexWhere((x) => x <= start);
      if (lane < 0) {
        lane = ends.length;
        ends.add(end);
      } else {
        ends[lane] = end;
      }
      group.add({'event': e, 'start': start, 'end': end, 'lane': lane});
      groupEnd = math.max(groupEnd, end);
    }
    flush();
    return Stack(children: [
      for (int h = 0; h < 48; h++)
        Positioned(
            top: h * 30.0,
            left: 0,
            right: 0,
            height: 30,
            child: InkWell(
                onTap: () => _edit(at: day.add(Duration(minutes: h * 30))),
                child: Container(
                    decoration: BoxDecoration(
                        border: Border(
                            top: BorderSide(
                                color: h.isEven
                                    ? const Color(0xFFDCE5EC)
                                    : const Color(0xFFF0F3F6)),
                            left:
                                const BorderSide(color: Color(0xFFE1E8ED))))))),
      for (final p in placements)
        Positioned(
            top: p['start'] as double,
            right: (p['lane'] as int) * width / (p['columns'] as int),
            width: width / (p['columns'] as int) - 2,
            height:
                math.max(22, (p['end'] as double) - (p['start'] as double) - 2),
            child: Material(
                color: (_colors[p['event']['color']] ?? _blue)
                    .withValues(alpha: .18),
                borderRadius: BorderRadius.circular(5),
                child: InkWell(
                    onTap: () => _details(p['event']),
                    child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text(
                            '${_time(_wall(p['event']['start_local']))} ${p['event']['title']}',
                            overflow: TextOverflow.fade,
                            style: const TextStyle(fontSize: 12))))))
    ]);
  }

  @override
  Widget build(BuildContext context) => Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
          backgroundColor: Colors.white,
          appBar: AppBar(
              backgroundColor: _blue,
              foregroundColor: Colors.white,
              leading: IconButton(
                  tooltip: 'חזרה',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onClose ?? () => Navigator.pop(context)),
              title: const Text('לוח שנה'),
              actions: [
                IconButton(
                    tooltip: 'הזמנות ועדכונים',
                    onPressed: _inbox,
                    icon: Badge(
                        isLabelVisible:
                            _invitations.isNotEmpty || _notices.isNotEmpty,
                        label: Text('${_invitations.length + _notices.length}'),
                        child: const Icon(Icons.mail_outline))),
                IconButton(
                    tooltip: 'עיר וזמני שבת',
                    onPressed: _preferences,
                    icon: const Icon(Icons.location_on_outlined)),
                IconButton(
                    tooltip: 'רענון',
                    onPressed: _init,
                    icon: const Icon(Icons.refresh))
              ]),
          body: Column(children: [
            Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                          onPressed: _settings == null ? null : () => _edit(),
                          icon: const Icon(Icons.add),
                          label: const Text('אירוע חדש')),
                      SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'day', label: Text('יום')),
                            ButtonSegment(value: 'week', label: Text('שבוע')),
                            ButtonSegment(value: 'month', label: Text('חודש'))
                          ],
                          selected: {
                            _view
                          },
                          onSelectionChanged: (v) {
                            setState(() => _view = v.first);
                            _load();
                          }),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                            tooltip: 'הקודם',
                            onPressed: () => _move(-1),
                            icon: const Icon(Icons.chevron_right)),
                        TextButton(
                            onPressed: () async {
                              final d = await showDatePicker(
                                  context: context,
                                  initialDate: _selected,
                                  firstDate: DateTime(2020),
                                  lastDate: DateTime(2100));
                              if (d != null) {
                                setState(() => _selected = d);
                                _load();
                              }
                            },
                            child: Text(_view == 'month'
                                ? '${const [
                                    'ינואר',
                                    'פברואר',
                                    'מרץ',
                                    'אפריל',
                                    'מאי',
                                    'יוני',
                                    'יולי',
                                    'אוגוסט',
                                    'ספטמבר',
                                    'אוקטובר',
                                    'נובמבר',
                                    'דצמבר'
                                  ][_selected.month - 1]} ${_selected.year}'
                                : _dayLabel(_selected))),
                        IconButton(
                            tooltip: 'הבא',
                            onPressed: () => _move(1),
                            icon: const Icon(Icons.chevron_left)),
                        TextButton(
                            onPressed: () {
                              setState(() => _selected = _today);
                              _load();
                            },
                            child: const Text('היום'))
                      ]),
                    ])),
            if (_settings != null)
              InkWell(
                  onTap: _preferences,
                  child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      color: const Color(0xFFFFF9EB),
                      child: Text(
                          _configured
                              ? '${_settings!['city']} · ${_settings!['timezone']} · הדלקה ${_settings!['candle_minutes']} דק׳ לפני שקיעה; יציאה 8.5°; רבנו תם 72 דק׳ אחרי שקיעה. מקור: Hebcal. התאריך העברי מתחלף בשקיעה.'
                              : 'בחרו עיר ומנהג כדי להציג חגים וזמני שבת וחג',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF74561E))))),
            if (_configured && _holidays.isNotEmpty)
              SizedBox(
                  height: 54,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final h in _holidays
                          .where((h) =>
                              ['candles', 'havdalah', 'rabbeinu_tam']
                                  .contains(h['category']) &&
                              h['date']
                                      .toString()
                                      .substring(0, 10)
                                      .compareTo(_date(_selected)) >=
                                  0)
                          .take(3))
                        Padding(
                            padding: const EdgeInsets.all(4),
                            child: Chip(
                              avatar: const Icon(Icons.wb_twilight, size: 18),
                              label: Text(
                                  '${h['date'].toString().substring(0, 10)} · ${_holidayLabel(h)}',
                                  style: const TextStyle(fontSize: 12)),
                            )),
                    ],
                  )),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null || _holidayError != null)
              Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_error ?? _holidayError!,
                      style: const TextStyle(color: Colors.red))),
            Expanded(child: _view == 'month' ? _month() : _timeline()),
          ])));
}

class _CalendarSettings extends StatefulWidget {
  final Map<String, dynamic> settings;
  final List<Map<String, dynamic>> cities;
  const _CalendarSettings({required this.settings, required this.cities});
  @override
  State<_CalendarSettings> createState() => _CalendarSettingsState();
}

class _CalendarSettingsState extends State<_CalendarSettings> {
  late Map<String, dynamic> s;
  late final TextEditingController city, lat, lon, zone, minutes;
  @override
  void initState() {
    super.initState();
    s = Map.from(widget.settings);
    city = TextEditingController(text: s['city']);
    lat = TextEditingController(text: '${s['latitude']}');
    lon = TextEditingController(text: '${s['longitude']}');
    zone = TextEditingController(text: s['timezone']);
    minutes = TextEditingController(text: '${s['candle_minutes']}');
  }

  @override
  void dispose() {
    for (final c in [city, lat, lon, zone, minutes]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
          title: const Text('מיקום וזמני שבת וחג'),
          content: SizedBox(
              width: 430,
              child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                DropdownButtonFormField<String>(
                    decoration:
                        const InputDecoration(labelText: 'בחירה מהירה של עיר'),
                    items: widget.cities
                        .map((x) => DropdownMenuItem(
                            value: x['city'] as String, child: Text(x['city'])))
                        .toList(),
                    onChanged: (v) {
                      final c = widget.cities.firstWhere((x) => x['city'] == v);
                      setState(() {
                        s = Map.from(c);
                        city.text = c['city'];
                        lat.text = '${c['latitude']}';
                        lon.text = '${c['longitude']}';
                        zone.text = c['timezone'];
                        minutes.text = '${c['candle_minutes']}';
                      });
                    }),
                TextField(
                    controller: city,
                    decoration: const InputDecoration(labelText: 'עיר')),
                Row(children: [
                  Expanded(
                      child: TextField(
                          controller: lat,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true, signed: true),
                          decoration:
                              const InputDecoration(labelText: 'קו רוחב'))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextField(
                          controller: lon,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true, signed: true),
                          decoration:
                              const InputDecoration(labelText: 'קו אורך')))
                ]),
                TextField(
                    controller: zone,
                    textDirection: TextDirection.ltr,
                    decoration: const InputDecoration(
                        labelText: 'אזור זמן', hintText: 'Asia/Jerusalem')),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('לוח חגים של ישראל'),
                    subtitle: const Text('כבוי: חו״ל ויום טוב שני'),
                    value: s['israel'] == true,
                    onChanged: (v) => setState(() => s['israel'] = v)),
                TextField(
                    controller: minutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'דקות הדלקת נרות לפני השקיעה')),
                const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                        'יציאה: צאת הכוכבים לפי 8.5°. רבנו תם מוצג בנפרד לפי 72 דקות קבועות אחרי השקיעה. יש לבחור את מנהג ההדלקה הנהוג בעירכם. הזמנים מחושבים לפי מרכז העיר.',
                        style: TextStyle(fontSize: 12))),
              ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('ביטול')),
            FilledButton(
                onPressed: () {
                  final a = double.tryParse(lat.text),
                      b = double.tryParse(lon.text),
                      m = int.tryParse(minutes.text);
                  if (a == null ||
                      b == null ||
                      m == null ||
                      m < 0 ||
                      m > 60 ||
                      a.abs() > 65 ||
                      b.abs() > 180 ||
                      city.text.trim().isEmpty ||
                      zone.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('יש למלא מיקום ומנהג תקינים')));
                    return;
                  }
                  Navigator.pop(context, {
                    'city': city.text.trim(),
                    'latitude': a,
                    'longitude': b,
                    'timezone': zone.text.trim(),
                    'israel': s['israel'] == true,
                    'candle_minutes': m
                  });
                },
                child: const Text('שמירה'))
          ]));
}

class _EventEditor extends StatefulWidget {
  final CalendarApi api;
  final Map<String, dynamic> settings;
  final List<Map<String, dynamic>> contacts, attendees;
  final Map<String, dynamic>? event;
  final DateTime at;
  const _EventEditor(
      {required this.api,
      required this.settings,
      required this.contacts,
      required this.attendees,
      this.event,
      required this.at});
  @override
  State<_EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<_EventEditor> {
  late final TextEditingController title, notes, location, count;
  late DateTime start, end;
  late bool allDay;
  late String color, zone;
  String repeat = 'none';
  int? reminder = 15;
  final Set<String> invitees = {};
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final e = widget.event;
    title = TextEditingController(text: e?['title'] ?? '');
    notes = TextEditingController(text: e?['notes'] ?? '');
    location = TextEditingController(text: e?['location'] ?? '');
    count = TextEditingController(text: '4');
    start = e == null ? widget.at : _wall(e['event_start_local']);
    end = e == null
        ? start.add(const Duration(hours: 1))
        : _wall(e['event_end_local']);
    allDay = e?['all_day'] == true;
    color = e?['color'] ?? 'blue';
    zone = e?['timezone'] ?? widget.settings['timezone'];
    reminder = e == null ? 15 : e['reminder_minutes'];
    invitees.addAll(widget.attendees.map((x) => x['user_id'] as String));
  }

  @override
  void dispose() {
    for (final c in [title, notes, location, count]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> pick(bool first) async {
    final original = first ? start : end;
    final d = await showDatePicker(
        context: context,
        initialDate: original,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100));
    if (d == null || !mounted) return;
    TimeOfDay? t;
    if (!allDay) {
      t = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.fromDateTime(original),
          builder: (context, child) => MediaQuery(
              data:
                  MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
              child: child!));
      if (t == null || !mounted) return;
    }
    setState(() {
      final next =
          DateTime.utc(d.year, d.month, d.day, t?.hour ?? 0, t?.minute ?? 0);
      if (first) {
        start = next;
        if (!end.isAfter(start)) {
          end = start.add(Duration(hours: allDay ? 24 : 1));
        }
      } else {
        end = next;
      }
    });
  }

  Future<void> save() async {
    if (saving) return;
    if (title.text.trim().isEmpty || !end.isAfter(start)) {
      setState(() => error = 'יש להזין כותרת ושעת סיום אחרי ההתחלה');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.api.call(
          widget.event == null ? 'events' : 'events/${widget.event!['id']}',
          method: widget.event == null ? 'POST' : 'PUT',
          body: {
            'title': title.text.trim(),
            'notes': notes.text,
            'location': location.text,
            'start': _local(start),
            'end': _local(end),
            'timezone': zone,
            'all_day': allDay,
            'color': color,
            'reminder_minutes': reminder,
            'repeat': repeat,
            'count': int.tryParse(count.text),
            'invitees': invitees.toList(),
            if (widget.event != null) 'version': widget.event!['version']
          });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString().replaceFirst('Exception: ', '');
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = {
      for (final c in widget.contacts) c['id']: c['name'],
      for (final a in widget.attendees) a['user_id']: a['name']
    };
    return Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
            title: Text(
                widget.event == null ? 'אירוע חדש' : 'עריכת אירוע ומוזמנים'),
            content: SizedBox(
                width: 580,
                child: SingleChildScrollView(
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      TextField(
                          controller: title,
                          maxLength: 160,
                          decoration:
                              const InputDecoration(labelText: 'שם האירוע'),
                          autofocus: true),
                      Text('אזור זמן: $zone',
                          style: const TextStyle(fontSize: 12)),
                      SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('כל היום'),
                          value: allDay,
                          onChanged: saving
                              ? null
                              : (v) => setState(() {
                                    allDay = v;
                                    if (v) {
                                      start = _day(start);
                                      end = _day(end);
                                      if (!end.isAfter(start)) {
                                        end =
                                            start.add(const Duration(days: 1));
                                      }
                                    }
                                  })),
                      ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('התחלה'),
                          subtitle: Text(
                              '${_dayLabel(start)} ${allDay ? '' : _time(start)}'),
                          trailing: const Icon(Icons.edit_calendar),
                          onTap: saving ? null : () => pick(true)),
                      ListTile(
                          contentPadding: EdgeInsets.zero,
                          title:
                              Text(allDay ? 'סיום (יום זה אינו כלול)' : 'סיום'),
                          subtitle: Text(
                              '${_dayLabel(end)} ${allDay ? '' : _time(end)}'),
                          trailing: const Icon(Icons.edit_calendar),
                          onTap: saving ? null : () => pick(false)),
                      TextField(
                          controller: location,
                          maxLength: 300,
                          decoration: const InputDecoration(labelText: 'מקום')),
                      TextField(
                          controller: notes,
                          maxLength: 4000,
                          maxLines: 3,
                          decoration:
                              const InputDecoration(labelText: 'הערות')),
                      Wrap(spacing: 8, children: [
                        for (final c in _colors.entries)
                          ChoiceChip(
                              label:
                                  Icon(Icons.circle, color: c.value, size: 18),
                              selected: color == c.key,
                              onSelected: saving
                                  ? null
                                  : (_) => setState(() => color = c.key))
                      ]),
                      DropdownButtonFormField<int>(
                          initialValue: reminder ?? -1,
                          decoration:
                              const InputDecoration(labelText: 'תזכורת'),
                          items: const [
                            DropdownMenuItem(value: -1, child: Text('ללא')),
                            DropdownMenuItem(
                                value: 0, child: Text('בשעת האירוע')),
                            DropdownMenuItem(
                                value: 5, child: Text('5 דקות לפני')),
                            DropdownMenuItem(
                                value: 15, child: Text('15 דקות לפני')),
                            DropdownMenuItem(
                                value: 30, child: Text('30 דקות לפני')),
                            DropdownMenuItem(
                                value: 60, child: Text('שעה לפני')),
                            DropdownMenuItem(
                                value: 1440, child: Text('יום לפני'))
                          ],
                          onChanged: saving
                              ? null
                              : (v) => setState(
                                  () => reminder = v == -1 ? null : v)),
                      const Text(
                          'התזכורת תופיע בעדכוני היומן; התראת מכשיר דורשת הרשאת התראות.',
                          style:
                              TextStyle(fontSize: 11, color: Colors.blueGrey)),
                      if (widget.event == null) ...[
                        DropdownButtonFormField<String>(
                            initialValue: repeat,
                            decoration:
                                const InputDecoration(labelText: 'חזרה'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'none', child: Text('חד־פעמי')),
                              DropdownMenuItem(
                                  value: 'daily', child: Text('כל יום')),
                              DropdownMenuItem(
                                  value: 'weekly', child: Text('כל שבוע')),
                              DropdownMenuItem(
                                  value: 'monthly',
                                  child: Text('כל חודש (לועזי)'))
                            ],
                            onChanged: saving
                                ? null
                                : (v) => setState(() => repeat = v!)),
                        if (repeat != 'none')
                          TextField(
                              controller: count,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                  labelText:
                                      'מספר מופעים, כולל הראשון (עד 104)'))
                      ],
                      if (widget.event?['series_id'] != null)
                        const Text('העריכה חלה על מופע זה בלבד.'),
                      const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: Text('הזמנת חברים',
                              style: TextStyle(fontWeight: FontWeight.bold))),
                      if (contacts.isEmpty)
                        const Text(
                            'אין עדיין חברים זמינים להזמנה. אפשר לשמור אירוע אישי.'),
                      for (final c in contacts.entries)
                        CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(c.value.toString()),
                            subtitle: widget.attendees
                                    .any((a) => a['user_id'] == c.key)
                                ? Text({
                                    'pending': 'ממתין לתשובה',
                                    'accepted': 'אישר/ה',
                                    'maybe': 'אולי',
                                    'declined': 'דחה/תה'
                                  }[widget.attendees.firstWhere(
                                    (a) => a['user_id'] == c.key)['response']]!)
                                : null,
                            value: invitees.contains(c.key),
                            onChanged: saving
                                ? null
                                : (v) => setState(() {
                                      if (v == true) {
                                        invitees.add(c.key as String);
                                      } else {
                                        invitees.remove(c.key);
                                      }
                                    })),
                      if (error != null)
                        Text(error!, style: const TextStyle(color: Colors.red)),
                    ]))),
            actions: [
              TextButton(
                  onPressed:
                      saving ? null : () => Navigator.pop(context, false),
                  child: const Text('ביטול')),
              FilledButton(
                  onPressed: saving ? null : save,
                  child: Text(saving
                      ? 'שומר…'
                      : invitees.isEmpty
                          ? 'שמירה'
                          : 'שמירה ושליחת הזמנות'))
            ]));
  }
}
