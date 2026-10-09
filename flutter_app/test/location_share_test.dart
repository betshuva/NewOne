import 'package:betshuva/location_share.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  test('map projection round-trips around the world and clamps polar display',
      () {
    for (final zoom in [2, 7, 18]) {
      for (final point in [
        const LocationMapPoint(31.7683, 35.2137),
        const LocationMapPoint(-33.86, 151.2),
        const LocationMapPoint(0, -179.9),
        const LocationMapPoint(80, 10)
      ]) {
        final restored =
            locationMapUnproject(locationMapProject(point, zoom), zoom);
        expect(restored.latitude, closeTo(point.latitude, 0.000001));
        expect(restored.longitude, closeTo(point.longitude, 0.000001));
      }
      final pole = locationMapUnproject(
          locationMapProject(const LocationMapPoint(90, 1), zoom), zoom);
      expect(pole.latitude, closeTo(85.05112878, 0.000001));
    }
  });

  test('map projection wraps the dateline when panning', () {
    final projected = locationMapProject(const LocationMapPoint(0, 179), 7);
    final wrapped = locationMapUnproject(projected + const Offset(256, 0), 7);
    expect(wrapped.longitude, closeTo(-178.1875, 0.000001));
  });

  testWidgets(
      'a real tap chooses the visible map coordinate without geolocation',
      (tester) async {
    LocationMapPoint? selected;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 560,
                child: LocationPointPicker(
                    loadTiles: false,
                    onSelected: (point) => selected = point)))));
    final canvas = find.byKey(const ValueKey('location-map-canvas'));
    final rect = tester.getRect(canvas);
    await tester.tapAt(rect.center);
    expect(selected?.latitude, closeTo(31.7683, 0.000001));
    expect(selected?.longitude, closeTo(35.2137, 0.000001));
    await tester.tapAt(rect.center + const Offset(100, 0));
    expect(selected!.longitude, greaterThan(35.2137));
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
  });

  testWidgets(
      'manual coordinates create HTTPS map text and leave map loading opt-in',
      (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await showLocationShareDialog(context,
                          api: 'https://example.invalid/api');
                    },
                    child: const Text('פתיחה'))))));
    await tester.tap(find.text('פתיחה'));
    await tester.pumpAndSettle();
    expect(find.byType(LocationPointPicker), findsNothing);
    expect(find.text('הצגת מפה לבחירת נקודה'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'קו רוחב (-90 עד 90)'), '31.7');
    await tester.enterText(
        find.widgetWithText(TextField, 'קו אורך (-180 עד 180)'), '35.2');
    await tester.pump();
    await tester.tap(find.text('המשך לשיתוף'));
    await tester.pumpAndSettle();
    expect(
        result, startsWith('מיקום משותף\nhttps://www.google.com/maps/search/'));
    final uri = Uri.parse(result!.split('\n').last);
    expect(uri.queryParameters['query'], '31.700000,35.200000');
  });

  testWidgets(
      'invalid coordinates block sharing and cancellation returns no message',
      (tester) async {
    String? result = 'before';
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await showLocationShareDialog(context,
                          api: 'https://example.invalid/api');
                    },
                    child: const Text('פתיחה'))))));
    await tester.tap(find.text('פתיחה'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'קו רוחב (-90 עד 90)'), '91');
    await tester.enterText(
        find.widgetWithText(TextField, 'קו אורך (-180 עד 180)'), '35');
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'המשך לשיתוף'))
            .onPressed,
        isNull);
    expect(find.text('יש להזין שני מספרים בטווח המצוין.'), findsOneWidget);
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('GPS is read once only after the explicit confirmation',
      (tester) async {
    final previous = GeolocatorPlatform.instance;
    final location = _FakeLocation();
    GeolocatorPlatform.instance = location;
    addTearDown(() => GeolocatorPlatform.instance = previous);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => showLocationShareDialog(context,
                        api: 'https://example.invalid/api'),
                    child: const Text('פתיחה'))))));
    await tester.tap(find.text('פתיחה'));
    await tester.pumpAndSettle();
    expect(location.serviceChecks, 0);
    expect(location.reads, 0);
    await tester.tap(find.text('קבלת המיקום הנוכחי'));
    await tester.pumpAndSettle();
    expect(location.permissionRequests, 0);
    expect(location.reads, 0);
    await tester.tap(find.text('קבלת מיקום'));
    await tester.pumpAndSettle();
    expect(location.permissionRequests, 1);
    expect(location.reads, 1);
    expect(location.settings?.timeLimit, const Duration(seconds: 15));
    expect(find.text('הנקודה שתישלח: 31.700000, 35.200000'), findsOneWidget);
    expect(find.byType(LocationPointPicker), findsNothing);
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(location.reads, 1);
  });

  testWidgets('a denied GPS permission leaves manual sharing available',
      (tester) async {
    final previous = GeolocatorPlatform.instance;
    final location =
        _FakeLocation(permission: LocationPermission.deniedForever);
    GeolocatorPlatform.instance = location;
    addTearDown(() => GeolocatorPlatform.instance = previous);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => showLocationShareDialog(context,
                        api: 'https://example.invalid/api'),
                    child: const Text('פתיחה'))))));
    await tester.tap(find.text('פתיחה'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('קבלת המיקום הנוכחי'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('קבלת מיקום'));
    await tester.pumpAndSettle();
    expect(location.reads, 0);
    expect(
        find.text(
            'לא ניתנה הרשאה למיקום. אפשר לבחור נקודה במפה או להזין מיקום ידנית.'),
        findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'קו רוחב (-90 עד 90)'), '31');
    await tester.enterText(
        find.widgetWithText(TextField, 'קו אורך (-180 עד 180)'), '35');
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'המשך לשיתוף'))
            .onPressed,
        isNotNull);
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
  });
}

class _FakeLocation extends GeolocatorPlatform {
  final LocationPermission permission;
  _FakeLocation({this.permission = LocationPermission.denied});
  int serviceChecks = 0, permissionRequests = 0, reads = 0;
  LocationSettings? settings;
  @override
  Future<bool> isLocationServiceEnabled() async {
    serviceChecks++;
    return true;
  }

  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Future<LocationPermission> requestPermission() async {
    permissionRequests++;
    return LocationPermission.whileInUse;
  }

  @override
  Future<Position> getCurrentPosition(
      {LocationSettings? locationSettings}) async {
    reads++;
    settings = locationSettings;
    return Position(
        latitude: 31.7,
        longitude: 35.2,
        timestamp: DateTime(2026),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0);
  }
}
