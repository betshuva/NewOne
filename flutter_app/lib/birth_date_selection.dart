import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A birth date is submitted only when all three selections form an adult date.
class BirthDateSelection extends StatefulWidget {
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool enabled;

  const BirthDateSelection(
      {super.key,
      required this.value,
      required this.onChanged,
      this.enabled = true});

  @override
  State<BirthDateSelection> createState() => _BirthDateSelectionState();
}

class _BirthDateSelectionState extends State<BirthDateSelection> {
  int? _day, _month, _year;
  DateTime? _reportedValue;
  String? _error;

  void _restore(DateTime? value) {
    _day = value?.day;
    _month = value?.month;
    _year = value?.year;
    _reportedValue = value;
    _error = null;
  }

  @override
  void initState() {
    super.initState();
    _restore(widget.value);
  }

  @override
  void didUpdateWidget(covariant BirthDateSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep partial selections when the parent receives an incomplete date.
    if (widget.value != _reportedValue) _restore(widget.value);
  }

  int get _days =>
      _month == null ? 31 : DateTime(_year ?? 2000, _month! + 1, 0).day;

  void _changed({int? day, int? month, int? year}) {
    DateTime? value;
    setState(() {
      _day = day ?? _day;
      _month = month ?? _month;
      _year = year ?? _year;
      if (_day != null && _day! > _days) _day = null;
      _error = null;
      if (_day != null && _month != null && _year != null) {
        final date = DateTime(_year!, _month!, _day!);
        final now = DateTime.now();
        final latest = DateTime(now.year - 18, now.month,
            math.min(now.day, DateTime(now.year - 18, now.month + 1, 0).day));
        if (date.isAfter(latest)) {
          _error = 'ניתן להירשם מגיל 18 ומעלה בלבד';
        } else if (date.isBefore(DateTime(now.year - 120))) {
          _error = 'תאריך הלידה אינו תקין';
        } else {
          value = date;
        }
      }
      _reportedValue = value;
    });
    widget.onChanged(value);
  }

  Widget _select(String label, int? value, List<int> choices,
          ValueChanged<int> onChanged) =>
      Expanded(
        child: DropdownButtonFormField<int>(
          key: ValueKey('birth-$label-$value'),
          initialValue: value,
          isExpanded: true,
          menuMaxHeight: 300,
          decoration: InputDecoration(labelText: label),
          items: choices
              .map(
                  (item) => DropdownMenuItem(value: item, child: Text('$item')))
              .toList(),
          onChanged: widget.enabled
              ? (item) {
                  if (item != null) onChanged(item);
                }
              : null,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('תאריך לידה'),
        const SizedBox(height: 8),
        Row(children: [
          _select('יום', _day, List.generate(_days, (i) => i + 1),
              (v) => _changed(day: v)),
          const SizedBox(width: 8),
          _select('חודש', _month, List.generate(12, (i) => i + 1),
              (v) => _changed(month: v)),
          const SizedBox(width: 8),
          _select('שנה', _year, List.generate(103, (i) => now.year - 18 - i),
              (v) => _changed(year: v)),
        ]),
        const SizedBox(height: 6),
        Text(_error ?? 'השירות לבני 18 ומעלה בלבד.',
            style: TextStyle(
                fontSize: 12,
                color: _error == null
                    ? Theme.of(context).hintColor
                    : Theme.of(context).colorScheme.error)),
      ]),
    );
  }
}
