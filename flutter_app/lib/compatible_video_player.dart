import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

bool supportsCompatibleVideoPlayback(Object? error) {
  if (kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android ||
      error is! PlatformException ||
      error.code != 'VideoError') {
    return false;
  }
  // The Android plugin exposes decoder failures only in the error message.
  final message = error.message ?? '';
  return const [
    'MediaCodecVideoRenderer',
    'DecoderInitializationException',
    'Decoder init failed',
  ].any(message.contains);
}

class CompatibleVideoPlayer extends StatefulWidget {
  final Uri url;
  const CompatibleVideoPlayer({super.key, required this.url});

  @override
  State<CompatibleVideoPlayer> createState() => _CompatibleVideoPlayerState();
}

class _CompatibleVideoPlayerState extends State<CompatibleVideoPlayer> {
  static const _channel = MethodChannel('com.betshuva.app/media');
  int _generation = 0;
  bool _launching = false;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _play();
  }

  void _play({bool replacePending = false}) {
    if (_launching && !replacePending) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
    });
    if (!_launching) _launch(generation);
  }

  Future<void> _launch(int generation) async {
    _launching = true;
    final url = widget.url;
    try {
      if (!{'http', 'https'}.contains(url.scheme) || url.host.isEmpty) {
        throw ArgumentError('Unsupported video URL');
      }
      // Native VideoView avoids both the incompatible ImageReader texture and
      // Flutter/SurfaceView composition problems on older Android devices.
      final closed = await _channel
          .invokeMethod<bool>('playVideo', {'url': url.toString()});
      if (!mounted || generation != _generation) return;
      if (closed == true) {
        setState(() => _loading = false);
        final route = ModalRoute.of(context);
        if (route != null && !route.isFirst) {
          final navigator = Navigator.of(context);
          if (route.isCurrent) {
            navigator.pop();
          } else {
            navigator.removeRoute(route);
          }
        }
      } else {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    } finally {
      _launching = false;
      // Finish the old native request before opening a replacement URL.
      if (mounted && generation != _generation) _launch(_generation);
    }
  }

  @override
  void didUpdateWidget(covariant CompatibleVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) _play(replacePending: true);
  }

  Future<void> _openExternally() async {
    if (!await launchUrl(widget.url, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('לא ניתן לפתוח את הסרטון בדפדפן')),
      );
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('וידאו'),
        ),
        body: SafeArea(
          child: Center(
            child: _loading
                ? const CircularProgressIndicator(color: Colors.white)
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (_failed) ...[
                        const Icon(Icons.videocam_off_outlined,
                            color: Colors.white70, size: 40),
                        const SizedBox(height: 12),
                        const Text('לא ניתן לנגן את הסרטון',
                            style: TextStyle(color: Colors.white)),
                        const SizedBox(height: 16),
                      ],
                      Wrap(spacing: 12, runSpacing: 8, children: [
                        FilledButton.icon(
                            onPressed: _play,
                            icon: Icon(_failed ? Icons.refresh : Icons.replay),
                            label: Text(_failed ? 'נסה שוב' : 'נגן שוב')),
                        if (_failed)
                          OutlinedButton.icon(
                              onPressed: _openExternally,
                              icon: const Icon(Icons.open_in_new),
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white),
                              label: const Text('הפעל בדפדפן')),
                      ]),
                    ]),
                  ),
          ),
        ),
      );
}
