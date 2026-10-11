import 'package:betshuva/location_message_preview.dart';
import 'package:betshuva/location_map_embed_stub.dart' as native;
import 'package:betshuva/shared_content.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platformCalls = <MethodCall>[];
  setUp(() {
    platformCalls.clear();
    if (kIsWeb) return;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      platformCalls.add(call);
      if (call.method == 'create') return 0;
      if (call.method == 'resize') {
        final args = call.arguments as Map;
        return {'width': args['width'], 'height': args['height']};
      }
      return null;
    });
  });
  tearDown(() {
    if (kIsWeb) return;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
  });
  final named = SharedPlace(
      title: 'רחובות',
      url: Uri.https('www.google.com', '/maps/search/',
          {'api': '1', 'query': 'רחובות'}).toString());
  final point = SharedPlace.point(31.7, 35.2, title: 'נקודת מפגש');
  test('native map rejects unrelated URLs and retains a desktop fallback', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final url in [
      'https://example.com/maps?q=רחובות&output=embed',
      'http://www.google.com/maps?q=רחובות&output=embed',
      'https://www.google.com/maps?q=רחובות',
      'https://www.google.com/maps?q=רחובות&output=embed&redirect=x',
    ]) {
      expect(native.locationMapEmbed(Uri.parse(url)), isA<ColoredBox>());
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(
        native.locationMapEmbed(Uri.https('www.google.com', '/maps',
            {'q': 'רחובות', 'output': 'embed', 'hl': 'he'})),
        isA<ColoredBox>());
  });
  testWidgets('Android uses an embedded map and disposes it with the message',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: LocationMessagePreview(place: named))));
    await tester.pumpAndSettle();
    final map = tester.widget<AndroidView>(find.byType(AndroidView));
    expect(map.viewType, 'com.betshuva.app/location-map');
    final uri = Uri.parse((map.creationParams as Map)['url'] as String);
    expect(uri.host, 'www.google.com');
    expect(uri.queryParameters['q'], 'רחובות');
    expect(uri.queryParameters['output'], 'embed');
    expect(
        find.ancestor(
            of: find.byType(AndroidView), matching: find.byType(IgnorePointer)),
        findsWidgets);
    expect(
        platformCalls.where((call) => call.method == 'create'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(
        platformCalls.where((call) => call.method == 'dispose'), hasLength(1));
    expect(tester.takeException(), isNull);
  }, skip: kIsWeb, variant: TargetPlatformVariant.only(TargetPlatform.android));
  test('preview resolves the actual pin or address and preserves commentary',
      () {
    expect(sharedPlaceMapQuery(named), 'רחובות');
    expect(sharedPlaceMapQuery(point), '31.700000,35.200000');
    expect(locationMessageDisplayText(named.toMessageText()), '');
    expect(locationMessageDisplayText('${named.toMessageText()}\nנתראה כאן'),
        'רחובות\n\nנתראה כאן');
    for (final url in [
      'https://maps.app.goo.gl/abcdef',
      'https://www.google.com/maps/place/example/@31.7,35.2,12z',
      'https://example.com/maps?query=רחובות',
      'https://www.google.com/maps?q=91,35',
    ]) {
      expect(previewableSharedPlace(url), isNull);
      expect(locationMessageDisplayText(url), url);
    }
  });
  for (final place in [named, point]) {
    for (final target in ['Google Maps', 'Waze']) {
      testWidgets(
          '${place.title} map click opens $target with the correct place',
          (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Uri? opened;
        await tester.pumpWidget(MaterialApp(
            home: Scaffold(
                body: LocationMessagePreview(
                    place: place,
                    openLink: (uri) async {
                      opened = uri;
                      return true;
                    }))));
        await tester.pumpAndSettle();
        if (kIsWeb) expect(find.byType(HtmlElementView), findsOneWidget);
        final rect =
            tester.getRect(find.byKey(const ValueKey('shared-location-map')));
        await tester.tapAt(rect.topLeft + const Offset(100, 60));
        await tester.pumpAndSettle();
        expect(find.text('Google Maps'), findsOneWidget);
        expect(find.text('Waze'), findsOneWidget);
        expect(opened, isNull);
        await tester.tap(find.text(target));
        await tester.pumpAndSettle();
        expect(opened?.host, target == 'Waze' ? 'waze.com' : 'www.google.com');
        expect(
            opened?.queryParameters[target == 'Waze'
                ? (place.latitude == null ? 'q' : 'll')
                : 'query'],
            sharedPlaceMapQuery(place));
        expect(find.byType(SimpleDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
  testWidgets('failed navigation gives feedback', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: LocationMessagePreview(
                place: named, openLink: (_) async => false))));
    await tester.tap(find.byKey(const ValueKey('shared-location-map')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google Maps'));
    await tester.pumpAndSettle();
    expect(find.text('לא ניתן לפתוח את המפה. נסה שוב.'), findsOneWidget);
  });
}
