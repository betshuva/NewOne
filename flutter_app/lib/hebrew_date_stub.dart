/// Formats a Gregorian date using the fixed Hebrew calendar on native
/// platforms, where the browser's `Intl` Hebrew calendar is unavailable.
String fullHebrewDate(DateTime date) {
  final localDate = date.toLocal();
  final hebrew = _toHebrewDate(localDate);
  const weekdays = <String>[
    'יום שני',
    'יום שלישי',
    'יום רביעי',
    'יום חמישי',
    'יום שישי',
    'יום שבת',
    'יום ראשון',
  ];
  final months = <String>[
    'בתשרי',
    'בחשוון',
    'בכסלו',
    'בטבת',
    'בשבט',
    if (_isLeapYear(hebrew.year)) 'באדר א׳',
    'באדר',
    'בניסן',
    'באייר',
    'בסיוון',
    'בתמוז',
    'באב',
    'באלול',
  ];
  return '${weekdays[localDate.weekday - 1]}, '
      '${_hebrewNumber(hebrew.day)} ${months[hebrew.month - 1]} '
      '${_hebrewNumber(hebrew.year, omitThousands: true)}';
}

({int year, int month, int day}) _toHebrewDate(DateTime date) {
  final absolute = DateTime.utc(date.year, date.month, date.day)
          .difference(DateTime.utc(1, 1, 1))
          .inDays +
      1;
  var year = ((absolute + 1373428) ~/ 366).clamp(1, 9999);
  while (absolute >= _hebrewNewYear(year + 1)) {
    year++;
  }
  while (absolute < _hebrewNewYear(year)) {
    year--;
  }

  var dayInYear = absolute - _hebrewNewYear(year);
  var month = 1;
  for (final length in _hebrewMonthLengths(year)) {
    if (dayInYear < length) break;
    dayInYear -= length;
    month++;
  }
  return (year: year, month: month, day: dayInYear + 1);
}

int _hebrewNewYear(int year) => _hebrewCalendarElapsedDays(year) - 1373428;

int _hebrewCalendarElapsedDays(int year) {
  final months = (235 * year - 234) ~/ 19;
  final parts = 204 + 793 * (months % 1080);
  final hours = 5 + 12 * months + 793 * (months ~/ 1080) + parts ~/ 1080;
  var day = 1 + 29 * months + hours ~/ 24;
  final remainingParts = 1080 * (hours % 24) + parts % 1080;
  if (remainingParts >= 19440 ||
      (day % 7 == 2 && remainingParts >= 9924 && !_isLeapYear(year)) ||
      (day % 7 == 1 && remainingParts >= 16789 && _isLeapYear(year - 1))) {
    day++;
  }
  if (day % 7 == 0 || day % 7 == 3 || day % 7 == 5) day++;
  return day;
}

bool _isLeapYear(int year) => (7 * year + 1) % 19 < 7;

List<int> _hebrewMonthLengths(int year) {
  final yearLength = _hebrewNewYear(year + 1) - _hebrewNewYear(year);
  return <int>[
    30,
    yearLength % 10 == 5 ? 30 : 29,
    yearLength % 10 == 3 ? 29 : 30,
    29,
    30,
    if (_isLeapYear(year)) 30,
    29,
    30,
    29,
    30,
    29,
    30,
    29,
  ];
}

String _hebrewNumber(int number, {bool omitThousands = false}) {
  var value = omitThousands ? number % 1000 : number;
  const letters = <(int, String)>[
    (400, 'ת'),
    (300, 'ש'),
    (200, 'ר'),
    (100, 'ק'),
    (90, 'צ'),
    (80, 'פ'),
    (70, 'ע'),
    (60, 'ס'),
    (50, 'נ'),
    (40, 'מ'),
    (30, 'ל'),
    (20, 'כ'),
    (10, 'י'),
    (9, 'ט'),
    (8, 'ח'),
    (7, 'ז'),
    (6, 'ו'),
    (5, 'ה'),
    (4, 'ד'),
    (3, 'ג'),
    (2, 'ב'),
    (1, 'א'),
  ];
  final result = StringBuffer();
  while (value > 0) {
    if (value == 15 || value == 16) {
      result.write(value == 15 ? 'טו' : 'טז');
      break;
    }
    final part = letters.firstWhere((entry) => entry.$1 <= value);
    result.write(part.$2);
    value -= part.$1;
  }
  final text = result.toString();
  if (text.length == 1) return '$text׳';
  return '${text.substring(0, text.length - 1)}״${text.substring(text.length - 1)}';
}
