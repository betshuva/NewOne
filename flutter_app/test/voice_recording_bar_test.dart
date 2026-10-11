import 'package:betshuva/voice_recording_bar.dart';
import 'package:betshuva/audio_visualizer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('recording actions fit a narrow phone without a wrapping input',
      (tester) async {
    var sends = 0, cancellations = 0;
    final level = ValueNotifier<double>(0);
    addTearDown(level.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 280,
                    child: VoiceRecordingBar(
                        level: level,
                        timeLabel: '1:59:59',
                        onSend: () => sends++,
                        onCancel: () => cancellations++))))));
    expect(tester.getSize(find.byType(VoiceRecordingBar)).height,
        lessThanOrEqualTo(48));
    expect(find.byType(TextField), findsNothing);
    level.value = 0.75;
    await tester.pump();
    expect(
        tester
            .widget<AudioVisualizer>(
                find.byKey(const ValueKey('recording-level')))
            .value,
        0.75);
    await tester.tap(find.byTooltip('סיים ושלח'));
    await tester.tap(find.byTooltip('בטל הקלטה'));
    expect(sends, 1);
    expect(cancellations, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
