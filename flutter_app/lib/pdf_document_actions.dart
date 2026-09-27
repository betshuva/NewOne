import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

enum _PdfAction { external, download, zoomIn, zoomOut }

class PdfDocumentActions extends StatefulWidget {
  final String fileName;
  final String url;
  final Future<Uint8List> Function()? loadBytes;
  final VoidCallback onDownload;
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;

  const PdfDocumentActions({
    super.key,
    required this.fileName,
    required this.url,
    required this.loadBytes,
    required this.onDownload,
    this.onZoomIn,
    this.onZoomOut,
  });

  @override
  State<PdfDocumentActions> createState() => _PdfDocumentActionsState();
}

class _PdfDocumentActionsState extends State<PdfDocumentActions> {
  bool _printing = false;

  Future<void> _openExternal() async {
    try {
      final uri = Uri.parse(widget.url);
      if (!['https', 'http'].contains(uri.scheme) || uri.host.isEmpty) {
        throw const FormatException('Unsupported document URL');
      }
      if (await launchUrl(uri,
          mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank')) {
        return;
      }
    } catch (_) {
      // Keep the in-app document available when no external handler exists.
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('לא ניתן לפתוח את הקובץ ביישום אחר'),
        action: SnackBarAction(label: 'הורדה', onPressed: widget.onDownload),
      ));
    }
  }

  Future<void> _print() async {
    final load = widget.loadBytes;
    if (_printing || load == null) return;
    setState(() => _printing = true);
    try {
      // Use the document already opened by the viewer, not a second URL fetch.
      // Keep a single byte snapshot even if the print dialog requests it again.
      Future<Uint8List>? bytes;
      await Printing.layoutPdf(
        name: widget.fileName,
        dynamicLayout: false,
        onLayout: (_) => bytes ??= load(),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('לא ניתן לפתוח הדפסה ישירה במכשיר זה'),
          action: SnackBarAction(
            label: 'פתיחה חיצונית',
            onPressed: _openExternal,
          ),
        ));
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _printing ? 'פתיחת הדפסה' : 'הדפסת המסמך',
            onPressed: _printing || widget.loadBytes == null ? null : _print,
            icon: _printing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.print_outlined),
          ),
          PopupMenuButton<_PdfAction>(
            tooltip: 'אפשרויות המסמך',
            onSelected: (action) {
              switch (action) {
                case _PdfAction.external:
                  _openExternal();
                case _PdfAction.download:
                  widget.onDownload();
                case _PdfAction.zoomIn:
                  widget.onZoomIn?.call();
                case _PdfAction.zoomOut:
                  widget.onZoomOut?.call();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: _PdfAction.external,
                child: ListTile(
                  leading: Icon(Icons.open_in_new),
                  title: Text('פתיחה ביישום אחר'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: _PdfAction.download,
                child: ListTile(
                  leading: Icon(Icons.download_outlined),
                  title: Text('הורדת הקובץ'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: _PdfAction.zoomIn,
                enabled: widget.onZoomIn != null,
                child: const ListTile(
                  leading: Icon(Icons.zoom_in),
                  title: Text('הגדלה'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _PdfAction.zoomOut,
                enabled: widget.onZoomOut != null,
                child: const ListTile(
                  leading: Icon(Icons.zoom_out),
                  title: Text('הקטנה'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      );
}
