import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

class KeyboardClickSound {
  web.AudioContext? _context;
  Future<web.AudioBuffer>? _ready;
  bool _disposed = false;

  void click() {
    if (_disposed) return;
    try {
      final context = _context ??= web.AudioContext();
      // Resume during the user's tap/keystroke, before any asynchronous work.
      if (context.state == 'suspended') context.resume().toDart.ignore();
      _play(context);
    } catch (_) {
      // Audio availability must never interrupt message editing.
    }
  }

  Future<web.AudioBuffer> _loadBuffer(web.AudioContext context) async {
    final data = await rootBundle.load('assets/sounds/keyboard-click.wav');
    final bytes = Uint8List.fromList(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    return context.decodeAudioData(bytes.buffer.toJS).toDart;
  }

  Future<void> _play(web.AudioContext context) async {
    try {
      final buffer = await (_ready ??= _loadBuffer(context));
      if (_disposed) return;
      final source = context.createBufferSource()..buffer = buffer;
      source.connect(context.destination);
      source.onended = ((web.Event _) => source.disconnect()).toJS;
      source.start();
    } catch (_) {
      // Retry a failed asset load on the next keystroke without affecting typing.
      if (!_disposed) _ready = null;
    }
  }

  void dispose() {
    _disposed = true;
    _context?.close().toDart.ignore();
    _context = null;
    _ready = null;
  }
}
