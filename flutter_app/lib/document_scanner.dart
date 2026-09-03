import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

enum _ScanPageAction { next, remove, finish, cancel }

Future<XFile?> scanDocumentToPdf(
  BuildContext context, {
  required Future<XFile?> Function() capturePage,
  required String destinationName,
  int maxPages = 20,
}) async {
  final pages = <Uint8List>[];

  while (pages.length < maxPages) {
    final captured = await capturePage();
    if (captured == null) {
      if (pages.isEmpty) return null;
      break;
    }
    final bytes = await captured.readAsBytes();
    if (bytes.isEmpty) continue;
    pages.add(bytes);
    if (!context.mounted) return null;

    final action = await showDialog<_ScanPageAction>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text('עמוד ${pages.length} מתוך $maxPages'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    semanticLabel: 'תצוגה מקדימה של העמוד המצולם',
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text('המסמך יישלח אל $destinationName כקובץ PDF'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _ScanPageAction.cancel),
            child: const Text('ביטול'),
          ),
          TextButton.icon(
            onPressed: () =>
                Navigator.pop(dialogContext, _ScanPageAction.remove),
            icon: const Icon(Icons.delete_outline),
            label: const Text('מחק עמוד'),
          ),
          if (pages.length < maxPages)
            OutlinedButton.icon(
              onPressed: () =>
                  Navigator.pop(dialogContext, _ScanPageAction.next),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('צלם עמוד נוסף'),
            ),
          FilledButton.icon(
            onPressed: () =>
                Navigator.pop(dialogContext, _ScanPageAction.finish),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('הכן PDF'),
          ),
        ],
      ),
    );

    if (action == _ScanPageAction.cancel || action == null) return null;
    if (action == _ScanPageAction.remove) {
      pages.removeLast();
      continue;
    }
    if (action == _ScanPageAction.finish) break;
  }

  if (pages.isEmpty || !context.mounted) return null;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('שליחת המסמך הסרוק'),
      content: Text(
        'ייווצר קובץ PDF עם ${pages.length} עמודים ויישלח אל $destinationName. להמשיך?',
        textDirection: TextDirection.rtl,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('חזרה'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('צור ושלח'),
        ),
      ],
    ),
  );
  if (confirmed != true) return null;

  final document = pw.Document();
  for (final pageBytes in pages) {
    final image = pw.MemoryImage(pageBytes);
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(18),
        build: (_) => pw.Center(
          child: pw.Image(image, fit: pw.BoxFit.contain),
        ),
      ),
    );
  }
  final pdfBytes = await document.save();
  final now = DateTime.now();
  final stamp = '${now.year}'
      '${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}_'
      '${now.hour.toString().padLeft(2, '0')}'
      '${now.minute.toString().padLeft(2, '0')}'
      '${now.second.toString().padLeft(2, '0')}';
  return XFile.fromData(
    pdfBytes,
    name: 'document_scan_$stamp.pdf',
    mimeType: 'application/pdf',
  );
}
