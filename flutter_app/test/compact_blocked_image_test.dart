import 'package:betshuva/blocked_image_notice.dart';
import 'package:betshuva/filter_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final history in [false, true]) {
    testWidgets('blocked image is one row with details: history=$history',
        (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final notice = history
          ? FilterHiddenImage(
              api: 'https://example.test',
              token: 'token',
              messageId: 'blocked',
              fileType: 'image',
              status: 'rejected_scan',
              fileName: 'keyboard-image.gif',
              reason: 'סיבת בדיקת הבטיחות',
              onRestored: () async {})
          : const BlockedImageNotice(
              image: Text('תמונה שאסור להציג'),
              title: 'פרטי החסימה',
              reason: 'סיבת בדיקת הבטיחות',
              fileName: 'keyboard-image.gif',
              onlyYouText: 'לא נשלחה');
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Align(alignment: Alignment.topRight, child: notice))));
      expect(find.text('התמונה נחסמה'), findsOneWidget);
      expect(find.text('תמונה שאסור להציג'), findsNothing);
      expect(find.textContaining('keyboard-image.gif'), findsNothing);
      expect(tester.getSize(find.byWidget(notice)).height, lessThan(48));
      await tester.tap(find.text('התמונה נחסמה'));
      await tester.pumpAndSettle();
      expect(find.textContaining('סיבת בדיקת הבטיחות'), findsOneWidget);
      expect(find.textContaining('keyboard-image.gif'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
