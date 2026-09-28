import 'package:flutter/widgets.dart';

/// Native DOM videos bypass Flutter hit testing. Count covering media dialogs
/// across navigators, including their exit animation, without pausing playback.
final mediaPointerBarriers = ValueNotifier<int>(0);

class MediaPointerBarrier extends StatefulWidget {
  const MediaPointerBarrier({super.key, required this.child});
  final Widget child;

  @override
  State<MediaPointerBarrier> createState() => _MediaPointerBarrierState();
}

class _MediaPointerBarrierState extends State<MediaPointerBarrier> {
  @override
  void initState() {
    super.initState();
    mediaPointerBarriers.value++;
  }

  @override
  void dispose() {
    mediaPointerBarriers.value--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
