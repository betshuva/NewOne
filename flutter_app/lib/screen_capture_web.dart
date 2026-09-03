import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Captures one frame from a display surface explicitly selected by the user.
/// Chrome always shows its own picker; the stream is stopped after one frame.
Future<Uint8List> captureCurrentAppScreen() async {
  web.MediaStream? stream;
  final video = web.HTMLVideoElement()
    ..autoplay = true
    ..muted = true
    ..playsInline = true;
  try {
    final options = web.DisplayMediaStreamOptions(
      video: true.toJS,
      audio: false.toJS,
      selfBrowserSurface: 'include',
      surfaceSwitching: 'exclude',
    );
    stream =
        await web.window.navigator.mediaDevices.getDisplayMedia(options).toDart;
    video.srcObject = stream;
    await video.play().toDart;

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while ((video.videoWidth <= 0 || video.videoHeight <= 0) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (video.videoWidth <= 0 || video.videoHeight <= 0) {
      throw StateError('screen frame unavailable');
    }

    await Future<void>.delayed(const Duration(milliseconds: 120));
    final canvas = web.HTMLCanvasElement()
      ..width = video.videoWidth
      ..height = video.videoHeight;
    final context = canvas.getContext('2d') as web.CanvasRenderingContext2D?;
    if (context == null) throw StateError('screen canvas unavailable');
    context.drawImage(video, 0, 0);

    final dataUrl = canvas.toDataURL('image/png');
    final comma = dataUrl.indexOf(',');
    if (comma < 0) throw StateError('invalid screen capture');
    final bytes =
        Uint8List.fromList(base64Decode(dataUrl.substring(comma + 1)));
    if (bytes.isEmpty) throw StateError('empty screen capture');
    return bytes;
  } finally {
    video.pause();
    video.srcObject = null;
    final tracks = stream?.getTracks().toDart ?? <web.MediaStreamTrack>[];
    for (final track in tracks) {
      track.stop();
    }
  }
}
