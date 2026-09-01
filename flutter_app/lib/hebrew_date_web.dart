@JS()
library;

import 'dart:js_interop';

@JS('Intl.DateTimeFormat')
extension type _IntlDateTimeFormat._(JSObject _) implements JSObject {
  external factory _IntlDateTimeFormat(JSString locale, JSObject options);
  external JSString format(_JsDate date);
}

@JS('Date')
extension type _JsDate._(JSObject _) implements JSObject {
  external factory _JsDate(JSNumber milliseconds);
}

String fullHebrewDate(DateTime date) {
  try {
    final formatter = _IntlDateTimeFormat(
      'he-IL-u-ca-hebrew'.toJS,
      <String, String>{
        'weekday': 'long',
        'day': 'numeric',
        'month': 'long',
        'year': 'numeric',
      }.jsify()! as JSObject,
    );
    final jsDate = _JsDate(date.millisecondsSinceEpoch.toJS);
    final formatted = formatter.format(jsDate).toDart;
    return formatted.replaceAllMapped(RegExp(r'\d+'), (match) {
      final number = int.parse(match.group(0)!);
      return _hebrewNumber(number, omitThousands: number >= 5000);
    });
  } catch (_) {
    return '${date.day}/${date.month}/${date.year}';
  }
}

String _hebrewNumber(int number, {bool omitThousands = false}) {
  var value = omitThousands ? number % 1000 : number;
  if (value <= 0) return '';
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
    if (value == 15) {
      result.write('טו');
      break;
    }
    if (value == 16) {
      result.write('טז');
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
