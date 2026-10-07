@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:html' as html;
import 'package:betshuva/direct_support_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('paste multiple images into support draft, cap and dispose',
      (tester) async {
    final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC');
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: DirectSupportButtons(
                api: 'https://example.test/api',
                token: 'test',
                appVersion: 'test'))));
    await tester.tap(find.text('בקשה לשיפור'));
    await tester.pumpAndSettle();
    html.ClipboardEvent paste(int count) {
      final data = html.DataTransfer();
      for (var i = 0; i < count; i++) {
        data.items!
            .addFile(html.File([bytes], 'image-$i.png', {'type': 'image/png'}));
      }
      final event = html.ClipboardEvent('paste',
          {'clipboardData': data, 'bubbles': true, 'cancelable': true});
      html.document.dispatchEvent(event);
      return event;
    }

    Future<void> settleImages(int count) async {
      for (var i = 0; i < 150; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
        if (find.byType(Image).evaluate().length == count) break;
      }
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNWidgets(count));
    }

    expect(paste(2).defaultPrevented, isTrue);
    await settleImages(2);
    expect(find.text('הוספת תמונות (2/8)'), findsOneWidget);
    await tester.tap(find.byTooltip('הסרת תמונה 1'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    // Text stays a native editable-text paste, not intercepted as an attachment.
    await tester.tap(find.byType(TextFormField));
    await tester.pumpAndSettle();
    final textData = html.DataTransfer()..setData('text/plain', 'טקסט');
    final textEvent = html.ClipboardEvent(
        'paste', {'clipboardData': textData, 'cancelable': true});
    html.document.dispatchEvent(textEvent);
    expect(textEvent.defaultPrevented, isFalse);
    expect(paste(9).defaultPrevented, isTrue);
    await settleImages(8);
    expect(find.text('ניתן לצרף עד 8 תמונות'), findsOneWidget);
    await tester.ensureVisible(find.text('ביטול'));
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(paste(1).defaultPrevented, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
