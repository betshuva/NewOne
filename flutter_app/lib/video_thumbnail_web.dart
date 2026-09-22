// The video is decoded off-screen and released after capturing a still image.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';

final _frames = <String, Future<Uint8List?>>{};
final _waiting = Queue<Completer<void>>();
int _active = 0;

Future<Uint8List?> loadVideoThumbnail(String url) {
  if (url.isEmpty) return Future.value(null);
  final cached = _frames.remove(url);
  if (cached != null) {
    _frames[url] = cached;
    return cached;
  }
  final frame = _captureWhenAvailable(url);
  _frames[url] = frame;
  // Bound memory use while allowing grid/list switches to reuse their frames.
  if (_frames.length > 80) _frames.remove(_frames.keys.first);
  return frame;
}

Future<Uint8List?> _captureWhenAvailable(String url) async {
  // Avoid opening a decoder for every card in a large media library at once.
  if (_active >= 3) {
    final slot = Completer<void>();
    _waiting.add(slot);
    await slot.future;
  } else {
    _active++;
  }
  try {
    final result = await _capture(url);
    if (result == null) _frames.remove(url);
    return result;
  } finally {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _active--;
    }
  }
}

Future<Uint8List?> _capture(String url) async {
  final video = html.VideoElement()
    ..crossOrigin = 'anonymous'
    ..muted = true
    ..autoplay = false
    ..preload = 'auto'
    ..setAttribute('playsinline', 'true');
  final result = Completer<Uint8List?>();
  final subscriptions = <StreamSubscription<html.Event>>[];
  void finish(Uint8List? bytes) {
    if (!result.isCompleted) result.complete(bytes);
  }

  void capture() {
    try {
      if (video.videoWidth == 0 || video.videoHeight == 0) {
        finish(null);
        return;
      }
      final scale =
          math.min(1.0, 480 / math.max(video.videoWidth, video.videoHeight));
      final canvas = html.CanvasElement(
        width: math.max(1, (video.videoWidth * scale).round()),
        height: math.max(1, (video.videoHeight * scale).round()),
      );
      canvas.context2D
          .drawImageScaled(video, 0, 0, canvas.width!, canvas.height!);
      finish(base64Decode(canvas.toDataUrl('image/jpeg', .8).split(',').last));
    } catch (_) {
      finish(null);
    }
  }

  subscriptions.add(video.onError.listen((_) => finish(null)));
  subscriptions.add(video.onSeeked.listen((_) => capture()));
  subscriptions.add(video.onLoadedData.listen((_) {
    // Move past the initial frame without starting playback or audio.
    if (video.duration.isFinite && video.duration > .2) {
      video.currentTime = .1;
    } else {
      capture();
    }
  }));
  final timeout = Timer(const Duration(seconds: 12), () => finish(null));
  try {
    video
      ..src = url
      ..load();
    return await result.future;
  } catch (_) {
    return null;
  } finally {
    timeout.cancel();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    video
      ..pause()
      ..removeAttribute('src')
      ..load();
  }
}
