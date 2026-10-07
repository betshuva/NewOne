import 'package:betshuva/voice_recording_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('recording actions fit a narrow phone without a wrapping input',
      (tester) async {
    var sends = 0, cancellations = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 280,
                    child: VoiceRecordingBar(
                        timeLabel: '1:59:59',
                        onSend: () => sends++,
                        onCancel: () => cancellations++))))));
    expect(tester.getSize(find.byType(VoiceRecordingBar)).height,
        lessThanOrEqualTo(48));
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('סיים ושלח'));
    await tester.tap(find.byTooltip('בטל הקלטה'));
    expect(sends, 1);
    expect(cancellations, 1);
    expect(tester.takeException(), isNull);
  });
}
