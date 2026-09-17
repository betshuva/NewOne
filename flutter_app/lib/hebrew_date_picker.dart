import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'calendar_hebrew_date.dart';

DateTime _civilDay(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

/// Picks a civil date using Hebrew months, years, and day numbers.
Future<DateTime?> showHebrewDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  final first = _civilDay(firstDate);
  final last = _civilDay(lastDate);
  assert(!last.isBefore(first));
  final initial = _civilDay(initialDate);
  final boundedInitial = initial.isBefore(first)
      ? first
      : initial.isAfter(last)
          ? last
          : initial;
  return showDialog<DateTime>(
    context: context,
    builder: (context) => Directionality(
      textDirection: TextDirection.rtl,
      child: _HebrewDatePicker(
        initialDate: boundedInitial,
        firstDate: first,
        lastDate: last,
      ),
    ),
  );
}

class _HebrewDatePicker extends StatefulWidget {
  const _HebrewDatePicker({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_HebrewDatePicker> createState() => _HebrewDatePickerState();
}

class _HebrewDatePickerState extends State<_HebrewDatePicker> {
  late HebrewDate _selected;
  late final int _firstYear;
  late final int _lastYear;

  @override
  void initState() {
    super.initState();
    _selected = HebrewDate.fromGregorian(widget.initialDate);
    _firstYear = HebrewDate.fromGregorian(widget.firstDate).year;
    _lastYear = HebrewDate.fromGregorian(widget.lastDate).year;
  }

  bool _allowed(DateTime date) =>
      !date.isBefore(widget.firstDate) && !date.isAfter(widget.lastDate);

  bool _monthAllowed(int year, int month) {
    final first = HebrewDate(year, month, 1).toGregorian();
    final last = HebrewDate(
      year,
      month,
      HebrewDate.monthLength(year, month),
    ).toGregorian();
    return !last.isBefore(widget.firstDate) && !first.isAfter(widget.lastDate);
  }

  bool _canMoveMonth(int direction) {
    final next = _selected.addMonths(direction);
    return _monthAllowed(next.year, next.month);
  }

  void _select(HebrewDate date) {
    final civil = date.toGregorian();
    setState(() {
      _selected = civil.isBefore(widget.firstDate)
          ? HebrewDate.fromGregorian(widget.firstDate)
          : civil.isAfter(widget.lastDate)
              ? HebrewDate.fromGregorian(widget.lastDate)
              : date;
    });
  }

  void _changeMonth(int month) => _select(HebrewDate(
        _selected.year,
        month,
        math.min(
          _selected.day,
          HebrewDate.monthLength(_selected.year, month),
        ),
      ));

  Widget _dropdown({
    required String label,
    required String keyName,
    required int value,
    required List<DropdownMenuItem<int>> items,
    required ValueChanged<int> onChanged,
  }) =>
      InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            key: ValueKey(keyName),
            value: value,
            isExpanded: true,
            items: items,
            onChanged: (value) {
              if (value != null) onChanged(value);
            },
          ),
        ),
      );

  Widget _dayCell(int day) {
    final hebrew = HebrewDate(_selected.year, _selected.month, day);
    final civil = hebrew.toGregorian();
    final enabled = _allowed(civil);
    final selected = _selected.day == day;
    final today = civil == _civilDay(DateTime.now());
    final colors = Theme.of(context).colorScheme;
    final keyDate = '${civil.year}-'
        '${civil.month.toString().padLeft(2, '0')}-'
        '${civil.day.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Semantics(
        key: ValueKey('calendar-picker-day-semantics-$keyDate'),
        label: '${hebrew.label}${today ? ', היום' : ''}',
        button: true,
        enabled: enabled,
        selected: selected,
        onTap: enabled ? () => _select(hebrew) : null,
        excludeSemantics: true,
        child: Material(
          color: selected ? colors.primary : Colors.transparent,
          shape: CircleBorder(
            side: today
                ? BorderSide(
                    color: selected ? colors.onPrimary : colors.primary,
                    width: 1.5,
                  )
                : BorderSide.none,
          ),
          child: InkWell(
            key: ValueKey('calendar-picker-day-$keyDate'),
            customBorder: const CircleBorder(),
            onTap: enabled ? () => _select(hebrew) : null,
            child: Center(
              child: Text(
                hebrew.dayLabel,
                style: TextStyle(
                  color: !enabled
                      ? Theme.of(context).disabledColor
                      : selected
                          ? colors.onPrimary
                          : colors.onSurface,
                  fontWeight:
                      selected || today ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final civil = _selected.toGregorian();
    final monthStart =
        HebrewDate(_selected.year, _selected.month, 1).toGregorian();
    final offset = monthStart.weekday % 7;
    final dayCount = _selected.daysInMonth;
    final cellCount = ((offset + dayCount + 6) ~/ 7) * 7;
    final months = HebrewDate.monthsInYear(_selected.year)
        .where((month) => _monthAllowed(_selected.year, month))
        .toList();
    final theme = Theme.of(context);
    return Dialog(
      key: const ValueKey('calendar-hebrew-date-picker'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('בחירת תאריך עברי', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  _selected.label,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${civil.day}/${civil.month}/${civil.year}',
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _dropdown(
                      label: 'חודש עברי',
                      keyName: 'calendar-picker-month',
                      value: _selected.month,
                      items: [
                        for (final month in months)
                          DropdownMenuItem(
                            value: month,
                            child: Text(HebrewDate.monthNameFor(
                              _selected.year,
                              month,
                            )),
                          ),
                      ],
                      onChanged: _changeMonth,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _dropdown(
                      label: 'שנה עברית',
                      keyName: 'calendar-picker-year',
                      value: _selected.year,
                      items: [
                        for (var year = _firstYear; year <= _lastYear; year++)
                          DropdownMenuItem(
                            value: year,
                            child: Text(HebrewDate(year, 7, 1).yearLabel),
                          ),
                      ],
                      onChanged: (year) => _select(_selected.withYear(year)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  IconButton(
                    key: const ValueKey('calendar-picker-prev'),
                    tooltip: 'החודש הקודם',
                    onPressed: _canMoveMonth(-1)
                        ? () => _select(_selected.addMonths(-1))
                        : null,
                    icon: const Icon(
                      Icons.chevron_right,
                      textDirection: TextDirection.ltr,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _selected.monthYearLabel,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('calendar-picker-next'),
                    tooltip: 'החודש הבא',
                    onPressed: _canMoveMonth(1)
                        ? () => _select(_selected.addMonths(1))
                        : null,
                    icon: const Icon(
                      Icons.chevron_left,
                      textDirection: TextDirection.ltr,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  for (final weekday in const [
                    'א׳',
                    'ב׳',
                    'ג׳',
                    'ד׳',
                    'ה׳',
                    'ו׳',
                    'שבת',
                  ])
                    Expanded(
                      child: Center(
                        child:
                            Text(weekday, style: theme.textTheme.labelMedium),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                primary: false,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                ),
                itemCount: cellCount,
                itemBuilder: (context, index) {
                  final day = index - offset + 1;
                  return day < 1 || day > dayCount
                      ? const SizedBox.shrink()
                      : _dayCell(day);
                },
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const ValueKey('calendar-picker-cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('ביטול'),
                  ),
                  FilledButton(
                    key: const ValueKey('calendar-picker-confirm'),
                    onPressed: () => Navigator.of(context).pop(civil),
                    child: const Text('אישור'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
