import 'package:betshuva/copyable_file_name.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('copies the full filename from a truncated label', (tester) async {
    const name = 'צילום ארוך מאוד לבדיקה 2026 (1).mp4';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = call.arguments['text'];
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 100,
                child: CopyableFileName(name,
                    maxLines: 1, overflow: TextOverflow.ellipsis)))));
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
    expect(copied, name);
    expect(find.text('שם הקובץ הועתק'), findsOneWidget);
  });

  testWidgets('reports a denied clipboard write without success', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        throw PlatformException(code: 'denied');
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: CopyableFileName('video.mp4'))));
    await tester.tap(find.text('video.mp4'));
    await tester.pumpAndSettle();
    expect(find.text('שם הקובץ הועתק'), findsNothing);
    expect(find.text('לא ניתן להעתיק את שם הקובץ. אפשר לנסות שוב.'),
        findsOneWidget);
  });
}
