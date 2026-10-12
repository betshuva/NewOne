import 'dart:async';
import 'dart:convert';

import 'package:betshuva/listing_search_filters.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _listing = <String, dynamic>{
  'id': '11111111-1111-4111-8111-111111111111',
  'title': 'מודעת בסיס',
  'description': 'מודעה לצורך הבדיקה',
  'type': 'sale',
  'category': 'אחר',
  'price': 100.0,
  'city': 'רחובות',
  'seller_id': 'another-user',
  'seller_name': 'מפרסם',
  'status': 'active',
};

http.Response _json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});
void _expectParameters(
    Map<String, String> actual, Map<String, Object> expected) {
  final normalized = <String, Object>{
    for (final entry in actual.entries)
      entry.key: const ['minPrice', 'maxPrice', 'radius'].contains(entry.key)
          ? double.parse(entry.value)
          : entry.value,
  };
  expect(normalized, expected);
}

Finder get _panel => find.byType(AdvancedListingSearchScreen);
Finder _key(String name) => find.byKey(ValueKey('listing-search-$name'));
Finder get _quickSearch => find.byWidgetPredicate((widget) =>
    widget is TextField && widget.decoration?.hintText == 'חיפוש במודעות... ');

Finder _input(String name) {
  final keyed = _key(name);
  if (keyed.evaluate().single.widget is TextField) return keyed;
  return find.descendant(of: keyed, matching: find.byType(TextField)).first;
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final scrollable =
        find.descendant(of: _panel, matching: find.byType(Scrollable)).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(finder, 180, scrollable: scrollable);
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String name, String text) async {
  await _reveal(tester, _key(name));
  await tester.enterText(_input(name), text);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String name, String label) async {
  await _tap(tester, _key(name));
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _cancel(WidgetTester tester) async {
  final back = find.descendant(of: _panel, matching: find.byType(BackButton));
  if (back.evaluate().isNotEmpty) {
    await _tap(tester, back.first);
  } else {
    await _tap(tester,
        find.descendant(of: _panel, matching: find.byIcon(Icons.close)).first);
  }
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _app(Widget child, {bool keyboard = false}) => MaterialApp(
    theme: ThemeData(fontFamily: 'NotoSansHebrew'),
    builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: keyboard
            ? MediaQuery(
                data: MediaQuery.of(context).copyWith(
                    viewInsets: const EdgeInsets.only(bottom: 280),
                    textScaler: const TextScaler.linear(1.4)),
                child: child!)
            : child!),
    home: child);

Future<void> _withListings(WidgetTester tester,
    Future<void> Function(List<http.Request> requests) action,
    {Size size = const Size(1400, 1100),
    Future<http.Response> Function(http.Request request)? respond}) async {
  _size(tester, size);
  SharedPreferences.setMockInitialValues({});
  final requests = <http.Request>[];
  final client = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/listings')) {
      if (request.url.queryParameters['mine'] == 'true') return _json([]);
      requests.add(request);
      return respond == null
          ? _json([
              {
                ..._listing,
                if (request.url.queryParameters.keys
                    .any((key) => key != 'page'))
                  'title': 'תוצאה מסוננת',
              }
            ])
          : await respond(request);
    }
    if (path.contains('/listings/') && !path.endsWith('/catalog')) {
      return _json(_listing);
    }
    return _json({});
  });
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(_app(ListingsScreen(
          token: 'token',
          me: const {'id': 'search-user', 'name': 'מחפש', 'city': 'רחובות'},
          socket: null,
          currentMainNavigationIndex: 3,
          onMainNavigationSelected: (_) {})));
      await tester.pumpAndSettle();
      await action(requests);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  }, () => client);
}

Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open-listing-advanced-search')));
  await tester.pumpAndSettle();
  expect(_panel, findsOneWidget);
  expect(find.descendant(of: _panel, matching: find.text('חיפוש מתקדם')),
      findsOneWidget);
  expect(find.byType(BottomSheet), findsNothing);
}

Future<void> _applyCar(WidgetTester tester) async {
  await _enter(tester, 'query', 'היברידי');
  await _choose(tester, 'type', 'למכירה');
  await _choose(tester, 'category', 'רכב');
  await _enter(tester, 'detail-manufacturer', 'Toyota');
  await _enter(tester, 'detail-model', 'Corolla');
  await _enter(tester, 'detail-year', '2020');
  await _enter(tester, 'min-price', '10000');
  await _enter(tester, 'max-price', '60000');
  await _enter(tester, 'city', 'רחובות');
  final radius = find.descendant(of: _panel, matching: find.byType(Slider));
  await _reveal(tester, radius);
  await tester.tapAt(tester.getCenter(radius));
  await tester.pumpAndSettle();
  await _choose(tester, 'sort', 'מחיר: מהנמוך לגבוה');
  await _tap(tester, find.text('חפש מודעות'));
}

Future<void> _withDraft(WidgetTester tester, ListingSearchFilters filters,
    Future<void> Function(List<ListingSearchFilters> applied) action) async {
  final applied = <ListingSearchFilters>[];
  var clearAllCalls = 0;
  try {
    await tester.pumpWidget(_app(AdvancedListingSearchScreen(
        initialFilters: filters,
        embedded: true,
        onApply: applied.add,
        onClear: () => clearAllCalls++)));
    await tester.pumpAndSettle();
    await action(applied);
    expect(clearAllCalls, 0,
        reason: 'An individual reset must not invoke the global clear action');
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }
}

Future<String> _textValue(WidgetTester tester, String name) async {
  await _reveal(tester, _key(name));
  return tester.widget<TextField>(_input(name)).controller!.text;
}

String? _selectionValue(WidgetTester tester, String name) => tester
    .state<FormFieldState<String>>(find
        .descendant(
            of: _key(name),
            matching: find.byType(DropdownButtonFormField<String>))
        .first)
    .value;

void main() {
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  test(
      'search filters serialize vehicle and property fields for the existing API',
      () {
    expect(const ListingSearchFilters().queryParameters, {'page': '1'});
    expect(
        const ListingSearchFilters(details: {'manufacturer': 'stale'})
            .queryParameters,
        {'page': '1'});
    _expectParameters(
        const ListingSearchFilters(
            type: 'sale',
            category: 'רכב',
            city: ' רחובות ',
            query: ' היברידי ',
            minPrice: 10000,
            maxPrice: 60000,
            sort: 'price_asc',
            radius: 25,
            details: {
              'manufacturer': ' Toyota ',
              'model': 'Corolla',
              'year': '2020',
              'trim': '',
            }).queryParameters,
        {
          'page': '1',
          'type': 'sale',
          'category': 'רכב',
          'city': 'רחובות',
          'q': 'היברידי',
          'minPrice': 10000,
          'maxPrice': 60000,
          'sort': 'price_asc',
          'radius': 25,
          'detail_manufacturer': 'Toyota',
          'detail_model': 'Corolla',
          'detail_year': '2020',
        });
    expect(
        const ListingSearchFilters(category: 'נדל״ן', details: {
          'deal_type': 'rent',
          'property_type': 'apartment',
          'rooms': '3',
          'area_sqm': '80',
        }).queryParameters,
        {
          'page': '1',
          'category': 'נדל״ן',
          'detail_deal_type': 'rent',
          'detail_property_type': 'apartment',
          'detail_rooms': '3',
          'detail_area_sqm': '80',
        });
  });

  for (final invalid in [
    ('-1', '100'),
    ('NaN', '100'),
    ('Infinity', '100'),
    ('200', '100')
  ]) {
    testWidgets(
        'invalid price range $invalid leaves results and sends no search',
        (tester) async {
      await _withListings(tester, (requests) async {
        await _openPanel(tester);
        final before = requests.length;
        await _enter(tester, 'min-price', invalid.$1);
        await _enter(tester, 'max-price', invalid.$2);
        await _tap(tester, find.text('חפש מודעות'));
        expect(requests, hasLength(before));
        expect(_panel, findsOneWidget);
        expect(find.text('מודעת בסיס'), findsOneWidget);
        expect(
            find.text(invalid.$1 == '-1'
                ? 'המחיר חייב להיות אפס או מספר חיובי'
                : invalid.$1 == '200'
                    ? 'מחיר המינימום גדול ממחיר המקסימום'
                    : 'יש להזין מחיר תקין'),
            findsOneWidget);
      });
    });
  }

  testWidgets(
      'desktop search occupies the right and applies vehicle filters to the left',
      (tester) async {
    await _withListings(tester, (requests) async {
      await _openPanel(tester);
      expect(
          tester.widget<AdvancedListingSearchScreen>(_panel).embedded, isTrue);
      expect(tester.getRect(_panel).left, closeTo(411, .1));
      expect(tester.getRect(_panel).right, closeTo(1400, .1));
      expect(tester.getRect(_quickSearch).left, greaterThanOrEqualTo(0));
      expect(tester.getRect(_quickSearch).right, lessThanOrEqualTo(410));
      await _applyCar(tester);
      _expectParameters(requests.last.url.queryParameters, {
        'page': '1',
        'type': 'sale',
        'category': 'רכב',
        'q': 'היברידי',
        'city': 'רחובות',
        'minPrice': 10000,
        'maxPrice': 60000,
        'sort': 'price_asc',
        'radius': 50,
        'detail_manufacturer': 'Toyota',
        'detail_model': 'Corolla',
        'detail_year': '2020',
      });
      expect(_panel, findsOneWidget);
      expect(find.text('תוצאה מסוננת'), findsOneWidget);
    });
  });

  testWidgets(
      'clear removes every committed filter and keeps the desktop search open',
      (tester) async {
    await _withListings(tester, (requests) async {
      await _openPanel(tester);
      await _applyCar(tester);
      await _tap(tester, find.text('נקה מסננים'));
      expect(requests.last.url.queryParameters, {'page': '1'});
      expect(_panel, findsOneWidget);
      await _reveal(tester, _key('query'));
      expect(
          tester.widget<TextField>(_input('query')).controller!.text, isEmpty);
      expect(tester.widget<TextField>(_quickSearch).controller!.text, isEmpty);
      expect(find.text('מודעת בסיס'), findsOneWidget);
    });
  });

  testWidgets('cancel discards draft edits while retaining the applied search',
      (tester) async {
    await _withListings(tester, (requests) async {
      await _openPanel(tester);
      await _enter(tester, 'query', 'חיפוש שמור');
      await _tap(tester, find.text('חפש מודעות'));
      final applied =
          Map<String, String>.from(requests.last.url.queryParameters);
      final before = requests.length;
      await _enter(tester, 'query', 'שינוי לא שמור');
      await _enter(tester, 'min-price', '400');
      await _cancel(tester);
      expect(_panel, findsNothing);
      expect(requests, hasLength(before));
      expect(requests.last.url.queryParameters, applied);
      await _openPanel(tester);
      expect(tester.widget<TextField>(_input('query')).controller!.text,
          'חיפוש שמור');
      await _reveal(tester, _key('min-price'));
      expect(tester.widget<TextField>(_input('min-price')).controller!.text,
          isEmpty);
    });
  });

  testWidgets(
      'changing category clears vehicle fields and submits property fields',
      (tester) async {
    ListingSearchFilters? applied;
    await tester.pumpWidget(_app(AdvancedListingSearchScreen(
        initialFilters: const ListingSearchFilters(category: 'רכב', details: {
          'manufacturer': 'Toyota',
          'model': 'Corolla',
          'year': '2020',
        }),
        embedded: true,
        onApply: (filters) => applied = filters,
        onClear: () {})));
    await tester.pumpAndSettle();
    await _choose(tester, 'category', 'נדל״ן');
    await _choose(tester, 'detail-deal_type', 'השכרה');
    await _choose(tester, 'detail-property_type', 'דירה');
    await _enter(tester, 'detail-rooms', '3');
    await _enter(tester, 'detail-area_sqm', '80');
    await _tap(tester, find.text('חפש מודעות'));
    expect(applied!.queryParameters, {
      'page': '1',
      'category': 'נדל״ן',
      'detail_deal_type': 'rent',
      'detail_property_type': 'apartment',
      'detail_rooms': '3',
      'detail_area_sqm': '80',
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing vehicle manufacturer clears its dependent model',
      (tester) async {
    ListingSearchFilters? applied;
    await tester.pumpWidget(_app(AdvancedListingSearchScreen(
        initialFilters: const ListingSearchFilters(category: 'רכב', details: {
          'manufacturer': 'Toyota',
          'model': 'Corolla',
          'year': '2020',
        }),
        embedded: true,
        onApply: (filters) => applied = filters,
        onClear: () {})));
    await tester.pumpAndSettle();
    await _enter(tester, 'detail-manufacturer', 'Honda');
    await _reveal(tester, _key('detail-model'));
    expect(tester.widget<TextField>(_input('detail-model')).controller!.text,
        isEmpty);
    await _tap(tester, find.text('חפש מודעות'));
    expect(applied!.details['manufacturer'], 'Honda');
    expect(applied!.details.containsKey('model'), isFalse);
    expect(applied!.details['year'], '2020');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mobile applies a full screen search and returns to results',
      (tester) async {
    await _withListings(tester, (requests) async {
      await _openPanel(tester);
      expect(tester.getRect(_panel).width, closeTo(430, .1));
      await _enter(tester, 'query', 'מקרר');
      await _tap(tester, find.text('חפש מודעות'));
      expect(_panel, findsNothing);
      expect(requests.last.url.queryParameters, {'page': '1', 'q': 'מקרר'});
      expect(find.text('תוצאה מסוננת'), findsOneWidget);
      await _openPanel(tester);
      await _tap(tester, find.text('נקה מסננים'));
      expect(_panel, findsNothing);
      expect(requests.last.url.queryParameters, {'page': '1'});
    }, size: const Size(430, 1000));
  });

  testWidgets('desktop to mobile resize keeps the uncommitted search draft',
      (tester) async {
    await _withListings(tester, (requests) async {
      await _openPanel(tester);
      await _enter(tester, 'query', 'טיוטה במעבר');
      final before = requests.length;
      for (final width in [899.0, 900.0, 430.0]) {
        tester.view.physicalSize = Size(width, 1000);
        await tester.pumpAndSettle();
        expect(_panel, findsOneWidget);
        expect(tester.widget<TextField>(_input('query')).controller!.text,
            'טיוטה במעבר');
        expect(requests, hasLength(before));
      }
      await _tap(tester, find.text('חפש מודעות'));
      expect(_panel, findsNothing);
      expect(requests.last.url.queryParameters['q'], 'טיוטה במעבר');
    }, size: const Size(900, 1000));
  });

  testWidgets('older search responses cannot replace the newest results',
      (tester) async {
    final old = Completer<http.Response>();
    addTearDown(() {
      if (!old.isCompleted) old.complete(_json([]));
    });
    await _withListings(tester, (requests) async {
      await tester.enterText(_quickSearch, 'ישן');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      expect(requests.last.url.queryParameters['q'], 'ישן');
      await tester.enterText(_quickSearch, 'חדש');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('התוצאה החדשה'), findsOneWidget);
      old.complete(_json([
        {..._listing, 'title': 'תוצאה ישנה'}
      ]));
      await tester.pumpAndSettle();
      expect(find.text('התוצאה החדשה'), findsOneWidget);
      expect(find.text('תוצאה ישנה'), findsNothing);
    }, respond: (request) async {
      if (request.url.queryParameters['q'] == 'ישן') return old.future;
      return _json([
        {
          ..._listing,
          if (request.url.queryParameters['q'] == 'חדש')
            'title': 'התוצאה החדשה',
        }
      ]);
    });
  });

  testWidgets(
      'leaving search restores post, personal listings and details to the left',
      (tester) async {
    await _withListings(tester, (requests) async {
      await _openPanel(tester);
      await tester.tap(find.text('פרסום מתקדם').first);
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      expect(
          tester
              .widget<PostListingScreen>(find.byType(PostListingScreen))
              .embedded,
          isTrue);
      expect(
          tester.getRect(find.byType(PostListingScreen)).left, closeTo(0, .1));
      expect(tester.getRect(find.byType(PostListingScreen)).right,
          closeTo(989, .1));
      await _openPanel(tester);
      expect(find.byType(PostListingScreen), findsNothing);
      await tester.tap(find.byTooltip('המודעות שלי'));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      expect(
          tester
              .widget<MyListingsScreen>(find.byType(MyListingsScreen))
              .embedded,
          isTrue);
      expect(
          tester.getRect(find.byType(MyListingsScreen)).left, closeTo(0, .1));
      expect(tester.getRect(find.byType(MyListingsScreen)).right,
          closeTo(989, .1));
      await _openPanel(tester);
      expect(find.byType(MyListingsScreen), findsNothing);
      await tester.tap(find.text('מודעת בסיס'));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      expect(
          tester
              .widget<ListingDetailScreen>(find.byType(ListingDetailScreen))
              .embedded,
          isTrue);
      expect(tester.getRect(find.byType(ListingDetailScreen)).left,
          closeTo(0, .1));
      expect(tester.getRect(find.byType(ListingDetailScreen)).right,
          closeTo(989, .1));
      expect(tester.getRect(_quickSearch).left, greaterThanOrEqualTo(990));
    });
  });

  testWidgets(
      'advanced search fits a small phone with keyboard and enlarged text',
      (tester) async {
    _size(tester, const Size(320, 740));
    ListingSearchFilters? applied;
    await tester.pumpWidget(_app(
        AdvancedListingSearchScreen(
            initialFilters: const ListingSearchFilters(),
            embedded: true,
            onApply: (filters) => applied = filters,
            onClear: () {}),
        keyboard: true));
    await tester.pumpAndSettle();
    await _enter(tester, 'query', 'חיפוש בטלפון');
    await _enter(tester, 'min-price', '10');
    await _enter(tester, 'max-price', '100');
    await _tap(tester, find.text('חפש מודעות'));
    expect(applied!.query, 'חיפוש בטלפון');
    expect(applied!.minPrice, 10);
    expect(applied!.maxPrice, 100);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final field in ['query', 'city', 'min-price', 'max-price']) {
    testWidgets(
        'reset $field preserves the other draft fields without a search',
        (tester) async {
      await _withListings(tester, (requests) async {
        await _openPanel(tester);
        final values = {
          'query': 'חיפוש שמור',
          'city': 'ירושלים',
          'min-price': '100',
          'max-price': '200',
        };
        for (final entry in values.entries) {
          await _enter(tester, entry.key, entry.value);
        }
        final before = requests.length;
        await _tap(tester, _key('clear-$field'));
        expect(_key('clear-$field'), findsNothing);
        for (final entry in values.entries) {
          expect(await _textValue(tester, entry.key),
              entry.key == field ? '' : entry.value);
        }
        expect(requests, hasLength(before));
        await _tap(tester, find.text('חפש מודעות'));
        _expectParameters(requests.last.url.queryParameters, {
          'page': '1',
          if (field != 'query') 'q': values['query']!,
          if (field != 'city') 'city': values['city']!,
          if (field != 'min-price') 'minPrice': 100,
          if (field != 'max-price') 'maxPrice': 200,
        });
      });
    });
  }

  for (final field in ['rooms', 'property_type']) {
    testWidgets(
        'reset property $field preserves other details and basic filters',
        (tester) async {
      final details = {
        'deal_type': 'rent',
        'property_type': 'apartment',
        'rooms': '3',
        'street': 'הרצל',
        'area_sqm': '80',
      };
      await _withDraft(
          tester,
          ListingSearchFilters(
              category: 'נדל״ן',
              query: 'דירה שמורה',
              city: 'ירושלים',
              minPrice: 100,
              maxPrice: 200,
              details: details), (applied) async {
        final barriers = find.byType(ModalBarrier).evaluate().length;
        await _tap(tester, _key('clear-detail-$field'));
        expect(find.byType(ModalBarrier).evaluate().length, barriers,
            reason: 'Resetting a dropdown must not open its menu');
        expect(_key('clear-detail-$field'), findsNothing);
        expect(applied, isEmpty);
        if (field == 'rooms') {
          expect(await _textValue(tester, 'detail-rooms'), isEmpty);
          await _reveal(tester, _key('detail-property_type'));
          expect(_selectionValue(tester, 'detail-property_type'), 'apartment');
        } else {
          await _reveal(tester, _key('detail-property_type'));
          expect(_selectionValue(tester, 'detail-property_type'),
              anyOf(isNull, ''));
          expect(await _textValue(tester, 'detail-rooms'), '3');
        }
        await _tap(tester, find.text('חפש מודעות'));
        _expectParameters(applied.single.queryParameters, {
          'page': '1',
          'category': 'נדל״ן',
          'q': 'דירה שמורה',
          'city': 'ירושלים',
          'minPrice': 100,
          'maxPrice': 200,
          for (final entry in details.entries)
            if (entry.key != field) 'detail_${entry.key}': entry.value,
        });
      });
    });
  }

  testWidgets('reset manufacturer clears model and trim while retaining year',
      (tester) async {
    await _withDraft(
        tester,
        const ListingSearchFilters(
            category: 'רכב',
            query: 'רכב שמור',
            details: {
              'manufacturer': 'Toyota',
              'model': 'Corolla',
              'trim': 'LE',
              'year': '2020',
            }), (applied) async {
      await _tap(tester, _key('clear-detail-manufacturer'));
      for (final field in ['manufacturer', 'model', 'trim']) {
        expect(await _textValue(tester, 'detail-$field'), isEmpty);
      }
      expect(await _textValue(tester, 'detail-year'), '2020');
      expect(applied, isEmpty);
      await _tap(tester, find.text('חפש מודעות'));
      expect(applied.single.queryParameters, {
        'page': '1',
        'category': 'רכב',
        'q': 'רכב שמור',
        'detail_year': '2020',
      });
    });
  });

  testWidgets('reset category clears its details and keeps basic filters',
      (tester) async {
    await _withListings(tester, (requests) async {
      await _openPanel(tester);
      await _enter(tester, 'query', 'חיפוש שמור');
      await _enter(tester, 'city', 'ירושלים');
      await _enter(tester, 'min-price', '100');
      await _choose(tester, 'category', 'רכב');
      await _enter(tester, 'detail-manufacturer', 'Toyota');
      await _enter(tester, 'detail-model', 'Corolla');
      final before = requests.length;
      await _tap(tester, _key('clear-category'));
      expect(_selectionValue(tester, 'category'), 'הכל');
      expect(_key('detail-manufacturer'), findsNothing);
      expect(_key('detail-model'), findsNothing);
      expect(await _textValue(tester, 'query'), 'חיפוש שמור');
      expect(await _textValue(tester, 'city'), 'ירושלים');
      expect(await _textValue(tester, 'min-price'), '100');
      expect(requests, hasLength(before));
      await _tap(tester, find.text('חפש מודעות'));
      _expectParameters(requests.last.url.queryParameters, {
        'page': '1',
        'q': 'חיפוש שמור',
        'city': 'ירושלים',
        'minPrice': 100,
      });
    });
  });

  testWidgets(
      'reset type sort condition and radius restores their defaults only',
      (tester) async {
    await _withDraft(
        tester,
        const ListingSearchFilters(
            type: 'sale',
            category: 'אחר',
            query: 'מוצר שמור',
            city: 'ירושלים',
            minPrice: 100,
            maxPrice: 200,
            sort: 'price_desc',
            condition: 'good',
            radius: 30), (applied) async {
      for (final setting in [
        ('type', 'all'),
        ('sort', 'newest'),
        ('condition', 'all')
      ]) {
        final barriers = find.byType(ModalBarrier).evaluate().length;
        await _tap(tester, _key('clear-${setting.$1}'));
        expect(find.byType(ModalBarrier).evaluate().length, barriers,
            reason: 'Resetting a dropdown must not open its menu');
        expect(_selectionValue(tester, setting.$1), setting.$2);
        expect(_key('clear-${setting.$1}'), findsNothing);
      }
      await _tap(tester, _key('clear-radius'));
      expect(
          tester
              .widget<Slider>(
                  find.descendant(of: _panel, matching: find.byType(Slider)))
              .value,
          0);
      expect(_key('clear-radius'), findsNothing);
      expect(applied, isEmpty);
      await _tap(tester, find.text('חפש מודעות'));
      _expectParameters(applied.single.queryParameters, {
        'page': '1',
        'category': 'אחר',
        'q': 'מוצר שמור',
        'city': 'ירושלים',
        'minPrice': 100,
        'maxPrice': 200,
      });
    });
  });

  testWidgets('desktop vehicle and price fields each occupy a full width row',
      (tester) async {
    await _withListings(tester, (requests) async {
      await _openPanel(tester);
      await _choose(tester, 'category', 'רכב');
      final scrollable =
          find.descendant(of: _panel, matching: find.byType(Scrollable)).first;
      Future<Rect> documentRect(String name) async {
        await _reveal(tester, _key(name));
        final offset =
            tester.state<ScrollableState>(scrollable).position.pixels;
        return tester.getRect(_key(name)).shift(Offset(0, offset));
      }

      Rect? previous;
      for (final field in ['manufacturer', 'model', 'year', 'mileage']) {
        final rect = await documentRect('detail-$field');
        if (previous != null) {
          expect(rect.top, greaterThan(previous.bottom));
          expect(rect.left, closeTo(previous.left, .1));
          expect(rect.right, closeTo(previous.right, .1));
        }
        previous = rect;
      }
      final minimum = await documentRect('min-price');
      final maximum = await documentRect('max-price');
      expect(maximum.top, greaterThan(minimum.bottom));
      expect(maximum.left, closeTo(minimum.left, .1));
      expect(maximum.right, closeTo(minimum.right, .1));
    });
  });
}
