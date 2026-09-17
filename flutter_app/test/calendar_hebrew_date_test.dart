import 'package:betshuva/calendar_hebrew_date.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('civil Gregorian conversion', () {
    // Independent ICU/Intl Hebrew calendar fixtures. Rosh Hashanah 5787 and
    // Purim 5784 additionally match the Hebcal date converter:
    // https://www.hebcal.com/converter?g2h=1&gd=12&gm=9&gy=2026
    // https://www.hebcal.com/converter?g2h=1&gd=24&gm=3&gy=2024
    const dates = <(int, int, int, HebrewDate)>[
      (1900, 1, 1, HebrewDate(5660, 11, 1)),
      (1948, 5, 14, HebrewDate(5708, 2, 5)),
      (2000, 1, 1, HebrewDate(5760, 10, 23)),
      (2023, 9, 16, HebrewDate(5784, 7, 1)),
      (2024, 2, 10, HebrewDate(5784, 12, 1)),
      (2024, 3, 11, HebrewDate(5784, 13, 1)),
      (2024, 3, 24, HebrewDate(5784, 13, 14)),
      (2024, 4, 23, HebrewDate(5784, 1, 15)),
      (2025, 9, 23, HebrewDate(5786, 7, 1)),
      (2026, 9, 11, HebrewDate(5786, 6, 29)),
      (2026, 9, 12, HebrewDate(5787, 7, 1)),
      (2026, 9, 17, HebrewDate(5787, 7, 6)),
      (2100, 3, 1, HebrewDate(5860, 12, 20)),
      (2200, 12, 31, HebrewDate(5961, 10, 24)),
    ];

    for (final entry in dates) {
      test('${entry.$1}-${entry.$2}-${entry.$3} is ${entry.$4}', () {
        final date = DateTime.utc(entry.$1, entry.$2, entry.$3);
        expect(HebrewDate.fromGregorian(date), entry.$4);
        expect(entry.$4.toGregorian(), date);
      });
    }

    test('uses civil fields for local and UTC dates at any time', () {
      const expected = HebrewDate(5787, 7, 1);
      expect(HebrewDate.fromGregorian(DateTime(2026, 9, 12)), expected);
      expect(HebrewDate.fromGregorian(DateTime(2026, 9, 12, 23, 59)), expected);
      expect(HebrewDate.fromGregorian(DateTime.utc(2026, 9, 12, 23)), expected);
      expect(expected.toGregorian().isUtc, isTrue);
      expect(expected.toGregorian().hour, 0);
    });

    test('round trips every day in Gregorian years 1900 through 2200', () {
      final end = DateTime.utc(2201);
      var date = DateTime.utc(1900);
      while (date.isBefore(end)) {
        final hebrew = HebrewDate.fromGregorian(date);
        expect(hebrew.toGregorian(), date, reason: date.toIso8601String());
        date = date.add(const Duration(days: 1));
      }
    });

    test('all years have permitted lengths and Rosh Hashanah weekdays', () {
      for (var year = 5660; year <= 5961; year++) {
        final start = HebrewDate(year, 7, 1);
        final next = HebrewDate(year + 1, 7, 1);
        final days = next.toGregorian().difference(start.toGregorian()).inDays;
        expect(
            days, isIn(start.isLeapYear ? [383, 384, 385] : [353, 354, 355]));
        expect(start.toGregorian().weekday, isNot(isIn([3, 5, 7])));
        expect(
          HebrewDate.monthsInYear(year).fold<int>(
            0,
            (total, month) => total + HebrewDate.monthLength(year, month),
          ),
          days,
        );
      }
    });
  });

  group('Hebrew month and year navigation', () {
    test('civil year starts at Tishrei and includes both leap Adars', () {
      expect(HebrewDate.monthsInYear(5786),
          [7, 8, 9, 10, 11, 12, 1, 2, 3, 4, 5, 6]);
      expect(HebrewDate.monthsInYear(5787),
          [7, 8, 9, 10, 11, 12, 13, 1, 2, 3, 4, 5, 6]);
      expect(const HebrewDate(5787, 7, 1).isLeapYear, isTrue);
      expect(const HebrewDate(5786, 7, 1).isLeapYear, isFalse);
    });

    test('crosses Elul and Tishrei in both directions', () {
      expect(const HebrewDate(5786, 6, 17).addMonths(1),
          const HebrewDate(5787, 7, 17));
      expect(const HebrewDate(5787, 7, 17).addMonths(-1),
          const HebrewDate(5786, 6, 17));
      expect(const HebrewDate(5786, 7, 17).addMonths(12),
          const HebrewDate(5787, 7, 17));
      expect(const HebrewDate(5787, 7, 17).addMonths(13),
          const HebrewDate(5788, 7, 17));
      expect(const HebrewDate(5788, 7, 17).addMonths(-25),
          const HebrewDate(5786, 7, 17));
    });

    test('steps over leap Adars without changing year at Nisan', () {
      expect(const HebrewDate(5784, 12, 20).addMonths(1),
          const HebrewDate(5784, 13, 20));
      expect(const HebrewDate(5784, 13, 20).addMonths(1),
          const HebrewDate(5784, 1, 20));
      expect(const HebrewDate(5784, 1, 20).addMonths(-1),
          const HebrewDate(5784, 13, 20));
      expect(const HebrewDate(5786, 12, 20).addMonths(1),
          const HebrewDate(5786, 1, 20));
    });

    test('clamps day 30 in short months without drifting multi-month jumps',
        () {
      expect(const HebrewDate(5784, 12, 30).addMonths(1),
          const HebrewDate(5784, 13, 29));
      expect(const HebrewDate(5784, 12, 30).addMonths(2),
          const HebrewDate(5784, 1, 30));
      expect(const HebrewDate(5786, 7, 30).addMonths(-1),
          const HebrewDate(5785, 6, 29));
      expect(const HebrewDate(5784, 7, 30).addMonths(0),
          const HebrewDate(5784, 7, 30));
    });

    test('changing years maps Adar II and clamps variable months', () {
      expect(const HebrewDate(5784, 13, 14).withYear(5785),
          const HebrewDate(5785, 12, 14));
      expect(const HebrewDate(5784, 12, 30).withYear(5785),
          const HebrewDate(5785, 12, 29));
      expect(const HebrewDate(5783, 8, 30).withYear(5784),
          const HebrewDate(5784, 8, 29));
      expect(const HebrewDate(5783, 9, 30).withYear(5784),
          const HebrewDate(5784, 9, 29));
      expect(const HebrewDate(5785, 12, 29).withYear(5787),
          const HebrewDate(5787, 12, 29));
    });

    test('rejects nonexistent months and invalid calendar dates', () {
      expect(() => HebrewDate.monthLength(5786, 13), throwsRangeError);
      expect(
          () => const HebrewDate(5786, 6, 30).toGregorian(), throwsRangeError);
      expect(() => HebrewDate.monthsInYear(0), throwsRangeError);
    });
  });

  test('formats Hebrew names, years and conventional numerals', () {
    expect(const HebrewDate(5787, 7, 7).label, 'ז׳ בתשרי תשפ״ז');
    expect(const HebrewDate(5787, 7, 7).monthYearLabel, 'תשרי תשפ״ז');
    expect(HebrewDate.monthNameFor(5784, 12), 'אדר א׳');
    expect(HebrewDate.monthNameFor(5784, 13), 'אדר ב׳');
    expect(HebrewDate.monthNameFor(5786, 12), 'אדר');
    expect(HebrewDate.formatNumber(1), 'א׳');
    expect(HebrewDate.formatNumber(15), 'ט״ו');
    expect(HebrewDate.formatNumber(16), 'ט״ז');
    expect(HebrewDate.formatNumber(30), 'ל׳');
    expect(HebrewDate.formatNumber(5786), 'תשפ״ו');
    expect(HebrewDate.formatNumber(5787), 'תשפ״ז');
    expect(HebrewDate.formatNumber(6000), 'ו׳');
  });
}
