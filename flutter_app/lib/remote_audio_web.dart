// ignore_for_file: avoid_web_libraries_in_flutter
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
