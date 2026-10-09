import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

class KeyboardClickSound {
  Future<AudioPlayer?>? _ready;
  bool _disposed = false;
  bool _playing = false;

  void click() {
    if (_disposed || _playing) return;
    _play();
  }

  Future<AudioPlayer?> _prepare() async {
    final player = AudioPlayer()..positionUpdater = null;
    try {
      await player.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.assistanceSonification,
          audioFocus: AndroidAudioFocus.none,
        ),
        iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
      ));
      await player.setReleaseMode(ReleaseMode.stop);
      final data = await rootBundle.load('assets/sounds/keyboard-click.wav');
      await player.setSource(BytesSource(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        mimeType: 'audio/wav',
      ));
      return player;
    } catch (_) {
      await player.dispose();
      return null;
    }
  }

  Future<void> _play() async {
    _playing = true;
    try {
      final player = await (_ready ??= _prepare());
      if (_disposed || player == null) return;
      await player.seek(Duration.zero);
      await player.resume();
    } catch (_) {
      // Audio availability must never interrupt message editing.
    } finally {
      _playing = false;
    }
  }

  void dispose() {
    _disposed = true;
    _release();
  }

  Future<void> _release() async {
    try {
      await (await _ready)?.dispose();
    } catch (_) {}
  }
}
