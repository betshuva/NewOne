import 'package:flutter/widgets.dart';

class NativeWebVideoPlayer extends StatelessWidget {
  final String url;
  final VoidCallback? onOptions;
  const NativeWebVideoPlayer({super.key, required this.url, this.onOptions});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
