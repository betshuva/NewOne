import 'package:betshuva/filter_history.dart';
import 'package:betshuva/scan_explanation.dart';
import 'package:betshuva/blocked_image_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const reason =
    'התמונה נחסמה — OpenAI: לא צנוע — כתף וחזה חשופים. Gemini: לא צנוע';
const message = 'התמונה נחסמה מטעמי צניעות';
void main() {
  test('modesty explanation survives purge without provider or anatomy detail',
      () {
    for (final purged in [false, true]) {
      expect(
          hiddenImageMessage(
              hiddenReason: 'moderation',
              status: 'rejected',
              reason: reason,
              contentPurged: purged),
          message);
    }
    expect(
        scanExplanation({
          'status': 'rejected_scan',
          'scanReason': reason,
          'classification': {'category': 'men'}
        }),
        message);
    expect(
        hiddenImageMessage(
            hiddenReason: 'moderation',
            status: 'approved',
            reason: null,
            contentPurged: true),
        'התמונה נמחקה ואינה זמינה עוד');
    expect(
        hiddenImageMessage(
            hiddenReason: 'moderation', status: 'rejected', reason: 'אלימות'),
        contains('אלימות'));
  });
  testWidgets('blocked marker opens only the brief modesty message',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 300,
                child: BlockedImageNotice(
                    image: const SizedBox(height: 160),
                    title: 'נחסמה',
                    reason: reason,
                    onlyYouText: 'פרטים נוספים',
                    classification: const {'category': 'men'})))));
    await tester.tap(find.byKey(const ValueKey('blocked-image-marker')));
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    expect(find.textContaining('OpenAI'), findsNothing);
    expect(find.textContaining('כתף'), findsNothing);
    expect(find.textContaining('זוהו:'), findsNothing);
  });
}
