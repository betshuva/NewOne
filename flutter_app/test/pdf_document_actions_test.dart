import 'dart:async';
import 'dart:typed_data';

import 'package:betshuva/pdf_document_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:printing/src/interface.dart';
// Mock the existing url_launcher plugin without opening an external app.
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _Printer extends PrintingPlatform {
  int calls = 0;
  String? name;
  bool? dynamicLayoutRequested;
  bool fail = false;
  bool result = true;
  Uint8List? bytes;
  Completer<void>? hold;

  @override
  Future<bool> layoutPdf(
      Printer? printer,
      LayoutCallback onLayout,
      String name,
      PdfPageFormat format,
      bool dynamicLayout,
      bool usePrinterSettings,
      OutputType outputType,
      bool forceCustomPrintPaper,
      bool windowsModernDialog) async {
    calls++;
    this.name = name;
    dynamicLayoutRequested = dynamicLayout;
    if (fail) throw StateError('No printer support');
    bytes = await onLayout(format);
    expect(await onLayout(PdfPageFormat.letter), same(bytes));
    await hold?.future;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Launcher extends UrlLauncherPlatform {
  @override
  get linkDelegate => null;
  bool success = true;
  String? url;
  LaunchOptions? options;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    this.url = url;
    this.options = options;
    return success;
  }
}

void main() {
  late _Printer printer;
  late _Launcher launcher;
  late Uint8List bytes;
  var loads = 0, downloads = 0, zooms = 0;
  setUp(() {
    final oldPrinter = PrintingPlatform.instance;
    final oldLauncher = UrlLauncherPlatform.instance;
    printer = _Printer();
    launcher = _Launcher();
    PrintingPlatform.instance = printer;
    UrlLauncherPlatform.instance = launcher;
    bytes = Uint8List.fromList('%PDF-1.7\nexample'.codeUnits);
    loads = downloads = zooms = 0;
    addTearDown(() {
      PrintingPlatform.instance = oldPrinter;
      UrlLauncherPlatform.instance = oldLauncher;
    });
  });

  Widget screen({bool ready = true, bool failedBytes = false}) => MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('שם מסמך ארוך מאוד בעברית.pdf',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                PdfDocumentActions(
                  fileName: 'שיעור.pdf',
                  url: 'https://example.test/protected.pdf?signature=existing',
                  loadBytes: ready
                      ? () async {
                          loads++;
                          if (failedBytes) throw StateError('Closed document');
                          return bytes;
                        }
                      : null,
                  onDownload: () => downloads++,
                  onZoomIn: ready ? () => zooms++ : null,
                  onZoomOut: ready ? () => zooms-- : null,
                ),
              ],
            ),
          ),
        ),
      );

  testWidgets('prints the full loaded PDF once without rebuilding its layout',
      (tester) async {
    await tester.pumpWidget(screen());
    await tester.tap(find.byTooltip('הדפסת המסמך'));
    await tester.pumpAndSettle();
    expect(printer.calls, 1);
    expect(printer.name, 'שיעור.pdf');
    expect(printer.dynamicLayoutRequested, isFalse);
    expect(printer.bytes, same(bytes));
    expect(loads, 1);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('printing stays disabled until a permitted document is ready',
      (tester) async {
    await tester.pumpWidget(screen(ready: false));
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.print_outlined)).onPressed,
        isNull);
    await tester.tap(find.byTooltip('אפשרויות המסמך'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('פתיחה ביישום אחר'));
    await tester.pumpAndSettle();
    expect(
        launcher.url, 'https://example.test/protected.pdf?signature=existing');
    expect(launcher.options?.mode, PreferredLaunchMode.externalApplication);
    expect(printer.calls, 0);
  });

  testWidgets('busy print cannot duplicate and completion after close is safe',
      (tester) async {
    printer.hold = Completer<void>();
    await tester.pumpWidget(screen());
    await tester.tap(find.byTooltip('הדפסת המסמך'));
    await tester.pump();
    expect(tester.widget<IconButton>(find.ancestor(of: find.byType(CircularProgressIndicator), matching: find.byType(IconButton))).onPressed,
        isNull);
    expect(printer.calls, 1);
    await tester.pumpWidget(const SizedBox());
    printer.hold!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel is silent and print errors offer an external fallback',
      (tester) async {
    printer.result = false;
    await tester.pumpWidget(screen());
    await tester.tap(find.byTooltip('הדפסת המסמך'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    printer.fail = true;
    await tester.tap(find.byTooltip('הדפסת המסמך'));
    await tester.pumpAndSettle();
    expect(find.text('לא ניתן לפתוח הדפסה ישירה במכשיר זה'), findsOneWidget);
    await tester.tap(find.text('פתיחה חיצונית'));
    await tester.pumpAndSettle();
    expect(launcher.url, isNotNull);
  });

  testWidgets('failed external opening offers download', (tester) async {
    launcher.success = false;
    await tester.pumpWidget(screen());
    await tester.tap(find.byTooltip('אפשרויות המסמך'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('פתיחה ביישום אחר'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('הורדה'));
    expect(downloads, 1);
  });

  testWidgets('phone toolbar fits and preserves zoom and download commands',
      (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(screen());
    await tester.tap(find.byTooltip('אפשרויות המסמך'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('הגדלה'));
    await tester.pumpAndSettle();
    expect(zooms, 1);
    await tester.tap(find.byTooltip('אפשרויות המסמך'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('הורדת הקובץ'));
    await tester.pumpAndSettle();
    expect(downloads, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('document encoding errors do not claim a successful print',
      (tester) async {
    await tester.pumpWidget(screen(failedBytes: true));
    await tester.tap(find.byTooltip('הדפסת המסמך'));
    await tester.pumpAndSettle();
    expect(find.text('לא ניתן לפתוח הדפסה ישירה במכשיר זה'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
