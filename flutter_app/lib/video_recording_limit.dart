import 'dart:async';

/// One deadline per recording; stopping or disposing cancels the deadline.
class VideoRecordingLimit {
  final Duration duration;
  final void Function() onLimit;
  Timer? _deadline;

  VideoRecordingLimit({required this.duration, required this.onLimit});

  void start() {
    cancel();
    _deadline = Timer(duration, onLimit);
  }

  void cancel() {
    _deadline?.cancel();
    _deadline = null;
  }
}
