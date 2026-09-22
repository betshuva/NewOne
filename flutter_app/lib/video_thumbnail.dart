import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'video_thumbnail_stub.dart'
    if (dart.library.io) 'video_thumbnail_native.dart'
    if (dart.library.html) 'video_thumbnail_web.dart' as platform;

/// A still frame; the parent owns taps and opens the full video player.
class VideoThumbnail extends StatefulWidget {
  const VideoThumbnail({
    super.key,
    required this.url,
    required this.fallback,
    this.small = false,
  });

  final String url;
  final Widget fallback;
  final bool small;

  @override
  State<VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<VideoThumbnail> {
  late Future<Uint8List?> _frame;

  @override
  void initState() {
    super.initState();
    _frame = platform.loadVideoThumbnail(widget.url);
  }

  @override
  void didUpdateWidget(covariant VideoThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _frame = platform.loadVideoThumbnail(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: _frame,
        builder: (context, snapshot) {
          // FutureBuilder retains the old data while a new URL is loading.
          if (snapshot.connectionState != ConnectionState.done ||
              snapshot.data == null) {
            return widget.fallback;
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                snapshot.data!,
                fit: BoxFit.cover,
                excludeFromSemantics: true,
                errorBuilder: (_, __, ___) => widget.fallback,
              ),
              Center(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: Color(0x99000000),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(widget.small ? 3 : 8),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: widget.small ? 22 : 36,
                      semanticLabel: 'נגן סרטון',
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
}
