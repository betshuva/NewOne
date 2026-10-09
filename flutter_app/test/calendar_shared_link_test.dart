import 'package:betshuva/calendar_shared_link.dart';
import 'package:flutter_test/flutter_test.dart';

String template(Map<String, String> parameters,
        {String host = 'calendar.google.com',
        String path = '/calendar/r/eventedit'}) =>
    Uri.https(host, path, {'action': 'TEMPLATE', ...parameters}).toString();

void main() {
  test('explicit UTC template preserves instants and Hebrew event details', () {
    final draft = parseSharedCalendarLink(template({
      'dates': '20261020T060000Z/20261020T070000Z',
      'text': 'פגישה משותפת',
      'details': 'הערה\nשורה נוספת',
      'location': 'ירושלים',
      'stz': 'Asia/Jerusalem',
      'etz': 'Asia/Jerusalem',
      'add': 'someone@example.test',
    }))!;
    expect(draft['title'], 'פגישה משותפת');
    expect(draft['notes'], 'הערה\nשורה נוספת');
    expect(draft['timezone'], 'Asia/Jerusalem');
    expect(draft['start_epoch_ms'],
        DateTime.utc(2026, 10, 20, 6).millisecondsSinceEpoch);
    expect(draft['end_epoch_ms'],
        DateTime.utc(2026, 10, 20, 7).millisecondsSinceEpoch);
    expect(draft['all_day'], false);
    expect(draft.containsKey('invitees'), false);
  });

  test('all-day dates preserve exclusive end without shifting midnight', () {
    final draft =
        parseSharedCalendarLink(template({'dates': '20261020/20261023'}))!;
    expect(draft['start'], '2026-10-20T00:00');
    expect(draft['end'], '2026-10-23T00:00');
    expect(draft['all_day'], true);
    expect(draft.containsKey('timezone'), false);
  });

  test('explicit civil times require one timezone and preserve civil values',
      () {
    final draft = parseSharedCalendarLink(template({
      'dates': '20261020T090000/20261020T100000',
      'ctz': 'Asia/Jerusalem'
    }))!;
    expect(draft['timezone'], 'Asia/Jerusalem');
    expect(draft['start'], '2026-10-20T09:00');
    expect(draft['end'], '2026-10-20T10:00');
    expect(
        parseSharedCalendarLink(
            template({'dates': '20261020T090000/20261020T100000'})),
        isNull);
    expect(
        parseSharedCalendarLink(template({
          'dates': '20261020T090000/20261020T100000',
          'stz': 'Asia/Tokyo',
          'etz': 'America/New_York'
        })),
        isNull);
  });

  test('UTC values retain exact instants even with different origin zones', () {
    final draft = parseSharedCalendarLink(template({
      'dates': '20261020T060000Z/20261020T170000Z',
      'stz': 'Asia/Tokyo',
      'etz': 'America/Los_Angeles'
    }))!;
    expect(draft['timezone'], 'Asia/Tokyo');
    expect(draft['end_epoch_ms'],
        DateTime.utc(2026, 10, 20, 17).millisecondsSinceEpoch);
  });

  test('private eid and incomplete templates remain ordinary shared links', () {
    for (final link in [
      'https://calendar.google.com/calendar/event?eid=private-id',
      template({'eid': 'private-id', 'text': 'אירוע'}),
      template({'dates': '20261020T090000Z'}),
      'ניפגש ביום רביעי בשעה 10:00',
    ]) {
      expect(parseSharedCalendarLink(link), isNull);
    }
  });

  test('host, action, credentials and port cannot masquerade as a template',
      () {
    final valid = template({'dates': '20261020T090000Z/20261020T100000Z'});
    for (final link in [
      valid.replaceFirst(
          'calendar.google.com', 'calendar.google.com.evil.test'),
      valid.replaceFirst('https:', 'http:'),
      valid.replaceFirst('calendar.google.com', 'attacker@calendar.google.com'),
      valid.replaceFirst('calendar.google.com', 'calendar.google.com:444'),
      valid.replaceFirst('action=TEMPLATE', 'action=VIEW'),
      valid.replaceFirst('/calendar/r/eventedit', '/unrelated'),
      '$valid&action=TEMPLATE',
      '$valid&dates=20261021T090000Z%2F20261021T100000Z',
    ]) {
      expect(parseSharedCalendarLink(link), isNull, reason: link);
    }
  });

  test('calendar validation rejects invalid and normalized-away dates', () {
    for (final dates in [
      '20260230T090000Z/20260301T100000Z',
      '20261020T246000Z/20261021T100000Z',
      '20261020T090000Z/20261020T090000Z',
      '20261020T100000Z/20261020T090000Z',
      '20261020/20261020T100000Z',
      '20261020T090000Z/20261020T100000',
      '20261020/20261220',
    ]) {
      expect(parseSharedCalendarLink(template({'dates': dates})), isNull,
          reason: dates);
    }
    expect(parseSharedCalendarLink(template({'dates': '20240229/20240301'})),
        isNotNull);
  });

  test(
      'one template in shared text is recognized; multiple events are not silently reduced',
      () {
    final first = template({'dates': '20261020T090000Z/20261020T100000Z'});
    final second = template({'dates': '20261021T090000Z/20261021T100000Z'});
    expect(parseSharedCalendarLink('האירוע שלנו:\n$first'), isNotNull);
    expect(parseSharedCalendarLink('$first\n$second'), isNull);
    expect(parseSharedCalendarLink('x' * (16 * 1024) + first), isNull);
  });

  test('recurrence metadata is retained for explicit single-occurrence warning',
      () {
    final draft = parseSharedCalendarLink(template({
      'dates': '20261020T090000Z/20261020T100000Z',
      'recur': 'RRULE:FREQ=YEARLY'
    }))!;
    expect(draft['recurrence'], 'RRULE:FREQ=YEARLY');
  });

  test(
      'legacy render and account-scoped eventedit paths use the same explicit dates',
      () {
    for (final path in ['/calendar/render', '/calendar/u/0/r/eventedit']) {
      expect(
          parseSharedCalendarLink(template(
              {'dates': '20261020T090000Z/20261020T100000Z'},
              path: path)),
          isNotNull);
    }
  });
}
