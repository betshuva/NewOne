import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Microphone level, or playback progress with a pulsing current segment.
class AudioVisualizer extends StatefulWidget {
  const AudioVisualizer(
      {super.key,
      required this.value,
      this.playing = false,
      this.recording = false,
      this.color = Colors.blue});
  final double value;
  final bool playing, recording;
  final Color color;
  @override
  State<AudioVisualizer> createState() => _AudioVisualizerState();
}

class _AudioVisualizerState extends State<AudioVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 650));
  void _sync() {
    if (widget.playing && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.playing) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(AudioVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: widget.recording ? 'עוצמת המיקרופון' : 'התקדמות השמעה',
        value: '${(widget.value.clamp(0.0, 1.0) * 100).round()}%',
        child: SizedBox(
          height: 18,
          width: double.infinity,
          child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) => CustomPaint(
                  painter: _AudioBarsPainter(
                      value: widget.value.clamp(0.0, 1.0),
                      pulse: _pulse.value,
                      recording: widget.recording,
                      playing: widget.playing,
                      color: widget.color))),
        ),
      );
}

class _AudioBarsPainter extends CustomPainter {
  const _AudioBarsPainter(
      {required this.value,
      required this.pulse,
      required this.recording,
      required this.playing,
      required this.color});
  final double value, pulse;
  final bool recording, playing;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    const count = 24;
    final step = size.width / count;
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final profile = 0.35 + 0.65 * math.sin((i + 0.5) * math.pi / count);
      final height = recording
          ? 2 + (size.height - 2) * value * profile
          : 4 + (size.height - 4) * profile;
      final played = (i + 1) / count <= value;
      final current = i == (value * count).floor().clamp(0, count - 1);
      paint.color = recording || played
          ? color
          : color.withValues(
              alpha: current && playing ? 0.45 + pulse * 0.55 : 0.2);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(i * step + step * 0.2, (size.height - height) / 2,
                  step * 0.6, height),
              const Radius.circular(2)),
          paint);
    }
  }

  @override
  bool shouldRepaint(_AudioBarsPainter oldDelegate) =>
      value != oldDelegate.value ||
      pulse != oldDelegate.pulse ||
      recording != oldDelegate.recording ||
      playing != oldDelegate.playing ||
      color != oldDelegate.color;
}
