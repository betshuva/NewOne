import 'dart:convert';
import 'package:betshuva/calendar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeCalendarLocation extends GeolocatorPlatform {
  FakeCalendarLocation(this.permission);
  final LocationPermission permission;
  int checks = 0, prompts = 0, positions = 0;
  @override
  Future<LocationPermission> checkPermission() async {
    checks++;
    return permission;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    prompts++;
    return permission;
  }

  @override
  Future<Position> getCurrentPosition(
      {LocationSettings? locationSettings}) async {
    positions++;
    return Position(
        latitude: 32.794,
        longitude: 34.9896,
        timestamp: DateTime.utc(2026, 9, 17),
        accuracy: 20,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0);
  }
}

void main() {
  for (final source in ['profile', 'saved', 'location', 'default']) {
    testWidgets('location permission granted: $source precedence',
        (tester) async {
      final fake = FakeCalendarLocation(LocationPermission.whileInUse);
      final requests = await openCalendar(tester, fake, source);
      expect(fake.prompts, 0);
      if (source == 'default') {
        expect(fake.positions, 1);
        expect(requests.where((r) => r.url.path.endsWith('/location/default')),
            hasLength(1));
        expect(find.textContaining('חיפה'), findsOneWidget);
      } else {
        expect(fake.checks, 0);
        expect(fake.positions, 0);
        expect(requests.where((r) => r.method != 'GET'), isEmpty);
      }
    });
  }
  testWidgets('denied location keeps Jerusalem without permission prompt',
      (tester) async {
    final fake = FakeCalendarLocation(LocationPermission.denied);
    final requests = await openCalendar(tester, fake, 'default');
    expect(fake.checks, 1);
    expect(fake.prompts, 0);
    expect(fake.positions, 0);
    expect(requests.where((r) => r.method != 'GET'), isEmpty);
    expect(find.textContaining('ירושלים'), findsOneWidget);
  });
  testWidgets('restricted account does not attempt device location',
      (tester) async {
    final fake = FakeCalendarLocation(LocationPermission.whileInUse);
    await openCalendar(tester, fake, 'default', locationAllowed: false);
    expect(fake.checks, 0);
    await tester.tap(find.byTooltip('עיר וזמני שבת'));
    await tester.pumpAndSettle();
    expect(find.text('שימוש במיקום הנוכחי'), findsNothing);
  });
}

Future<List<http.Request>> openCalendar(
    WidgetTester tester, FakeCalendarLocation fake, String source,
    {bool locationAllowed = true}) async {
  final previous = GeolocatorPlatform.instance;
  GeolocatorPlatform.instance = fake;
  addTearDown(() => GeolocatorPlatform.instance = previous);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
  final requests = <http.Request>[];
  var located = false;
  http.Response json(Object body) => http.Response(jsonEncode(body), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});
  await http.runWithClient(() async {
    await tester.pumpWidget(const MaterialApp(
        home: CalendarScreen(
            api: 'https://example.test/api', token: 'test-user')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  },
      () => MockClient((request) async {
            requests.add(request);
            if (request.url.path.endsWith('/location/default')) {
              expect(jsonDecode(request.body),
                  {'latitude': 32.794, 'longitude': 34.9896});
              located = true;
              return json({});
            }
            if (request.url.path.endsWith('/settings')) {
              return json({
                'configured': true,
                'source': located ? 'location' : source,
                'location_allowed': locationAllowed,
                'today': '2026-09-17',
                'cities': [],
                'timezones': ['Asia/Jerusalem', 'Europe/London'],
                'settings': {
                  'city': located ? 'חיפה' : 'ירושלים',
                  'timezone': 'Asia/Jerusalem',
                  'latitude': located ? 32.794 : 31.778,
                  'longitude': located ? 34.9896 : 35.235,
                  'israel': true,
                  'candle_minutes': 15
                }
              });
            }
            if (request.url.path.endsWith('/events')) {
              return json({'events': []});
            }
            if (request.url.path.endsWith('/inbox')) {
              return json({'notices': [], 'invitations': []});
            }
            return json({'items': [], 'configured': true});
          }));
  return requests;
}
