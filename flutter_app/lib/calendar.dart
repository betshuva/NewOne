import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'calendar_hebrew_date.dart';
import 'calendar_event_widgets.dart';
import 'hebrew_date_picker.dart';
import 'location_autocomplete.dart';
import 'package:http/http.dart' as http;

const _blue = Color(0xFF1B6CA8);
const _candleMinutes = 15;
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
String _reminderLabel(dynamic value) => switch (value) {
      null => 'ללא',
      0 => 'בשעת האירוע',
      60 => 'שעה לפני',
      1440 => 'יום לפני',
      _ => '$value דקות לפני',
    };
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
  List<String> _timezones = [];
  bool _locationAllowed = true, _autoLocationAttempted = false;
  DateTime _selected = _day(DateTime.now());
  String _view = 'week';
  bool _loading = true, _configured = false;
  String? _error, _holidayError;
  int _generation = 0;
  DateTime _today = _day(DateTime.now());
  Timer? _timer;
  final _hoursScroll = ScrollController(initialScrollOffset: 7 * 60);
  HebrewDate get _selectedHebrew => HebrewDate.fromGregorian(_selected);
  DateTime get _start {
    if (_view == 'month') {
      final selected = _selectedHebrew;
      final first = HebrewDate(selected.year, selected.month, 1).toGregorian();
      return first.subtract(Duration(days: first.weekday % 7));
    }
    return _view == 'week'
        ? _day(_selected).subtract(Duration(days: _selected.weekday % 7))
        : _day(_selected);
  }

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
      _autoLocationAttempted = false;
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
        _settings = {
          ...Map<String, dynamic>.from(b['settings']),
          'candle_minutes': _candleMinutes,
        };
        _today = _day(DateTime.parse(b['today'] ?? _date(DateTime.now())));
        if (firstLoad) _selected = _today;
        _configured = b['configured'] == true;
        _cities = _maps(b['cities']);
        _timezones = (b['timezones'] as List? ?? []).cast<String>();
        _locationAllowed = b['location_allowed'] != false;
      });
      await _load();
      if (mounted &&
          token == widget.token &&
          b['source'] == 'default' &&
          _locationAllowed &&
          !_autoLocationAttempted) {
        _autoLocationAttempted = true;
        unawaited(_automaticLocation());
      }
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
  String _hebrew(DateTime d) => HebrewDate.fromGregorian(d).label;

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
          ? _selectedHebrew.addMonths(n).toGregorian()
          : _selected.add(Duration(days: n * (_view == 'week' ? 7 : 1)));
    });
    _load();
  }

  Future<void> _automaticLocation() async {
    final client = api;
    final token = widget.token;
    try {
      // Screen loading never opens a permission prompt. The location button
      // lets the user grant permission explicitly if it is not already given.
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        return;
      }
      final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.low,
              timeLimit: Duration(seconds: 10)));
      if (!mounted || token != widget.token) return;
      await client.call('location/default', method: 'POST', body: {
        'latitude': position.latitude,
        'longitude': position.longitude,
      });
      if (mounted && token == widget.token) await _init();
    } catch (_) {
      // Jerusalem remains usable when device location is unavailable.
    }
  }

  Future<void> _preferences() async {
    if (_settings == null) return;
    final client = api;
    final token = widget.token;
    final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _CalendarSettings(
            api: client,
            settings: _settings!,
            cities: _cities,
            timezones: _timezones,
            locationAllowed: _locationAllowed));
    if (result == null || !mounted || token != widget.token) return;
    try {
      await client.call('settings', method: 'PUT', body: result);
      if (!mounted || token != widget.token) return;
      await _init();
    } catch (e) {
      if (mounted && token == widget.token) _message(e);
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
    final client = api;
    final token = widget.token;
    final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                key: const ValueKey('calendar-event-details'),
                title: Text(e['title']),
                content: SizedBox(
                    width: 480,
                    child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(
                              '${_dayLabel(_wall(e['start_local']))} · ${e['all_day'] == true ? 'כל היום' : '\u2066${_time(_wall(e['start_local']))}–${_time(_wall(e['end_local']))}\u2069'}'),
                          Text(
                              'עד ${_dayLabel(_wall(e['end_local']))} · ${_settings?['timezone']}'),
                          if (e['series_id'] != null)
                            const Text('מופע מתוך סדרה'),
                          Text('יוצר האירוע: ${e['owner_name']}'),
                          if (e['location'].toString().isNotEmpty)
                            Text('מקום: ${e['location']}'),
                          if (e['notes'].toString().isNotEmpty)
                            Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(e['notes'])),
                          Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                  'תזכורת: ${_reminderLabel(e['reminder_minutes'])}')),
                          if (owner)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: CalendarEventAttendanceDetails(
                                event: e,
                                loadAttendees: () async {
                                  final rows = await client
                                      .call('events/${e['id']}/attendees');
                                  if (!mounted || widget.token != token) {
                                    throw StateError('החשבון השתנה');
                                  }
                                  return _maps(rows);
                                },
                              ),
                            ),
                          if (!owner)
                            Text('תשובתך: ${{
                              'accepted': 'אישור',
                              'maybe': 'אולי',
                              'pending': 'טרם נענתה',
                              'declined': 'דחייה'
                            }[e['response']]}'),
                        ]))),
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
    if (!mounted || result == null || widget.token != token) return;
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

  Widget _eventChip(Map<String, dynamic> e,
          {bool compact = false, DateTime? day}) =>
      InkWell(
          onTap: () {
            if (day != null) setState(() => _selected = day);
            _details(e);
          },
          child: Container(
              margin: const EdgeInsets.symmetric(vertical: 1),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              decoration: BoxDecoration(
                  color: (_colors[e['color']] ?? _blue).withValues(alpha: .12),
                  border: Border(
                      right: BorderSide(
                          color: _colors[e['color']] ?? _blue, width: 3)),
                  borderRadius: BorderRadius.circular(4)),
              child: CalendarEventSummary(
                  event: e,
                  compact: compact,
                  color: _colors[e['color']] ?? _blue)));
  Widget _month() => LayoutBuilder(builder: (context, box) {
        final small = box.maxWidth < 600;
        final month = _selectedHebrew;
        final start = _start;
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
                                start.add(Duration(days: week * 7 + day));
                            final hebrew = HebrewDate.fromGregorian(date);
                            final selected = _date(date) == _date(_selected);
                            final today = _date(date) == _date(_today);
                            final inMonth = hebrew.year == month.year &&
                                hebrew.month == month.month;
                            final entries = _onDay(date),
                                holidays = _holidaysOn(date);
                            return Semantics(
                                selected: selected,
                                label: '${hebrew.label}, ${_dayLabel(date)}',
                                child: InkWell(
                                    onTap: () {
                                      setState(() {
                                        _selected = date;
                                        _view = 'day';
                                      });
                                      _load();
                                    },
                                    child: Container(
                                        key: ValueKey(
                                            'calendar-month-day-${_date(date)}'),
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                            color: selected
                                                ? const Color(0xFFDCEFFC)
                                                : today
                                                    ? const Color(0xFFEAF5FE)
                                                    : !inMonth
                                                        ? const Color(
                                                            0xFFF5F6F8)
                                                        : Colors.white,
                                            border: Border.all(
                                                color: selected
                                                    ? _blue
                                                    : const Color(0xFFE1E8ED),
                                                width: selected ? 2 : .5)),
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(children: [
                                                Flexible(
                                                  child: FittedBox(
                                                    fit: BoxFit.scaleDown,
                                                    child: Text(hebrew.dayLabel,
                                                        style: const TextStyle(
                                                            fontWeight:
                                                                FontWeight
                                                                    .bold)),
                                                  ),
                                                ),
                                                if (today)
                                                  const Padding(
                                                    padding:
                                                        EdgeInsetsDirectional
                                                            .only(start: 5),
                                                    child: Tooltip(
                                                      message: 'היום',
                                                      child: Icon(Icons.circle,
                                                          size: 6,
                                                          color: _blue),
                                                    ),
                                                  ),
                                              ]),
                                              Text('${date.day}/${date.month}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      fontSize: 10,
                                                      color: Colors.blueGrey)),
                                              for (final h
                                                  in holidays.take(maxItems))
                                                Text(_holidayLabel(h),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                        fontSize: 10,
                                                        color:
                                                            Color(0xFF8B6419))),
                                              for (final e
                                                  in entries.take(maxItems))
                                                _eventChip(e, compact: true),
                                              if (entries.length > (maxItems) ||
                                                  holidays.length > (maxItems))
                                                const Text('עוד…',
                                                    style: TextStyle(
                                                        fontSize: 10,
                                                        color: _blue)),
                                            ]))));
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
                            final selected = _date(d) == _date(_selected);
                            final today = _date(d) == _date(_today);
                            return Semantics(
                                key: ValueKey('calendar-header-${_date(d)}'),
                                selected: selected,
                                child: InkWell(
                                    onTap: () => setState(() => _selected = d),
                                    child: Container(
                                        padding: const EdgeInsets.all(5),
                                        decoration: BoxDecoration(
                                          color: selected
                                              ? const Color(0xFFDCEFFC)
                                              : const Color(0xFFF1F7FC),
                                          border: Border(
                                              bottom: BorderSide(
                                            color: selected
                                                ? _blue
                                                : Colors.transparent,
                                            width: 3,
                                          )),
                                        ),
                                        child: Column(children: [
                                          Text(
                                              '${_weekdays[d.weekday % 7]} ${d.day}/${d.month}${today ? ' · היום' : ''}',
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.bold)),
                                          Text(_hebrew(d),
                                              style: const TextStyle(
                                                  fontSize: 11)),
                                          for (final h in _holidaysOn(d))
                                            Text(_holidayLabel(h),
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                    fontSize: 11,
                                                    color: Color(0xFF8B6419))),
                                          for (final e in _onDay(d).where(
                                              (e) => e['all_day'] == true))
                                            _eventChip(e, compact: true, day: d)
                                        ]))));
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
    return ColoredBox(
        key: ValueKey('calendar-column-${_date(day)}'),
        color: _date(day) == _date(_selected)
            ? const Color(0xFFF1F8FE)
            : Colors.white,
        child: Stack(children: [
          for (int h = 0; h < 48; h++)
            Positioned(
                top: h * 30.0,
                left: 0,
                right: 0,
                height: 30,
                child: InkWell(
                    onTap: () {
                      setState(() => _selected = day);
                      _edit(at: day.add(Duration(minutes: h * 30)));
                    },
                    child: Container(
                        decoration: BoxDecoration(
                            border: Border(
                                top: BorderSide(
                                    color: h.isEven
                                        ? const Color(0xFFDCE5EC)
                                        : const Color(0xFFF0F3F6)),
                                left: const BorderSide(
                                    color: Color(0xFFE1E8ED))))))),
          for (final p in placements)
            Positioned(
                top: p['start'] as double,
                right: (p['lane'] as int) * width / (p['columns'] as int),
                width: width / (p['columns'] as int) - 2,
                height: math.max(
                    22, (p['end'] as double) - (p['start'] as double) - 2),
                child: Material(
                    color: (_colors[p['event']['color']] ?? _blue)
                        .withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(5),
                    child: InkWell(
                        onTap: () {
                          setState(() => _selected = day);
                          _details(p['event']);
                        },
                        child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: CalendarEventSummary(
                                event: p['event'],
                                color:
                                    _colors[p['event']['color']] ?? _blue)))))
        ]));
  }

  @override
  Widget build(BuildContext context) => Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
          // Inputs live in dialogs, which handle their own keyboard insets.
          resizeToAvoidBottomInset: false,
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
                            icon: const Icon(Icons.chevron_right,
                                textDirection: TextDirection.ltr)),
                        Flexible(
                            child: TextButton(
                                key: const ValueKey('calendar-date-picker'),
                                onPressed: () async {
                                  final d = await showHebrewDatePicker(
                                      context: context,
                                      initialDate: _selected,
                                      firstDate: DateTime.utc(2020),
                                      lastDate: DateTime.utc(2100));
                                  if (d != null && mounted) {
                                    setState(() => _selected = _day(d));
                                    _load();
                                  }
                                },
                                child: Text(
                                    _view == 'month'
                                        ? _selectedHebrew.monthYearLabel
                                        : _selectedHebrew.label,
                                    textAlign: TextAlign.center))),
                        IconButton(
                            tooltip: 'הבא',
                            onPressed: () => _move(1),
                            icon: const Icon(Icons.chevron_left,
                                textDirection: TextDirection.ltr)),
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
                              ? '${_settings!['city']} · ${_settings!['timezone']} · הדלקה $_candleMinutes דק׳ לפני שקיעה; יציאה 8.5°; רבנו תם 72 דק׳ אחרי שקיעה. מקור: Hebcal. התאריך העברי מתחלף בשקיעה.'
                              : 'בחרו עיר להצגת חגים וזמני שבת וחג',
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
  final CalendarApi api;
  final Map<String, dynamic> settings;
  final List<Map<String, dynamic>> cities;
  final List<String> timezones;
  final bool locationAllowed;
  const _CalendarSettings(
      {required this.api,
      required this.settings,
      required this.cities,
      required this.timezones,
      required this.locationAllowed});
  @override
  State<_CalendarSettings> createState() => _CalendarSettingsState();
}

class _CalendarSettingsState extends State<_CalendarSettings> {
  late Map<String, dynamic> s;
  late final TextEditingController city;
  bool _busy = false;
  bool _zoneEdited = false, _israelEdited = false;
  String? _error;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    s = {...widget.settings, 'candle_minutes': _candleMinutes};
    city = TextEditingController(text: s['city']);
  }

  @override
  void dispose() {
    _request++;
    city.dispose();
    super.dispose();
  }

  void _apply(Map<String, dynamic> settings, {bool preserveOverrides = false}) {
    final oldZone = s['timezone'], oldIsrael = s['israel'];
    s = {...settings, 'candle_minutes': _candleMinutes};
    city.text = s['city'];
    if (preserveOverrides && _zoneEdited) s['timezone'] = oldZone;
    if (preserveOverrides && _israelEdited) s['israel'] = oldIsrael;
    if (!preserveOverrides) {
      _zoneEdited = _israelEdited = false;
    }
    _error = null;
  }

  Future<bool> _resolveCity(String name,
      {bool preserveOverrides = false}) async {
    final query = name.trim();
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final b = await widget.api
          .call('location?${Uri(queryParameters: {'city': query}).query}');
      if (!mounted || request != _request) return false;
      setState(() => _apply(Map<String, dynamic>.from(b['settings']),
          preserveOverrides: preserveOverrides));
      return true;
    } catch (e) {
      if (mounted && request == _request) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
      return false;
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _deviceLocation() async {
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        throw Exception('המיקום אינו זמין. אפשר לבחור עיר מהרשימה.');
      }
      final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.low,
              timeLimit: Duration(seconds: 10)));
      final b = await widget.api.call('location?${Uri(queryParameters: {
            'latitude': '${position.latitude}',
            'longitude': '${position.longitude}',
          }).query}');
      if (!mounted || request != _request) return;
      setState(() => _apply(Map<String, dynamic>.from(b['settings'])));
    } catch (_) {
      if (mounted && request == _request) {
        setState(() =>
            _error = 'לא ניתן לזהות את המיקום כרגע. אפשר לבחור עיר מהרשימה.');
      }
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (city.text.trim().isEmpty) {
      setState(() => _error = 'יש לבחור עיר או יישוב');
      return;
    }
    if (city.text.trim() != s['city'] &&
        !await _resolveCity(city.text, preserveOverrides: true)) {
      return;
    }
    if (!mounted) return;
    Navigator.pop(context, {...s, 'candle_minutes': _candleMinutes});
  }

  Future<void> _chooseTimezone() async {
    final zones = <String>{
      'Asia/Jerusalem',
      s['timezone'] as String,
      ...widget.timezones,
      ...widget.cities.map((c) => c['timezone'] as String),
      'UTC'
    }.toList();
    final chosen = await showDialog<String>(
        context: context,
        builder: (_) => _TimeZonePicker(zones: zones, selected: s['timezone']));
    if (chosen != null && mounted) {
      setState(() {
        s['timezone'] = chosen;
        _zoneEdited = true;
      });
    }
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
                LocationAutocompleteField(
                    api: widget.api.base,
                    controller: city,
                    label: 'עיר או יישוב',
                    hint: 'הקלד שם עיר או יישוב',
                    citiesOnly: true,
                    extraCities:
                        widget.cities.map((c) => c['city'] as String).toList(),
                    onChanged: (_) => setState(() {
                          _request++;
                          _busy = false;
                          _error = null;
                        }),
                    onSelected: (name) => _resolveCity(name)),
                if (widget.locationAllowed)
                  Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                          onPressed: _busy ? null : _deviceLocation,
                          icon: const Icon(Icons.my_location, size: 18),
                          label: const Text('שימוש במיקום הנוכחי'))),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.red))),
                const SizedBox(height: 12),
                InkWell(
                    key: const ValueKey('calendar-timezone'),
                    onTap: _busy ? null : _chooseTimezone,
                    borderRadius: BorderRadius.circular(8),
                    child: InputDecorator(
                        decoration: const InputDecoration(
                            labelText: 'אזור זמן',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.schedule),
                            suffixIcon: Icon(Icons.arrow_drop_down)),
                        child: Text(_zoneLabel(s['timezone']),
                            maxLines: 2, overflow: TextOverflow.ellipsis))),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('לוח חגים של ישראל'),
                    subtitle: const Text('כבוי: חו״ל ויום טוב שני'),
                    value: s['israel'] == true,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() {
                              s['israel'] = v;
                              _israelEdited = true;
                            })),
                const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                        'יציאה: צאת הכוכבים לפי 8.5°. רבנו תם מוצג בנפרד לפי 72 דקות קבועות אחרי השקיעה. הזמנים מחושבים לפי מרכז העיר.',
                        style: TextStyle(fontSize: 12))),
                const SizedBox(height: 8),
                Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                  const Text('נתוני מיקום: ', style: TextStyle(fontSize: 11)),
                  TextButton(
                      onPressed: () => launchUrl(
                          Uri.parse('https://data.gov.il/'),
                          mode: LaunchMode.externalApplication),
                      child: const Text('data.gov.il',
                          style: TextStyle(fontSize: 11))),
                  TextButton(
                      onPressed: () => launchUrl(
                          Uri.parse('https://www.geonames.org/'),
                          mode: LaunchMode.externalApplication),
                      child: const Text('GeoNames',
                          style: TextStyle(fontSize: 11))),
                ]),
              ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('ביטול')),
            FilledButton(
                onPressed: _busy ? null : _save, child: const Text('שמירה'))
          ]));
}

const _zoneNames = {
  'Asia/Jerusalem': 'ישראל',
  'America/New_York': 'ניו יורק',
  'America/Chicago': 'שיקגו',
  'America/Los_Angeles': 'לוס אנג׳לס',
  'Europe/London': 'לונדון',
  'Europe/Paris': 'פריז',
  'Europe/Berlin': 'ברלין',
  'Europe/Moscow': 'מוסקבה',
  'Asia/Dubai': 'דובאי',
  'Asia/Tokyo': 'טוקיו',
  'Australia/Sydney': 'סידני',
  'UTC': 'זמן אוניברסלי',
};
String _zoneLabel(String zone) => _zoneNames.containsKey(zone)
    ? '${_zoneNames[zone]} · $zone'
    : zone.replaceAll('_', ' ');

class _TimeZonePicker extends StatefulWidget {
  final List<String> zones;
  final String selected;
  const _TimeZonePicker({required this.zones, required this.selected});
  @override
  State<_TimeZonePicker> createState() => _TimeZonePickerState();
}

class _TimeZonePickerState extends State<_TimeZonePicker> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final zones = widget.zones
        .where((z) => '$z ${_zoneLabel(z)}'
            .toLowerCase()
            .contains(_query.toLowerCase().trim()))
        .toList();
    return Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
            title: const Text('בחירת אזור זמן'),
            content: SizedBox(
                width: 430,
                height: MediaQuery.sizeOf(context).height * .5,
                child: Column(children: [
                  TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                          labelText: 'חיפוש אזור זמן',
                          prefixIcon: Icon(Icons.search)),
                      onChanged: (v) => setState(() => _query = v)),
                  const SizedBox(height: 8),
                  Expanded(
                      child: zones.isEmpty
                          ? const Center(child: Text('לא נמצאו אזורי זמן'))
                          : ListView.builder(
                              itemCount: zones.length,
                              itemBuilder: (_, i) => ListTile(
                                  title: Text(_zoneLabel(zones[i])),
                                  trailing: zones[i] == widget.selected
                                      ? const Icon(Icons.check, color: _blue)
                                      : null,
                                  onTap: () =>
                                      Navigator.pop(context, zones[i])))),
                ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('ביטול'))
            ]));
  }
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
  int repeatInterval = 1;
  final Set<int> repeatWeekdays = {};
  bool weekdaysChanged = false;
  String repeatEnd = 'count', editScope = 'single';
  late DateTime repeatUntil;
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
    repeatWeekdays.add(start.weekday);
    repeatUntil = _day(start).add(const Duration(days: 28));
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
    final d = await showHebrewDatePicker(
        context: context,
        initialDate: original,
        firstDate: DateTime.utc(2020),
        lastDate: DateTime.utc(2100));
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
        if (!weekdaysChanged) {
          repeatWeekdays
            ..clear()
            ..add(start.weekday);
        }
        if (!end.isAfter(start)) {
          end = start.add(Duration(hours: allDay ? 24 : 1));
        }
      } else {
        end = next;
      }
    });
  }

  Future<void> pickRepeatUntil() async {
    final selected = await showHebrewDatePicker(
        context: context,
        initialDate: repeatUntil,
        firstDate: _day(start),
        lastDate: DateTime.utc(2100, 12, 31));
    if (selected != null && mounted) {
      setState(() => repeatUntil = selected);
    }
  }

  DateTime get firstRepeatStart {
    if (repeat == 'weekly' && repeatWeekdays.isNotEmpty) {
      for (var offset = 0; offset < 7; offset++) {
        final candidate = start.add(Duration(days: offset));
        if (repeatWeekdays.contains(candidate.weekday)) return candidate;
      }
    }
    return start;
  }

  String get repeatSummary {
    final frequency = switch (repeat) {
      'daily' => repeatInterval == 1 ? 'כל יום' : 'כל $repeatInterval ימים',
      'weekly' => repeatWeekdays.isEmpty
          ? 'יש לבחור ימי שבוע'
          : 'בכל שבוע בימי ${[
              7,
              1,
              2,
              3,
              4,
              5,
              6
            ].where(repeatWeekdays.contains).map((d) => _weekdays[d % 7]).join(', ')}',
      'monthly' => 'בכל חודש לועזי בתאריך ${start.day}',
      _ => '',
    };
    final termination = repeatEnd == 'until'
        ? 'עד ${HebrewDate.fromGregorian(repeatUntil).label} (${_dayLabel(repeatUntil)}), כולל יום זה'
        : '${int.tryParse(count.text) ?? '—'} מופעים בסך הכול';
    return '$frequency, ${allDay ? 'כל היום' : 'בשעה \u2066${_time(start)}\u2069'}; החל מ־${_dayLabel(firstRepeatStart)}; $termination.';
  }

  Future<void> save() async {
    if (saving) return;
    if (title.text.trim().isEmpty || !end.isAfter(start)) {
      setState(() => error = 'יש להזין כותרת ושעת סיום אחרי ההתחלה');
      return;
    }
    if (widget.event == null && repeat != 'none') {
      final occurrences = int.tryParse(count.text);
      String? recurrenceError;
      if (repeat == 'weekly' && repeatWeekdays.isEmpty) {
        recurrenceError = 'יש לבחור לפחות יום אחד בשבוע';
      } else if (repeatEnd == 'count' &&
          (occurrences == null || occurrences < 1 || occurrences > 104)) {
        recurrenceError = 'יש להזין מספר מופעים בין 1 ל־104';
      } else if (repeatEnd == 'until' && repeatUntil.isBefore(_day(start))) {
        recurrenceError = 'תאריך סיום החזרה חייב להיות ביום ההתחלה או אחריו';
      } else if (repeatEnd == 'until' &&
          repeatUntil.isBefore(_day(firstRepeatStart))) {
        recurrenceError = 'אין מופעים בימים שנבחרו עד תאריך הסיום';
      }
      if (recurrenceError != null) {
        setState(() => error = recurrenceError);
        return;
      }
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
            if (widget.event == null && repeat != 'none') ...{
              if (repeat == 'daily') 'interval': repeatInterval,
              if (repeat == 'weekly')
                'weekdays': repeatWeekdays.toList()..sort(),
              'end_type': repeatEnd,
              if (repeatEnd == 'count') 'count': int.parse(count.text),
              if (repeatEnd == 'until') 'until': _date(repeatUntil),
            },
            'invitees': invitees.toList(),
            if (widget.event != null) ...{
              'version': widget.event!['version'],
              'scope': editScope,
              if (editScope == 'series')
                'series_revision': widget.event!['series_revision'],
            }
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
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
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
                          isExpanded: true,
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
                            key: const ValueKey('calendar-repeat'),
                            initialValue: repeat,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: 'חזרה'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'none', child: Text('חד־פעמי')),
                              DropdownMenuItem(
                                  value: 'daily', child: Text('יומי')),
                              DropdownMenuItem(
                                  value: 'weekly', child: Text('שבועי')),
                              DropdownMenuItem(
                                  value: 'monthly',
                                  child: Text('כל חודש (לועזי)'))
                            ],
                            onChanged: saving
                                ? null
                                : (v) => setState(() => repeat = v!)),
                        if (repeat == 'daily')
                          DropdownButtonFormField<int>(
                              key: const ValueKey('calendar-repeat-interval'),
                              initialValue: repeatInterval,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                  labelText: 'מרווח בין מופעים'),
                              items: [
                                for (var days = 1; days <= 7; days++)
                                  DropdownMenuItem(
                                      value: days,
                                      child: Text(days == 1
                                          ? 'כל יום'
                                          : 'כל $days ימים'))
                              ],
                              onChanged: saving
                                  ? null
                                  : (v) => setState(() => repeatInterval = v!)),
                        if (repeat == 'weekly') ...[
                          const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text('באילו ימים בשבוע?')),
                          Wrap(spacing: 6, runSpacing: 4, children: [
                            for (final day in [7, 1, 2, 3, 4, 5, 6])
                              FilterChip(
                                  key: ValueKey('calendar-repeat-weekday-$day'),
                                  label: Text([
                                    'א׳',
                                    'ב׳',
                                    'ג׳',
                                    'ד׳',
                                    'ה׳',
                                    'ו׳',
                                    'ש׳'
                                  ][day % 7]),
                                  tooltip: _weekdays[day % 7],
                                  selected: repeatWeekdays.contains(day),
                                  onSelected: saving
                                      ? null
                                      : (selected) => setState(() {
                                            weekdaysChanged = true;
                                            if (selected) {
                                              repeatWeekdays.add(day);
                                            } else {
                                              repeatWeekdays.remove(day);
                                            }
                                          }))
                          ])
                        ],
                        if (repeat == 'monthly')
                          const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                  'החזרה לפי התאריך הלועזי. בחודש קצר יותר האירוע יחול ביום האחרון בחודש.')),
                        if (repeat != 'none') ...[
                          DropdownButtonFormField<String>(
                              key: const ValueKey('calendar-repeat-end'),
                              initialValue: repeatEnd,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                  labelText: 'סיום החזרה'),
                              items: const [
                                DropdownMenuItem(
                                    value: 'count',
                                    child: Text('לאחר מספר מופעים')),
                                DropdownMenuItem(
                                    value: 'until', child: Text('בתאריך'))
                              ],
                              onChanged: saving
                                  ? null
                                  : (v) => setState(() => repeatEnd = v!)),
                          if (repeatEnd == 'count')
                            TextField(
                                key: const ValueKey('calendar-repeat-count'),
                                controller: count,
                                enabled: !saving,
                                keyboardType: TextInputType.number,
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                    labelText: 'מספר מופעים (כולל הראשון)',
                                    helperText: 'בין 1 ל־104 מופעים')),
                          if (repeatEnd == 'until')
                            ListTile(
                                key: const ValueKey('calendar-repeat-until'),
                                contentPadding: EdgeInsets.zero,
                                title: const Text('תאריך סיום החזרה'),
                                subtitle: Text(
                                    '${HebrewDate.fromGregorian(repeatUntil).label}\n${_dayLabel(repeatUntil)} (כולל)'),
                                trailing: const Icon(Icons.edit_calendar),
                                onTap: saving ? null : pickRepeatUntil),
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(repeatSummary,
                                  key: const ValueKey(
                                      'calendar-repeat-summary'))),
                          const Text('ניתן ליצור עד 104 מופעים בכל סדרה.',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.blueGrey))
                        ]
                      ],
                      if (widget.event?['series_id'] != null) ...[
                        DropdownButtonFormField<String>(
                            key: const ValueKey('calendar-edit-scope'),
                            initialValue: editScope,
                            isExpanded: true,
                            decoration: const InputDecoration(
                                labelText: 'החלת השינויים'),
                            items: const [
                              DropdownMenuItem(
                                  value: 'single', child: Text('מופע זה בלבד')),
                              DropdownMenuItem(
                                  value: 'series', child: Text('כל הסדרה'))
                            ],
                            onChanged: saving
                                ? null
                                : (v) => setState(() => editScope = v!)),
                        Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(editScope == 'single'
                                ? 'השינויים יישמרו במופע זה בלבד.'
                                : 'פרטי האירוע, השעות, התזכורת והמוזמנים יעודכנו בכל המופעים שלא בוטלו. שינוי תאריך מזיז את כל הסדרה באותו מספר ימים; תדירות החזרה נשארת כפי שנקבעה.'))
                      ],
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
