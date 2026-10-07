import 'dart:convert';

import 'package:betshuva/message_reaction_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

late String _bundledCatalog;

class _Catalog extends CachingAssetBundle {
  _Catalog(this.catalog);
  final String catalog;
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode(catalog)));
}

Future<void> _show(WidgetTester tester,
    {ValueChanged<String?>? onResult,
    String? selectedEmoji,
    AssetBundle? bundle,
    double textScale = 1}) async {
  Widget app = MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: Scaffold(
          body: Builder(
        builder: (context) => TextButton(
            onPressed: () async {
              final result = await showMessageReactionEmojiPicker(context,
                  selectedEmoji: selectedEmoji);
              onResult?.call(result);
            },
            child: const Text('open')),
      )));
  bundle ??= _Catalog(_bundledCatalog);
  app = DefaultAssetBundle(bundle: bundle, child: app);
  await tester.pumpWidget(app);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    _bundledCatalog =
        await rootBundle.loadString('assets/stickers/user-catalog.json');
  });
  testWidgets('library keeps all 150 IDs and renders colored 32px artwork',
      (tester) async {
    await _show(tester, selectedEmoji: '[[bt-emoji:001]]');
    final grid = tester.widget<SliverGrid>(
        find.byKey(const ValueKey('message-reaction-library-grid')));
    expect((grid.delegate as SliverChildBuilderDelegate).childCount, 150);
    final first = find.byKey(const ValueKey('reaction-library-emoji-001'));
    final image = tester.widget<Image>(
        find.descendant(of: first, matching: find.byType(Image)));
    expect(image.width, 32);
    expect(image.height, 32);
    expect(
        (image.image as NetworkImage).url,
        'https://betshuva.com/betshuva-app/expression-library/'
        'user-20261008-color/sticker-01.png');
    final selected = tester.widget<Semantics>(
        find.ancestor(of: first, matching: find.byType(Semantics)).first);
    expect(selected.properties.selected, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Hebrew search preserves IDs and selection returns only a token',
      (tester) async {
    String? selected;
    await _show(tester, onResult: (result) => selected = result);
    final bundled = jsonDecode(_bundledCatalog) as Map;
    final labels = bundled['categories'][0]['labels'] as List;
    await tester.enterText(find.byType(TextField), labels[149] as String);
    await tester.pumpAndSettle();
    final last = find.byKey(const ValueKey('reaction-library-emoji-150'));
    expect(last, findsOneWidget);
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(selected, '[[bt-emoji:150]]');
    expect(
        find.byKey(const ValueKey('message-reaction-library')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clear search restores all IDs and cancel returns no selection',
      (tester) async {
    var completed = false;
    String? selected = 'unchanged';
    await _show(tester, onResult: (result) {
      completed = true;
      selected = result;
    });
    await tester.enterText(find.byType(TextField), 'does-not-exist');
    await tester.pumpAndSettle();
    expect(find.text('לא נמצאו אימוג׳י מתאימים'), findsOneWidget);
    await tester.tap(find.byTooltip('ניקוי החיפוש'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reaction-library-emoji-001')),
        findsOneWidget);
    await tester.tap(find.byTooltip('סגירה'));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(selected, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('library and search fit a 390px RTL screen without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _show(tester);
    final dialog = tester.getRect(find.byType(Dialog));
    expect(dialog.left, greaterThanOrEqualTo(0));
    expect(dialog.right, lessThanOrEqualTo(390));
    expect(dialog.top, greaterThanOrEqualTo(0));
    expect(dialog.bottom, lessThanOrEqualTo(844));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final viewport in [
    (width: 320.0, height: 240.0, keyboard: 0.0, scale: 2.5),
    (width: 390.0, height: 844.0, keyboard: 350.0, scale: 2.5),
    (width: 320.0, height: 568.0, keyboard: 250.0, scale: 1.0),
  ]) {
    testWidgets('scrollable library fits $viewport', (tester) async {
      tester.view.physicalSize = Size(viewport.width, viewport.height);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: viewport.keyboard);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await _show(tester, textScale: viewport.scale);
      expect(tester.takeException(), isNull);
      final search = find.byKey(const ValueKey('reaction-library-search'));
      final scrollable = find
          .descendant(
              of: find.byKey(const ValueKey('reaction-library-scroll')),
              matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(search, 60, scrollable: scrollable);
      await tester.enterText(search, 'קריצה');
      await tester.pumpAndSettle();
      final choice = find.byKey(const ValueKey('reaction-library-emoji-004'));
      await tester.scrollUntilVisible(choice, 60, scrollable: scrollable);
      await tester.pumpAndSettle();
      final hit = tester.getRect(choice);
      expect(hit.left, greaterThanOrEqualTo(0));
      expect(hit.right, lessThanOrEqualTo(viewport.width));
      expect(hit.top, greaterThanOrEqualTo(0));
      expect(
          hit.bottom, lessThanOrEqualTo(viewport.height - viewport.keyboard));
      expect(tester.takeException(), isNull);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('message-reaction-library')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('an untrusted folder cannot turn library entries into image URLs',
      (tester) async {
    final catalog = jsonEncode({
      'categories': [
        {
          'id': 'user-stickers',
          'coloredPath': '../../https://untrusted.invalid',
          'labels': List.generate(150, (index) => 'label $index'),
        }
      ]
    });
    await _show(tester, bundle: _Catalog(catalog));
    expect(find.text('לא ניתן לטעון את האימוג׳י כרגע'), findsOneWidget);
    expect(find.byKey(const ValueKey('message-reaction-library-grid')),
        findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
