// Legacy DOM bridge required by the current WebRTC audio manager.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

Future<bool> resumeRemoteAudio() async {
  final manager =
      html.document.getElementById('html_webrtc_audio_manager_list');
  final elements = manager?.querySelectorAll('audio') ?? const [];
  var played = false;
  for (final element in elements) {
    if (element is! html.AudioElement) continue;
    element
      ..muted = false
      ..volume = 1;
    try {
      await element.play();
      played = true;
    } catch (_) {}
  }
  return played;
}
