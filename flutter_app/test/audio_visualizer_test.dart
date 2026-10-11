import 'package:betshuva/audio_visualizer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('playback animates while playing and stops when paused',
      (tester) async {
    Widget player(bool playing) => MaterialApp(
        home: Center(
            child: SizedBox(
                width: 180,
                child: AudioVisualizer(value: 0.4, playing: playing))));
    await tester.pumpWidget(player(true));
    final paint = find.descendant(
        of: find.byType(AudioVisualizer), matching: find.byType(CustomPaint));
    final initial = tester.widget<CustomPaint>(paint).painter!;
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<CustomPaint>(paint).painter!.shouldRepaint(initial),
        isTrue);
    await tester.pumpWidget(player(false));
    final paused = tester.widget<CustomPaint>(paint).painter!;
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<CustomPaint>(paint).painter!.shouldRepaint(paused),
        isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
