import 'dart:async';

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
  Widget? header,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Widget picker = InlineEmojiPicker(
    onSelected: onSelected ?? (_) {},
    header: header,
  );
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
  if (settle) await tester.pumpAndSettle();
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

  for (final layout in [
    (const Size(640, 90), 1.0),
    (const Size(320, 90), 2.5),
  ]) {
    testWidgets(
        'scrolls header and choices in a short ${layout.$1} viewport '
        'at text scale ${layout.$2}', (tester) async {
      final selected = <String>[];
      var closed = false;
      await _showPicker(
        tester,
        size: layout.$1,
        textScale: layout.$2,
        onSelected: selected.add,
        header: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Expanded(child: Text('בחרו אימוג׳י')),
              IconButton(
                key: const ValueKey('picker-header-close'),
                onPressed: () => closed = true,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final viewport = find.byType(CustomScrollView);
      final scrollable = find
          .descendant(of: viewport, matching: find.byType(Scrollable))
          .first;
      final firstEmoji = find.byKey(const ValueKey('inline-emoji-1f600'));
      await tester.scrollUntilVisible(firstEmoji, 60, scrollable: scrollable);
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(firstEmoji), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(firstEmoji);
      await tester.pumpAndSettle();
      expect(selected, ['😀']);
      expect(tester.takeException(), isNull);

      await tester.drag(viewport, const Offset(0, 1000));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('picker-header-close')));
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('header remains usable while the catalog loads and after failure',
      (tester) async {
    final bundle = _DelayedAssetBundle();
    var headerTaps = 0;
    await _showPicker(
      tester,
      bundle: bundle,
      settle: false,
      header: TextButton(
        onPressed: () => headerTaps++,
        child: const Text('חזרה לאימוג׳ים שלי'),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('חזרה לאימוג׳ים שלי'));
    expect(headerTaps, 1);

    bundle.catalog.completeError(StateError('Catalog unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('לא ניתן לטעון את האימוג׳ים כרגע'), findsOneWidget);
    await tester.tap(find.text('חזרה לאימוג׳ים שלי'));
    expect(headerTaps, 2);
    expect(tester.takeException(), isNull);
  });

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

class _DelayedAssetBundle extends CachingAssetBundle {
  final catalog = Completer<ByteData>();

  @override
  Future<ByteData> load(String key) => key.endsWith('emoji_allowlist.json')
      ? catalog.future
      : rootBundle.load(key);
}
