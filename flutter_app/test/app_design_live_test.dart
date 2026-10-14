import 'dart:convert';
import 'package:betshuva/chat_design_settings.dart';
import 'package:betshuva/main.dart';
import 'package:betshuva/listing_search_filters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('listing layout, field order and future fields validate independently',
      () {
    final design = ChatDesign.parse({
      'schemaVersion': 1,
      'revision': 'new',
      'settings': {
        'listingLayout': 'cards',
        'listingSearchSide': 'left',
        'listingCategoryOrder': ['רכב'],
        'listingSearchFieldOrder': ['model'],
        'compactBlockedMedia': false,
        'futureSetting': 'ignored'
      }
    })!;
    expect(design.orderedCategories(['אחר', 'רכב', 'ספרים']),
        ['רכב', 'אחר', 'ספרים']);
    expect(design.orderedFields(['year', 'model', 'price'], (s) => s),
        ['model', 'year', 'price']);
    for (final bad in [
      {'listingLayout': 'script'},
      {
        'listingCategoryOrder': ['רכב', 'רכב']
      },
      {'listingSearchWidth': 2000}
    ]) {
      expect(
          ChatDesign.parse(
              {'schemaVersion': 1, 'revision': 'bad', 'settings': bad}),
          isNull);
    }
  });

  for (final size in [const Size(360, 740), const Size(1400, 900)]) {
    testWidgets(
        'listing updates preserve search and change visible cards at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      ChatDesignStore.shared.value = const ChatDesign();
      var settings = <String, dynamic>{};
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
            home: ListingsScreen(
                token: 'token',
                me: const {'id': 'viewer'},
                socket: null,
                currentMainNavigationIndex: 3,
                onMainNavigationSelected: (_) {})));
        await tester.pumpAndSettle();
        await tester.runAsync(() => ChatDesignStore.shared.ready);
        await tester.pumpAndSettle();
        final search = find.byWidgetPredicate((w) =>
            w is TextField && w.decoration?.hintText == 'חיפוש במודעות... ');
        await tester.enterText(search, 'רכב');
        await tester.pump(const Duration(milliseconds: 600));
        settings = {
          'listingLayout': 'cards',
          'listingShowPrice': false,
          'listingShowLocation': false,
          'listingShowDate': false,
          'listingShowPublisher': false,
          'listingShowImages': false,
          'listingShowPost': false,
          'listingShowAi': false,
          'listingShowFree': false,
          'listingCardPadding': 6,
          'listingCardGap': 4,
          'listingTitleSize': 20
        };
        await tester.runAsync(() => ChatDesignStore.shared.refresh());
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(search).controller!.text, 'רכב');
        expect(find.text('רכב בדיקה'), findsOneWidget);
        expect(find.text('₪100'), findsNothing);
        expect(find.text('רחובות'), findsNothing);
        expect(find.text('מפרסם בדיקה'), findsNothing);
        expect(find.text('פרסום מתקדם'), findsNothing);
        expect(find.text('למסירה'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        ChatDesignStore.shared.value = const ChatDesign();
      },
          () => MockClient((r) async {
                Object body = {};
                if (r.url.path.endsWith('/chat-design'))
                  body = {
                    'schemaVersion': 1,
                    'revision': settings.isEmpty ? 'old' : 'new',
                    'settings': settings
                  };
                if (r.url.path.endsWith('/listings'))
                  body = [
                    {
                      'id': 'listing',
                      'title': 'רכב בדיקה',
                      'type': 'sale',
                      'price': 100,
                      'category': 'רכב',
                      'city': 'רחובות',
                      'seller_name': 'מפרסם בדיקה',
                      'created_at': '2026-10-14T00:00:00Z'
                    }
                  ];
                return http.Response(jsonEncode(body), 200, headers: {
                  'content-type': 'application/json; charset=utf-8'
                });
              }));
    });
  }

  testWidgets(
      'advanced search keeps draft while layout and reset controls change',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    ChatDesignStore.shared.value = const ChatDesign();
    var changed = false;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: AdvancedListingSearchScreen(
              initialFilters: const ListingSearchFilters(category: 'רכב'),
              onApply: (_) {},
              onClear: () {},
              embedded: true)));
      await tester.pumpAndSettle();
      await tester.runAsync(() => ChatDesignStore.shared.ready);
      await tester.pumpAndSettle();
      final query = find.byKey(const ValueKey('listing-search-query'));
      await tester.enterText(query, 'טיוטת חיפוש');
      await tester.pump();
      changed = true;
      await tester.runAsync(() => ChatDesignStore.shared.refresh());
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(query).controller!.text, 'טיוטת חיפוש');
      expect(
          tester.getRect(query).top,
          lessThan(tester
              .getRect(find.byKey(const ValueKey('listing-search-category')))
              .top));
      expect(find.byKey(const ValueKey('listing-search-clear-query')),
          findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      ChatDesignStore.shared.value = const ChatDesign();
    },
        () => MockClient((r) async => http.Response(
            jsonEncode(r.url.path.endsWith('/chat-design')
                ? {
                    'schemaVersion': 1,
                    'revision': changed ? 'new' : 'old',
                    'settings': changed
                        ? {
                            'listingShowClearButtons': false,
                            'listingSingleFieldRows': false,
                            'listingFieldGap': 20,
                            'listingSearchSectionOrder': [
                              'query',
                              'category',
                              'details',
                              'price',
                              'location',
                              'options'
                            ]
                          }
                        : {}
                  }
                : {}),
            200)));
  });
}
