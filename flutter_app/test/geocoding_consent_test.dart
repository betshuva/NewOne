import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:betshuva/geocoding_consent.dart';

void main() {
  testWidgets('cancellation and dismissal never authorize sending location',
      (tester) async {
    bool? answer;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return TextButton(
        onPressed: () async => answer =
            await requestGeocodingConsent(context, GeocodingPurpose.address),
        child: const Text('open'),
      );
    })));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Geoapify באירופה'), findsOneWidget);
    expect(
        find.textContaining('הקואורדינטות לא יישמרו בפרופיל'), findsOneWidget);
    expect(answer, isNull);
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    answer = null;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('precise sharing explicitly discloses storage before approval',
      (tester) async {
    bool? answer;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return TextButton(
        onPressed: () async => answer =
            await requestGeocodingConsent(context, GeocodingPurpose.nearby),
        child: const Text('open'),
      );
    })));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('המיקום המדויק יישמר בשרת'), findsOneWidget);
    expect(find.textContaining('הפעולה אינה חובה'), findsOneWidget);
    expect(answer, isNull);
    await tester.tap(find.text('אישור ושליחת המיקום'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  test('malformed error responses fall back to manual address entry', () {
    expect(
        geocodingErrorMessage('<html>proxy failed</html>'), contains('ידנית'));
    expect(geocodingErrorMessage('{"error":"המכסה נוצלה"}'), 'המכסה נוצלה');
  });

  testWidgets('source credits fit a narrow phone screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: Center(
              child: SizedBox(
        width: 280,
        child: GeocodingAttribution(),
      ))),
    ));
    expect(find.text('Powered by Geoapify'), findsOneWidget);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    expect(find.text('© OpenAddresses contributors'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
