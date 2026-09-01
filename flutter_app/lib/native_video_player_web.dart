// Legacy DOM bridge required by HtmlElementView in the current implementation.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

class NativeWebVideoPlayer extends StatefulWidget {
  final String url;
  final VoidCallback? onOptions;
  const NativeWebVideoPlayer({super.key, required this.url, this.onOptions});

  @override
  State<NativeWebVideoPlayer> createState() => _NativeWebVideoPlayerState();
}

class _NativeWebVideoPlayerState extends State<NativeWebVideoPlayer> {
  static int _nextId = 0;
  late final String _viewType;
  late final html.VideoElement _video;
  late final html.DivElement _container;
  html.ButtonElement? _optionsButton;
  StreamSubscription<html.Event>? _contextMenuSubscription;
  StreamSubscription<html.Event>? _optionsSubscription;

  @override
  void initState() {
    super.initState();
    _viewType = 'betshuva-video-${_nextId++}';
    _video = html.VideoElement()
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
    _container = html.DivElement()
      ..style.position = 'relative'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.borderRadius = '10px'
      ..style.overflow = 'hidden'
      ..append(_video);
    _contextMenuSubscription = _video.onContextMenu.listen((event) {
      if (widget.onOptions == null) return;
      event.preventDefault();
      widget.onOptions!();
    });
    if (widget.onOptions != null) {
      _optionsButton = html.ButtonElement()
        ..text = '⋮'
        ..title = 'אפשרויות הודעה'
        ..setAttribute('aria-label', 'אפשרויות הודעה')
        ..style.position = 'absolute'
        ..style.top = '8px'
        ..style.left = '8px'
        ..style.width = '34px'
        ..style.height = '34px'
        ..style.padding = '0'
        ..style.border = '1px solid rgba(255,255,255,.65)'
        ..style.borderRadius = '17px'
        ..style.backgroundColor = 'rgba(13,33,55,.78)'
        ..style.color = 'white'
        ..style.fontSize = '24px'
        ..style.lineHeight = '28px'
        ..style.cursor = 'pointer'
        ..style.zIndex = '2';
      _optionsSubscription = _optionsButton!.onClick.listen((event) {
        event.preventDefault();
        event.stopPropagation();
        widget.onOptions?.call();
      });
      _container.append(_optionsButton!);
    }
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (_) {
      return _container;
    });
  }

  @override
  void didUpdateWidget(covariant NativeWebVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _video
        ..pause()
        ..src = widget.url
        ..load();
    }
  }

  @override
  void dispose() {
    _contextMenuSubscription?.cancel();
    _optionsSubscription?.cancel();
    _video
      ..pause()
      ..src = ''
      ..load();
    super.dispose();
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
