import 'package:betshuva/hebrew_date_stub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats a date like the Hebrew web calendar', () {
    expect(fullHebrewDate(DateTime(2026, 9, 2)), 'יום רביעי, כ׳ באלול תשפ״ו');
  });

  test('handles Rosh Hashanah and leap-year Adar', () {
    expect(fullHebrewDate(DateTime(2025, 9, 23)), 'יום שלישי, א׳ בתשרי תשפ״ו');
    expect(fullHebrewDate(DateTime(2024, 2, 10)), 'יום שבת, א׳ באדר א׳ תשפ״ד');
  });
}
