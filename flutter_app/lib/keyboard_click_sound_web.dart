import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

class KeyboardClickSound {
  web.AudioContext? _context;
  web.AudioBuffer? _buffer;
  bool _disposed = false;

  void click() {
    if (_disposed) return;
    try {
      final context = _context ??= web.AudioContext();
      // Resume during the user's tap/keystroke, before any asynchronous work.
      if (context.state == 'suspended') context.resume().toDart.ignore();
      final buffer = _buffer ??= _createBuffer(context);
      final source = context.createBufferSource()..buffer = buffer;
      source.connect(context.destination);
      source.onended = ((web.Event _) => source.disconnect()).toJS;
      source.start();
    } catch (_) {
      // Audio availability must never interrupt message editing.
    }
  }

  web.AudioBuffer _createBuffer(web.AudioContext context) {
    final length = (context.sampleRate * 0.025).round();
    final buffer = context.createBuffer(1, length, context.sampleRate);
    final samples = buffer.getChannelData(0).toDart;
    final noise = math.Random(42);
    for (var i = 0; i < length; i++) {
      final t = i / context.sampleRate;
      final envelope = math.exp(-t * 240) * math.min(1.0, t * 2000);
      samples[i] = ((noise.nextDouble() * 2 - 1) * 0.18 +
              math.sin(2 * math.pi * 1800 * t) * 0.08) *
          envelope;
    }
    return buffer;
  }

  void dispose() {
    _disposed = true;
    _context?.close().toDart.ignore();
    _context = null;
    _buffer = null;
  }
}
