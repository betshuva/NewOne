import 'dart:convert';
import 'package:betshuva/document_scanner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets(
      'confirmed scan returns readable PDF bytes with a native filename',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    XFile? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async {
                  result = await scanDocumentToPdf(context,
                      capturePage: () async => XFile.fromData(
                          img.encodePng(img.Image(width: 16, height: 16)),
                          mimeType: 'image/png'),
                      destinationName: 'Test recipient');
                },
                child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('הכן PDF'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.textContaining('Test recipient'), findsOneWidget);
    await tester.tap(find.text('צור ושלח'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.name,
        matches(RegExp(r'^betshuva-document-scan-\d{8}_\d{6}\.pdf$')));
    expect(result!.mimeType, 'application/pdf');
    final bytes = await result!.readAsBytes();
    expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
  });
}
