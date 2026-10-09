/// Reads explicit Google Calendar event templates without opening the link or
/// fetching a private event by eid. Links lacking complete dates remain normal
/// shared text. IANA zone validity is checked again by the calendar preview API.
///
/// Google documents TEMPLATE dates, stz, etz, text, details and location at:
/// https://developers.google.com/workspace/calendar/api/concepts/inviting-attendees-to-events
Map<String, dynamic>? parseSharedCalendarLink(String text) {
  if (text.isEmpty || text.length > 16 * 1024) return null;
  try {
    final found = <Map<String, dynamic>>[];
    for (final match
        in RegExp(r'https://[^\s<>"\u0000-\u001f]+').allMatches(text)) {
      final candidate = match.group(0)!;
      final uri = Uri.tryParse(candidate);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'calendar.google.com' ||
          uri.userInfo.isNotEmpty ||
          (uri.hasPort && uri.port != 443) ||
          !RegExp(r'^/calendar/(?:u/\d+/)?(?:r/eventedit|render|eventedit|event)/?$')
              .hasMatch(uri.path)) {
        continue;
      }
      final query = uri.queryParametersAll;
      const fields = [
        'action',
        'dates',
        'ctz',
        'stz',
        'etz',
        'text',
        'details',
        'location',
        'recur',
        'rrule',
      ];
      if (fields.any((field) => (query[field]?.length ?? 0) > 1) ||
          query['action']?.single != 'TEMPLATE') {
        continue;
      }
      final dates = (query['dates']?.single ?? '').split('/');
      if (dates.length != 2) continue;
      final start = _explicitDate(dates[0]);
      final end = _explicitDate(dates[1]);
      if (start == null ||
          end == null ||
          start.isDate != end.isDate ||
          start.isUtc != end.isUtc ||
          !end.value.isAfter(start.value) ||
          end.value.difference(start.value) > const Duration(days: 31) ||
          start.value.year < 2020 ||
          start.value.year > 2100) {
        continue;
      }
      final ctz = query['ctz']?.single;
      final stz = query['stz']?.single;
      final etz = query['etz']?.single;
      final zones = [ctz, stz, etz].whereType<String>();
      if (zones.any((zone) => !_zoneSyntax.hasMatch(zone))) continue;
      final startZone = stz ?? ctz;
      final endZone = etz ?? ctz ?? startZone;
      // Civil times in two zones cannot be converted safely in this pure
      // helper. Explicit UTC instants can keep different origin zones.
      if (!start.isDate &&
          !start.isUtc &&
          (startZone == null || startZone != endZone)) {
        continue;
      }
      final draft = <String, dynamic>{
        'title': query['text']?.single ?? 'אירוע משותף',
        'notes': query['details']?.single ?? '',
        'location': query['location']?.single ?? '',
        'all_day': start.isDate,
        if (startZone != null) 'timezone': startZone,
      };
      if (start.isUtc && !start.isDate) {
        draft['start_epoch_ms'] = start.value.millisecondsSinceEpoch;
        draft['end_epoch_ms'] = end.value.millisecondsSinceEpoch;
        draft['timezone'] ??= 'UTC';
      } else {
        // All-day end is exclusive. Calendar preview retains these dates in
        // its chosen zone, rather than shifting UTC midnight to another day.
        draft['start'] = _civil(start.value);
        draft['end'] = _civil(end.value);
      }
      final recurrence = query['recur']?.single ?? query['rrule']?.single;
      if (recurrence != null && recurrence.isNotEmpty) {
        draft['recurrence'] = recurrence;
      }
      found.add(draft);
    }
    // Do not silently choose one event when a share contains several templates.
    return found.length == 1 ? found.single : null;
  } on FormatException {
    return null;
  }
}

final _zoneSyntax = RegExp(r'^[A-Za-z][A-Za-z0-9_+\-]*(?:/[A-Za-z0-9_+\-]+)*$');
String _civil(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}T${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

class _SharedDate {
  final DateTime value;
  final bool isDate, isUtc;
  const _SharedDate(this.value, {required this.isDate, required this.isUtc});
}

_SharedDate? _explicitDate(String raw) {
  final match =
      RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$')
          .firstMatch(raw);
  if (match == null) return null;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final hour = int.parse(match[4] ?? '0');
  final minute = int.parse(match[5] ?? '0');
  final second = int.parse(match[6] ?? '0');
  final value = DateTime.utc(year, month, day, hour, minute, second);
  if (value.year != year ||
      value.month != month ||
      value.day != day ||
      value.hour != hour ||
      value.minute != minute ||
      value.second != second) {
    return null;
  }
  return _SharedDate(value, isDate: match[4] == null, isUtc: match[7] == 'Z');
}
