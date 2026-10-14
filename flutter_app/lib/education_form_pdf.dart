import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'survey_answers.dart';

String educationSignatureSvg(dynamic data) {
  if (data is! List) return '';
  final segments = <String>[];
  var penDown = false;
  var maxX = 1.0, maxY = 170.0;
  for (final point in data) {
    if (point is! Map || point['x'] is! num || point['y'] is! num) {
      penDown = false;
      continue;
    }
    final x = (point['x'] as num).toDouble();
    final y = (point['y'] as num).toDouble();
    if (!x.isFinite || !y.isFinite || x < 0 || y < 0) {
      penDown = false;
      continue;
    }
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
    segments.add('${penDown ? 'L' : 'M'} $x $y');
    penDown = true;
  }
  if (segments.isEmpty) return '';
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${maxX + 4} ${maxY + 4}">'
      '<path d="${segments.join(' ')}" fill="none" stroke="#123B57" stroke-width="2.4" stroke-linecap="round"/></svg>';
}

String _status(dynamic value) => switch (value) {
      'approved' => 'אושר',
      'declined' => 'לא אושר',
      'completed' => 'הושלם',
      _ => 'טרם השיב/ה',
    };

Future<Uint8List> buildEducationFormPdf({
  required Map<String, dynamic> form,
  required List<Map<String, dynamic>> participants,
  required List<Map<String, dynamic>> results,
  required DateTime generatedAt,
}) async {
  final font =
      pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
  final pdf = pw.Document();
  final survey = form['form_type'] == 'survey';
  final anonymous = survey && form['anonymous'] == true;
  final questions = (form['questions'] as List? ?? []).cast<Map>();
  final completed =
      participants.where((p) => p['response_status'] != null).length;
  pdf.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    maxPages: 1000,
    textDirection: pw.TextDirection.rtl,
    theme: pw.ThemeData.withFont(base: font, bold: font),
    margin: const pw.EdgeInsets.all(32),
    header: (_) =>
        pw.Text('בתשובה — דוח תוצאות', style: const pw.TextStyle(fontSize: 11)),
    footer: (context) => pw.Text(
        'עמוד ${context.pageNumber} מתוך ${context.pagesCount}',
        style: const pw.TextStyle(fontSize: 9)),
    build: (_) => [
      pw.SizedBox(height: 12),
      pw.Text(form['title']?.toString() ?? 'טופס',
          style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
      pw.Text('קבוצה: ${form['group_name'] ?? ''}'),
      if ((form['description']?.toString() ?? '').isNotEmpty)
        pw.Text(form['description'].toString()),
      pw.Text(
          'מצב: ${form['status'] == 'closed' ? 'סגור' : 'פתוח — תוצאות ביניים'}'),
      pw.Text('השלימו: $completed מתוך ${participants.length}'),
      pw.Text('הופק: ${generatedAt.toIso8601String()}'),
      if ((form['file_name']?.toString() ?? '').isNotEmpty)
        pw.Text('מסמך מצורף: ${form['file_name']}'),
      pw.SizedBox(height: 16),
      if (survey)
        ...questions.asMap().entries.expand((entry) {
          final counts = surveyAnswerCounts(
              Map<String, dynamic>.from(entry.value), results, entry.key);
          return <pw.Widget>[
            pw.Text('${entry.key + 1}. ${entry.value['text']}',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            ...counts.entries
                .map((item) => pw.Text('${item.key}: ${item.value}')),
            pw.SizedBox(height: 10),
          ];
        }),
      if (anonymous)
        pw.Text(
            'סקר אנונימי — הדוח מציג תוצאות מצטברות בלבד, ללא שמות או שיוך תשובות.'),
      if (!anonymous)
        ...participants.expand((person) {
          final svg = educationSignatureSvg(person['signature_data']);
          final answers = person['answers'];
          return <pw.Widget>[
            pw.Divider(),
            pw.Text(
                '${person['name'] ?? ''} — ${_status(person['response_status'])}',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            if (person['submitted_at'] != null)
              pw.Text('מועד תשובה: ${person['submitted_at']}'),
            if (survey && answers is Map)
              ...questions.asMap().entries.map((entry) => pw.Text(
                  '${entry.value['text']}: ${surveyAnswerLabel(answers[entry.key.toString()] ?? answers[entry.key])}')),
            if (form['form_type'] == 'signature' &&
                person['signer_name'] != null)
              pw.Text('שם החותם: ${person['signer_name']}'),
            if (form['form_type'] == 'signature' && svg.isNotEmpty)
              pw.SizedBox(height: 85, child: pw.SvgImage(svg: svg)),
          ];
        }),
    ],
  ));
  return pdf.save();
}
