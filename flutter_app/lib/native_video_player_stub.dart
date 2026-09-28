import 'package:flutter/widgets.dart';

class NativeWebVideoPlayer extends StatelessWidget {
  final String url;
  final VoidCallback? onOptions;
  final String? token;
  final String? progressApi;
  const NativeWebVideoPlayer({super.key, required this.url, this.onOptions,
    this.token, this.progressApi});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
