import 'package:flutter/material.dart';

const _responseLabels = <String, String>{
  'accepted': 'אישר/ה',
  'maybe': 'אולי',
  'pending': 'טרם ענה/תה',
  'declined': 'סירב/ה',
};

bool _isOwner(Map<String, dynamic> event) => event['response'] == null;

Map<String, int>? _summary(Map<String, dynamic> event) {
  if (!_isOwner(event)) return null;
  final value = event['attendee_summary'];
  if (value is! Map || value['total'] is! num) return null;
  return {
    for (final key in ['total', ..._responseLabels.keys])
      key: value[key] is num ? (value[key] as num).toInt() : 0,
  };
}

String _attendance(Map<String, dynamic> event, [Map<String, int>? counts]) {
  if (!_isOwner(event)) {
    return 'תשובתך: ${{
          'accepted': 'אישור',
          'maybe': 'אולי',
          'pending': 'טרם נענתה',
          'declined': 'דחייה',
        }[event['response']] ?? 'טרם נענתה'}';
  }
  final summary = counts ?? _summary(event);
  if (summary == null) return '';
  if (summary['total'] == 0) return 'אירוע אישי';
  return '${summary['accepted']} מתוך ${summary['total']} מוזמנים אישרו';
}

String _breakdown(Map<String, int> counts) =>
    '${counts['accepted']} אישרו · ${counts['maybe']} אולי · '
    '${counts['pending']} טרם ענו · ${counts['declined']} סירבו';

String _text(Object? value) => value?.toString().trim() ?? '';

String _reminderLabel(Object? value) {
  if (value is! num || value < 0) return 'ללא';
  return switch (value) {
    0 => 'בשעת האירוע',
    60 => 'שעה לפני',
    1440 => 'יום לפני',
    _ => '$value דקות לפני',
  };
}

String _timeLabel(Map<String, dynamic> event) {
  if (event['all_day'] == true) return 'כל היום';
  String clock(Object? value) {
    final match = RegExp(r'T(\d{2}:\d{2})').firstMatch(_text(value));
    return match?.group(1) ?? '';
  }

  final start = clock(event['start_local']);
  final end = clock(event['end_local']);
  // Keep the start and end in chronological reading order within Hebrew text.
  return start.isNotEmpty && end.isNotEmpty ? '\u2066$start–$end\u2069' : start;
}

/// Event content that respects the calendar's fixed height and overlap width.
class CalendarEventSummary extends StatelessWidget {
  final Map<String, dynamic> event;
  final Color color;
  final bool compact;

  const CalendarEventSummary({
    super.key,
    required this.event,
    required this.color,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final title = _text(event['title']);
    final time = _timeLabel(event);
    final heading = [title, time].where((s) => s.isNotEmpty).join(' · ');
    final attendance = _attendance(event);
    final counts = _summary(event);
    final location = _text(event['location']);
    final notes = _text(event['notes']);
    final notePreview = notes.runes.length > 200
        ? '${String.fromCharCodes(notes.runes.take(200))}…'
        : notes;
    final reminder = event['reminder_minutes'];
    final description = [
      heading,
      if (attendance.isNotEmpty) attendance,
      if (counts != null && counts['total'] != 0) _breakdown(counts),
      if (location.isNotEmpty) 'מקום: $location',
      if (notePreview.isNotEmpty) notePreview,
      'תזכורת: ${_reminderLabel(reminder)}',
    ].join('\n');
    final style = DefaultTextStyle.of(context).style.copyWith(
          fontSize: 11,
          height: 1.1,
          color: color,
          fontWeight: FontWeight.w500,
        );
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);

    return Semantics(
      label: description,
      excludeSemantics: true,
      child: Tooltip(
        message: description,
        excludeFromSemantics: true,
        child: LayoutBuilder(builder: (context, constraints) {
          final painter = TextPainter(
            text: TextSpan(text: heading, style: style),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final lineHeight = painter.height;
          final lines = compact || !constraints.hasBoundedHeight
              ? 1
              : ((constraints.maxHeight + 2) / (lineHeight + 2)).floor();
          String inline = heading;
          if (attendance.isNotEmpty && lines < 2) {
            final brief = counts != null && counts['total'] != 0
                ? '${counts['accepted']} מתוך ${counts['total']} אישרו'
                : attendance;
            final candidate = '$heading · $brief';
            painter.text = TextSpan(text: candidate, style: style);
            painter.layout();
            if (painter.width <= constraints.maxWidth) inline = candidate;
          }
          painter.dispose();

          Widget line(String text, String key) => Text(
                text,
                key: ValueKey(key),
                style: style,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              );

          final additional = [
            if (attendance.isNotEmpty) attendance,
            if (location.isNotEmpty) 'מקום: $location',
          ];
          return ClipRect(
            child: lines < 2 || additional.isEmpty
                ? line(inline, 'calendar-event-heading')
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      line(heading, 'calendar-event-heading'),
                      for (var i = 0;
                          i < additional.length && i < lines - 1;
                          i++) ...[
                        const SizedBox(height: 2),
                        line(additional[i], 'calendar-event-extra-$i'),
                      ],
                    ],
                  ),
          );
        }),
      ),
    );
  }
}

/// Loads owner-only invitee details once per open, with an explicit retry.
class CalendarEventAttendanceDetails extends StatefulWidget {
  final Map<String, dynamic> event;
  final Future<List<Map<String, dynamic>>> Function() loadAttendees;

  const CalendarEventAttendanceDetails({
    super.key,
    required this.event,
    required this.loadAttendees,
  });

  @override
  State<CalendarEventAttendanceDetails> createState() =>
      _CalendarEventAttendanceDetailsState();
}

class _CalendarEventAttendanceDetailsState
    extends State<CalendarEventAttendanceDetails> {
  Future<List<Map<String, dynamic>>>? _attendees;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CalendarEventAttendanceDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event['id'] != widget.event['id'] ||
        _isOwner(oldWidget.event) != _isOwner(widget.event)) {
      _load();
    }
  }

  void _load() {
    _attendees =
        _isOwner(widget.event) ? Future.sync(widget.loadAttendees) : null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_isOwner(widget.event)) return Text(_attendance(widget.event));
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _attendees,
      builder: (context, snapshot) {
        final loaded = snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasError;
        final attendees = loaded
            ? (snapshot.data ?? []).where((attendee) {
                final owner = widget.event['owner_id'];
                return owner == null || attendee['user_id'] != owner;
              }).toList()
            : <Map<String, dynamic>>[];
        final counts = loaded
            ? <String, int>{
                'total': attendees.length,
                for (final response in _responseLabels.keys)
                  response: attendees
                      .where((a) =>
                          (_responseLabels.containsKey(a['response'])
                              ? a['response']
                              : 'pending') ==
                          response)
                      .length,
              }
            : _summary(widget.event);
        final attendance = _attendance(widget.event, counts);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Text('מוזמנים',
                style: TextStyle(fontWeight: FontWeight.bold)),
            if (attendance.isNotEmpty)
              Text(attendance,
                  key: const ValueKey('calendar-attendance-total')),
            if (counts != null && counts['total'] != 0)
              Text(_breakdown(counts),
                  key: const ValueKey('calendar-attendance-breakdown')),
            if (!loaded && !snapshot.hasError)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 8),
                    Flexible(child: Text('טוען תשובות מוזמנים…')),
                  ],
                ),
              ),
            if (snapshot.hasError) ...[
              const Text('לא ניתן לטעון את תשובות המוזמנים.'),
              TextButton.icon(
                key: const ValueKey('calendar-attendance-retry'),
                onPressed: () => setState(_load),
                icon: const Icon(Icons.refresh),
                label: const Text('ניסיון נוסף'),
              ),
            ],
            if (loaded)
              for (final attendee in attendees)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${_text(attendee['name']).isEmpty ? 'מוזמן/ת' : _text(attendee['name'])} · '
                    '${_responseLabels[attendee['response']] ?? _responseLabels['pending']}',
                    key: ValueKey('calendar-attendee-${attendee['user_id']}'),
                  ),
                ),
          ],
        );
      },
    );
  }
}
