import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('model search ignores punctuation in both directions', () {
    expect(normalizeListingSearchText('LW-6810'), 'lw6810');
    expect(normalizeListingSearchText('LW6810'),
        normalizeListingSearchText('LW-6810'));
    expect(normalizeListingSearchText('KMS 9912'),
        normalizeListingSearchText('KMS-9912'));
    expect(normalizeListingSearchText('Qrevo / Curv'), 'qrevocurv');
  });

  testWidgets('advanced listing form renders while catalog loads',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(
      home: PostListingScreen(
        token: 'test-token',
        me: <String, dynamic>{'city': 'רחובות'},
        embedded: true,
      ),
    ));
    await tester.pump();

    final exceptions = <Object>[];
    Object? exception;
    while ((exception = tester.takeException()) != null) {
      exceptions.add(exception!);
    }
    expect(exceptions.whereType<StackOverflowError>(), isEmpty);
    expect(find.text('פרסום מתקדם'), findsOneWidget);
    expect(find.text('קטגוריה'), findsOneWidget);
    expect(find.text('כותרת המודעה *'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
