import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Displays the guide's plain text and Markdown tables without interpreting
/// links, HTML, or any other Markdown in user-provided cell values.
class GuideTableText extends StatelessWidget {
  const GuideTableText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final blocks = _parseBlocks(text);
    return SelectionArea(
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: blocks.every((block) => block is String)
            ? _paragraph(text)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var index = 0; index < blocks.length; index++) ...[
                    if (index > 0) const SizedBox(height: 8),
                    if (blocks[index] is String)
                      _paragraph(blocks[index] as String)
                    else
                      _table(context, blocks[index] as _GuideTable),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _paragraph(String value) => Text(
        value,
        style: style,
        textDirection: TextDirection.rtl,
        textAlign: TextAlign.right,
      );

  Widget _table(BuildContext context, _GuideTable data) {
    final theme = Theme.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final availableWidth = constraints.hasBoundedWidth
          ? constraints.maxWidth
          : MediaQuery.sizeOf(context).width;
      final columnWidth =
          (availableWidth / data.headers.length).clamp(120.0, 220.0);
      final tableWidth = columnWidth * data.headers.length;
      return SizedBox(
        width: math.min(availableWidth, tableWidth),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            textDirection: TextDirection.rtl,
            defaultColumnWidth: FixedColumnWidth(columnWidth),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder.all(color: theme.dividerColor),
            children: [
              TableRow(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.07),
                ),
                children: [
                  for (final header in data.headers)
                    _cell(header, isHeader: true),
                ],
              ),
              for (final row in data.rows)
                TableRow(children: [
                  for (var column = 0; column < row.length; column++)
                    _cell(row[column],
                        isPhone: _phoneHeader.hasMatch(data.headers[column])),
                ]),
            ],
          ),
        ),
      );
    });
  }

  Widget _cell(String value, {bool isHeader = false, bool isPhone = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(
          value,
          style: isHeader ? style.copyWith(fontWeight: FontWeight.w600) : style,
          textDirection: isPhone ? TextDirection.ltr : TextDirection.rtl,
          textAlign: TextAlign.right,
        ),
      );
}

final _phoneHeader = RegExp(r'טלפון|נייד|phone|mobile', caseSensitive: false);
final _separatorCell = RegExp(r'^:?-{3,}:?$');

class _GuideTable {
  _GuideTable(this.headers, this.rows);

  final List<String> headers;
  final List<List<String>> rows;
}

List<String>? _cells(String line) {
  var value = line.trim();
  if (!value.contains('|')) return null;
  if (value.startsWith('|')) value = value.substring(1);
  if (value.endsWith('|')) value = value.substring(0, value.length - 1);
  return value
      .split('|')
      .map((cell) => cell.trim().replaceAll('&#124;', '|'))
      .toList();
}

List<Object> _parseBlocks(String text) {
  final lines = text.split('\n');
  final blocks = <Object>[];
  final paragraph = <String>[];
  void flushParagraph() {
    final value = paragraph.join('\n').trim();
    if (value.isNotEmpty) blocks.add(value);
    paragraph.clear();
  }

  var index = 0;
  while (index < lines.length) {
    final headers = _cells(lines[index]);
    final separator =
        index + 1 < lines.length ? _cells(lines[index + 1]) : null;
    if (headers == null ||
        separator == null ||
        headers.length != separator.length ||
        !separator.every(_separatorCell.hasMatch)) {
      paragraph.add(lines[index++]);
      continue;
    }
    flushParagraph();
    index += 2;
    final rows = <List<String>>[];
    while (index < lines.length) {
      final row = _cells(lines[index]);
      if (row == null || row.length != headers.length) break;
      rows.add(row);
      index++;
    }
    blocks.add(_GuideTable(headers, rows));
  }
  flushParagraph();
  return blocks;
}
