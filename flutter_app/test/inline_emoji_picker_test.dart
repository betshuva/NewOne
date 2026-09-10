import 'package:betshuva/inline_emoji_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _showPicker(
  WidgetTester tester, {
  ValueChanged<String>? onSelected,
  Size size = const Size(400, 440),
  double textScale = 1,
  AssetBundle? bundle,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Widget picker = InlineEmojiPicker(onSelected: onSelected ?? (_) {});
  if (bundle != null) {
    picker = DefaultAssetBundle(bundle: bundle, child: picker);
  }
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: picker,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('selecting a tile returns the Unicode emoji exactly once',
      (tester) async {
    final selected = <String>[];
    await _showPicker(tester, onSelected: selected.add);
    expect(selected, isEmpty);

    await tester.tap(find.byKey(const ValueKey('inline-emoji-1f600')));
    await tester.pump();

    expect(selected, ['😀']);
    expect(find.byType(InlineEmojiPicker), findsOneWidget);
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture).first);
    expect(svg.width, 28);
    expect(svg.height, 28);
  });

  testWidgets('Hebrew search and category filters combine and clear',
      (tester) async {
    await _showPicker(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'מחוות'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inline-emoji-1f600')), findsNothing);
    expect(find.byType(SvgPicture), findsWidgets);

    await tester.enterText(find.byType(TextField), 'פנים ורגשות');
    await tester.pumpAndSettle();
    expect(find.text('לא נמצאו אימוג׳ים מתאימים'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'הכול'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inline-emoji-1f600')), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'חיוך גדול');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inline-emoji-1f604')), findsOneWidget);
    expect(find.byKey(const ValueKey('inline-emoji-1f600')), findsNothing);

    await tester.tap(find.byTooltip('ניקוי החיפוש'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inline-emoji-1f600')), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
  });

  testWidgets('emoji search returns multi-codepoint Unicode unchanged',
      (tester) async {
    final selected = <String>[];
    await _showPicker(tester, onSelected: selected.add);
    await tester.enterText(find.byType(TextField), '❤️');
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
    await tester.tap(find.byType(InkWell).last);
    expect(selected, ['❤️']);
  });

  for (final layout in [
    (const Size(320, 420), 1.0),
    (const Size(320, 420), 2.5),
    (const Size(900, 420), 2.5),
  ]) {
    testWidgets('fits ${layout.$1} with text scale ${layout.$2}',
        (tester) async {
      await _showPicker(tester, size: layout.$1, textScale: layout.$2);
      expect(find.byType(SvgPicture), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), 'אין אימוג׳י כזה');
      await tester.pumpAndSettle();
      expect(find.text('לא נמצאו אימוג׳ים מתאימים'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unavailable catalog offers a retry without a broken grid',
      (tester) async {
    final bundle = _RetryAssetBundle();
    await _showPicker(tester, bundle: bundle);
    expect(find.text('לא ניתן לטעון את האימוג׳ים כרגע'), findsOneWidget);
    expect(tester.takeException(), isNull);

    bundle.fail = false;
    await tester.tap(find.text('ניסיון נוסף'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inline-emoji-1f600')), findsOneWidget);
    expect(find.text('לא ניתן לטעון את האימוג׳ים כרגע'), findsNothing);
  });

  testWidgets('emoji tiles expose a meaningful accessible button label',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _showPicker(tester);
      expect(find.bySemanticsLabel('הוספת אימוג׳י: חיוך 😀'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });
}

class _RetryAssetBundle extends CachingAssetBundle {
  bool fail = true;

  @override
  Future<ByteData> load(String key) {
    if (fail && key.endsWith('emoji_allowlist.json')) {
      return Future.error(StateError('Catalog temporarily unavailable'));
    }
    return rootBundle.load(key);
  }
}
