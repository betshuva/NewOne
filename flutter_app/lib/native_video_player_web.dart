// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class NativeWebVideoPlayer extends StatefulWidget {
  final String url;
  const NativeWebVideoPlayer({super.key, required this.url});

  @override
  State<NativeWebVideoPlayer> createState() => _NativeWebVideoPlayerState();
}

class _NativeWebVideoPlayerState extends State<NativeWebVideoPlayer> {
  static int _nextId = 0;
  late final String _viewType;

  @override
  void initState() {
    super.initState();
    _viewType = 'betshuva-video-${_nextId++}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (_) {
      final video = html.VideoElement()
        ..src = widget.url
        ..controls = true
        ..autoplay = false
        ..preload = 'metadata'
        ..setAttribute('playsinline', 'true')
        ..setAttribute('controlsList', 'nodownload')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'contain'
        ..style.backgroundColor = 'black'
        ..style.borderRadius = '10px';
      return video;
    });
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 280,
        height: 220,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: HtmlElementView(viewType: _viewType),
        ),
      );
}
