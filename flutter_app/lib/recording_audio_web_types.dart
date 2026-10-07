abstract class WebRecordingAudio {
  Future<String?> stop();
  Future<void> cancel();
  bool get recording;
}
