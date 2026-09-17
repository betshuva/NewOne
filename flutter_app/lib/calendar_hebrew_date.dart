/// A Hebrew calendar date with no time of day, location, or sunset adjustment.
///
/// Month numbers follow the traditional Nisan=1 numbering; the civil year
/// starts with Tishrei=7. Adar is 12, and leap years also contain Adar II=13.
class HebrewDate {
  const HebrewDate(this.year, this.month, this.day)
      : assert(year > 0),
        assert(month >= 1 && month <= 13),
        assert(day >= 1 && day <= 30);

  final int year;
  final int month;
  final int day;

  static final DateTime _gregorianEpoch = DateTime.utc(1, 1, 1);

  /// Converts the supplied civil year/month/day, without changing its zone.
  factory HebrewDate.fromGregorian(DateTime date) {
    final absolute = DateTime.utc(date.year, date.month, date.day)
            .difference(_gregorianEpoch)
            .inDays +
        1;
    if (absolute < _newYear(1)) {
      throw RangeError('Date precedes the Hebrew calendar epoch');
    }
    var year = (absolute + 1373428) ~/ 366;
    if (year < 1) year = 1;
    while (absolute >= _newYear(year + 1)) {
      year++;
    }
    while (absolute < _newYear(year)) {
      year--;
    }
    var remaining = absolute - _newYear(year);
    for (final month in monthsInYear(year)) {
      final length = monthLength(year, month);
      if (remaining < length) return HebrewDate(year, month, remaining + 1);
      remaining -= length;
    }
    throw StateError('Invalid Hebrew year length');
  }

  /// Returns UTC midnight for this date so calendar arithmetic avoids DST.
  DateTime toGregorian() {
    final length = daysInMonth;
    if (day < 1 || day > length) {
      throw RangeError.range(day, 1, length, 'day');
    }
    var absolute = _newYear(year) + day - 1;
    for (final precedingMonth in monthsInYear(year)) {
      if (precedingMonth == month) break;
      absolute += monthLength(year, precedingMonth);
    }
    return _gregorianEpoch.add(Duration(days: absolute - 1));
  }

  bool get isLeapYear => _isLeapYear(year);
  int get daysInMonth => monthLength(year, month);
  String get monthName => monthNameFor(year, month);
  String get yearLabel => formatNumber(year);
  String get dayLabel => formatNumber(day);
  String get label => '$dayLabel ב$monthName $yearLabel';
  String get monthYearLabel => '$monthName $yearLabel';

  /// Advances through the civil month order, clamping only in the final month.
  HebrewDate addMonths(int delta) {
    var targetYear = year;
    var months = monthsInYear(targetYear);
    var index = months.indexOf(month);
    if (index < 0) throw RangeError.value(month, 'month');
    index += delta;
    while (index < 0) {
      targetYear--;
      months = monthsInYear(targetYear);
      index += months.length;
    }
    while (index >= months.length) {
      index -= months.length;
      targetYear++;
      months = monthsInYear(targetYear);
    }
    final targetMonth = months[index];
    return HebrewDate(
      targetYear,
      targetMonth,
      day.clamp(1, monthLength(targetYear, targetMonth)),
    );
  }

  /// Keeps the month and clamps the day; Adar II becomes Adar in common years.
  HebrewDate withYear(int year) {
    _checkYear(year);
    final targetMonth = month == 13 && !_isLeapYear(year) ? 12 : month;
    return HebrewDate(
      year,
      targetMonth,
      day.clamp(1, monthLength(year, targetMonth)),
    );
  }

  static List<int> monthsInYear(int year) {
    _checkYear(year);
    return <int>[
      7,
      8,
      9,
      10,
      11,
      12,
      if (_isLeapYear(year)) 13,
      1,
      2,
      3,
      4,
      5,
      6,
    ];
  }

  static String monthNameFor(int year, int month) {
    _checkMonth(year, month);
    const names = <String>[
      '',
      'ניסן',
      'אייר',
      'סיוון',
      'תמוז',
      'אב',
      'אלול',
      'תשרי',
      'חשוון',
      'כסלו',
      'טבת',
      'שבט',
      'אדר',
      'אדר ב׳',
    ];
    return month == 12 && _isLeapYear(year) ? 'אדר א׳' : names[month];
  }

  static int monthLength(int year, int month) {
    _checkMonth(year, month);
    if (month == 8 || month == 9) {
      final length = _newYear(year + 1) - _newYear(year);
      if (month == 8) return length % 10 == 5 ? 30 : 29;
      return length % 10 == 3 ? 29 : 30;
    }
    if (month == 12) return _isLeapYear(year) ? 30 : 29;
    return const <int>{2, 4, 6, 10, 13}.contains(month) ? 29 : 30;
  }

  /// Hebrew numerals with punctuation, omitting thousands in calendar years.
  static String formatNumber(int number) {
    if (number <= 0) return '';
    var value = number % 1000;
    if (value == 0) value = number ~/ 1000;
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
    final buffer = StringBuffer();
    while (value > 0) {
      if (value == 15 || value == 16) {
        buffer.write(value == 15 ? 'טו' : 'טז');
        break;
      }
      final letter = letters.firstWhere((entry) => entry.$1 <= value);
      buffer.write(letter.$2);
      value -= letter.$1;
    }
    final text = buffer.toString();
    if (text.length == 1) return '$text׳';
    return '${text.substring(0, text.length - 1)}״${text.substring(text.length - 1)}';
  }

  static bool _isLeapYear(int year) => (7 * year + 1) % 19 < 7;

  static void _checkYear(int year) {
    if (year < 1) throw RangeError.value(year, 'year');
  }

  static void _checkMonth(int year, int month) {
    _checkYear(year);
    if (month < 1 || month > (_isLeapYear(year) ? 13 : 12)) {
      throw RangeError.value(month, 'month');
    }
  }

  // Fixed-calendar arithmetic already used by hebrew_date_stub.dart, expressed
  // in absolute Gregorian days (1 January 1 = day 1). The molad and postponement
  // rules are described in NASA's Explanatory Supplement, section 3.1:
  // https://eclipse.gsfc.nasa.gov/SEhelp/calendars.html
  static int _newYear(int year) {
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
    return day - 1373428;
  }

  @override
  bool operator ==(Object other) =>
      other is HebrewDate &&
      year == other.year &&
      month == other.month &&
      day == other.day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => 'HebrewDate($year, $month, $day)';
}
