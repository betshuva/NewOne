import 'dart:convert';

import 'package:betshuva/inline_emoji_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

class _HouseFixtureBundle extends CachingAssetBundle {
  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (key.endsWith('emoji_allowlist.json')) {
      return jsonEncode([
        {
          'emoji': '😀',
          'category': 'פנים',
          'label_he': 'חיוך',
          'twemoji_code': '1f600'
        },
        {
          'emoji': '🏠',
          'category': 'מקומות',
          'label_he': 'בית',
          'twemoji_code': '1f3e0'
        },
        {
          'emoji': '🏡',
          'category': 'מקומות',
          'label_he': 'בית עם גינה',
          'twemoji_code': '1f3e1'
        },
      ]);
    }
    if (key.endsWith('.svg')) {
      return '<svg xmlns="http://www.w3.org/2000/svg" width="28" height="28"><rect width="28" height="28" fill="yellow"/></svg>';
    }
    return super.loadString(key, cache: cache);
  }

  @override
  Future<ByteData> load(String key) async {
    final bytes = Uint8List.fromList(utf8.encode(await loadString(key)));
    return ByteData.sublistView(bytes);
  }
}

void main() {
  testWidgets('house Unicode remain in artwork catalog but cannot be selected',
      (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DefaultAssetBundle(
          bundle: _HouseFixtureBundle(),
          child: InlineEmojiPicker(onSelected: selected.add),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inline-emoji-1f3e0')), findsNothing);
    expect(find.byKey(const ValueKey('inline-emoji-1f3e1')), findsNothing);
    expect(find.byType(SvgPicture), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'בית');
    await tester.pumpAndSettle();
    expect(find.text('לא נמצאו אימוג׳ים מתאימים'), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
    expect(selected, isEmpty);
    await tester.tap(find.byTooltip('ניקוי החיפוש'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('inline-emoji-1f600')));
    expect(selected, ['😀']);
  });
}
