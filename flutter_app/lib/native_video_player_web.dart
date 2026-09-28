// Legacy DOM bridge required by HtmlElementView in the current implementation.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'message_hover.dart';
import 'media_playback_progress.dart';
import 'media_pointer_barrier.dart';

class NativeWebVideoPlayer extends StatefulWidget {
  final String url;
  final VoidCallback? onOptions;
  final String? token;
  final String? progressApi;
  const NativeWebVideoPlayer({super.key, required this.url, this.onOptions,
    this.token, this.progressApi});

  @override
  State<NativeWebVideoPlayer> createState() => _NativeWebVideoPlayerState();
}

class _NativeWebVideoPlayerState extends State<NativeWebVideoPlayer>
    with WidgetsBindingObserver {
  static int _nextId = 0;
  late final String _viewType;
  late final html.VideoElement _video;
  late final html.DivElement _container;
  html.ButtonElement? _optionsButton;
  StreamSubscription<html.Event>? _contextMenuSubscription;
  StreamSubscription<html.Event>? _optionsSubscription;
  final List<StreamSubscription<html.Event>> _detailSubscriptions = [];
  MediaPlaybackProgress? _progress;
  Future<int?>? _savedPosition;
  Timer? _saveTimer;
  int _generation = 0;
  int _positionMs = 0;
  bool _ready = false;
  bool _dirty = false;
  bool _restoring = false;
  bool _starting = false;
  bool _allowPlay = false;
  bool _resumeAfterRestore = false;
  bool _saveFailed = false;
  bool _routeIsCurrent = true;

  void _updatePointerEvents() {
    _container.style.pointerEvents =
        _routeIsCurrent && mediaPointerBarriers.value == 0 ? 'auto' : 'none';
  }

  bool _current(int generation) => mounted && generation == _generation;

  void _startProgress() {
    ++_generation;
    _ready = false;
    _dirty = false;
    _restoring = false;
    _starting = false;
    _allowPlay = false;
    _resumeAfterRestore = false;
    _positionMs = 0;
    _saveFailed = false;
    _progress = widget.token == null || widget.progressApi == null ? null
        : MediaPlaybackProgress(api: widget.progressApi!, token: widget.token!,
            url: widget.url, mediaType: 'video');
    _savedPosition = _progress?.load();
  }

  Future<void> _setPosition(int milliseconds, int generation) async {
    final duration = _video.duration;
    if (!duration.isFinite || duration <= 0 || !_current(generation)) return;
    final seconds = (milliseconds / 1000).clamp(0, duration).toDouble();
    if ((_video.currentTime - seconds).abs() < .05) return;
    _restoring = true;
    try {
      final seeked = _video.onSeeked.first.timeout(const Duration(seconds: 3),
          onTimeout: () => html.Event('timeout'));
      _video.currentTime = seconds;
      await seeked;
    } finally {
      if (_current(generation)) _restoring = false;
    }
  }

  Future<void> _restore() async {
    final generation = _generation;
    if (_ready || _restoring) return;
    if (_video.currentSrc.isNotEmpty && _video.currentSrc != widget.url) return;
    _restoring = true;
    final saved = await _savedPosition;
    if (!_current(generation)) return;
    _saveFailed = _progress != null && saved == null;
    final end = _video.duration * 1000;
    if (saved != null && saved > 0 && saved < end) {
      await _setPosition(saved, generation);
      if (!_current(generation)) return;
    }
    _restoring = false;
    _positionMs = (_video.currentTime * 1000).round();
    setState(() => _ready = true);
    if (_resumeAfterRestore) {
      _resumeAfterRestore = false;
      await _playFromLatest();
    }
  }

  Future<void> _savePosition() async {
    final progress = _progress;
    if (!_dirty || progress == null) return;
    final generation = _generation;
    _dirty = false;
    final saved = await progress.save(_positionMs);
    if (!_current(generation)) return;
    if (!saved) _dirty = true;
    if (_saveFailed != !saved) setState(() => _saveFailed = !saved);
  }

  void _samplePosition() {
    if (!_ready || _restoring || _starting) return;
    _positionMs = (_video.currentTime * 1000).round();
    _dirty = true;
  }

  Future<void> _playFromLatest() async {
    if (_starting) return;
    final generation = _generation;
    _starting = true;
    _video.pause();
    try {
      await _savePosition();
      if (!_current(generation)) return;
      final saved = await _progress?.load();
      if (!_current(generation)) return;
      _saveFailed = _progress != null && saved == null;
      if (saved != null) {
        await _setPosition(saved >= _video.duration * 1000 ? 0 : saved, generation);
        if (!_current(generation)) return;
        _positionMs = (_video.currentTime * 1000).round();
        _dirty = false;
      }
      _allowPlay = true;
      await _video.play();
    } catch (_) {
      if (_current(generation)) _allowPlay = false;
    } finally {
      if (_current(generation)) setState(() => _starting = false);
    }
  }

  void _showDetails(bool visible) {
    _video.controls = visible;
    _optionsButton?.style.visibility = visible ? 'visible' : 'hidden';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startProgress();
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
    mediaPointerBarriers.addListener(_updatePointerEvents);
    _updatePointerEvents();
    _detailSubscriptions.add(_video.onLoadedMetadata.listen((_) => _restore()));
    _detailSubscriptions.add(_video.onPlay.listen((_) {
      if (_allowPlay) { _allowPlay = false; return; }
      if (!_ready) { _resumeAfterRestore = true; _video.pause(); return; }
      if (_progress != null) _playFromLatest();
    }));
    _detailSubscriptions.add(_video.onTimeUpdate.listen((_) {
      if (!_video.paused) _samplePosition();
    }));
    _detailSubscriptions.add(_video.onSeeked.listen((_) {
      _samplePosition();
      _savePosition();
    }));
    _detailSubscriptions.add(_video.onPause.listen((_) {
      _samplePosition();
      if (!_starting && !_restoring) _savePosition();
    }));
    _detailSubscriptions.add(_video.onEnded.listen((_) {
      if (!_ready || _restoring) return;
      _positionMs = 0;
      _dirty = true;
      _savePosition();
    }));
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _savePosition());
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
    _detailSubscriptions
        .add(_container.onMouseEnter.listen((_) => _showDetails(true)));
    _detailSubscriptions
        .add(_container.onMouseLeave.listen((_) => _showDetails(false)));
    _detailSubscriptions
        .add(_container.onTouchStart.listen((_) => _showDetails(true)));
    _detailSubscriptions
        .add(_container.on['focusin'].listen((_) => _showDetails(true)));
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (_) {
      return _container;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // DOM media does not participate in Flutter's hit testing. A menu/dialog
    // above this route must receive clicks instead of the underlying video.
    _routeIsCurrent = ModalRoute.isCurrentOf(context) != false;
    _updatePointerEvents();
    _showDetails(MessageHover.detailsVisible(context));
  }

  @override
  void didUpdateWidget(covariant NativeWebVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.token != widget.token ||
        oldWidget.progressApi != widget.progressApi) {
      if (!_video.paused) _samplePosition();
      _savePosition();
      _startProgress();
      _video
        ..pause()
        ..src = widget.url
        ..load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (!_video.paused) _samplePosition();
      _savePosition();
    }
  }

  @override
  void dispose() {
    if (!_video.paused) _samplePosition();
    _savePosition();
    ++_generation;
    WidgetsBinding.instance.removeObserver(this);
    mediaPointerBarriers.removeListener(_updatePointerEvents);
    _saveTimer?.cancel();
    _contextMenuSubscription?.cancel();
    _optionsSubscription?.cancel();
    for (final subscription in _detailSubscriptions) {
      subscription.cancel();
    }
    _video
      ..pause()
      ..src = ''
      ..load();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 280,
        height: _saveFailed ? 244 : 222,
        child: Column(children: [Expanded(child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: HtmlElementView(viewType: _viewType),
        )),
          if (_saveFailed) const Text('שמירת ההתקדמות אינה זמינה כרגע',
              style: TextStyle(fontSize: 10)),
        ]),
      );
}
