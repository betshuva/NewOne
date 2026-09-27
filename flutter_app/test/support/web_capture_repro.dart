// Manual browser regression target; always build outside the deployed web root:
// flutter build web --release --target test/support/web_capture_repro.dart \
//   --output /tmp/betshuva-capture-repro-web --base-href /
// Query: ?views=4&boundary=1 adds background video overlays and the app wrapper.
// Use camera=fake with Chromium's --use-fake-device-for-media-stream and
// --use-fake-ui-for-media-stream flags to exercise actual getUserMedia.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:betshuva/native_video_player_web.dart';
import 'package:betshuva/web_capture_picker_web.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

html.MediaStream _syntheticStream() {
  final canvas = html.CanvasElement(width: 640, height: 360);
  final stream = canvas.captureStream(20);
  var frame = 0;
  late Timer timer;
  timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
    if (stream.getVideoTracks().every((track) => track.readyState == 'ended')) {
      timer.cancel();
      return;
    }
    canvas.context2D
      ..fillStyle = '#e82943'
      ..fillRect(0, 0, 320, 180)
      ..fillStyle = '#127ed1'
      ..fillRect(320, 0, 320, 180)
      ..fillStyle = '#28bd65'
      ..fillRect(0, 180, 320, 180)
      ..fillStyle = '#f2ce19'
      ..fillRect(320, 180, 320, 180)
      ..fillStyle = 'white'
      ..fillRect((frame++ * 13) % 550, 140, 90, 80)
      ..fillStyle = 'black'
      ..font = 'bold 28px sans-serif'
      ..fillText('CAMERA FRAME $frame', 24, 46);
  });
  return stream;
}

Future<String> _backgroundVideo() async {
  final stream = _syntheticStream();
  final recorder = html.MediaRecorder(stream, {'mimeType': 'video/webm'});
  final chunks = <html.Blob>[];
  recorder.on['dataavailable'].listen((event) {
    chunks.add((event as html.BlobEvent).data!);
  });
  final stopped = recorder.on['stop'].first;
  recorder.start();
  await Future<void>.delayed(const Duration(milliseconds: 700));
  recorder.stop();
  await stopped;
  for (final track in stream.getTracks()) {
    track.stop();
  }
  return html.Url.createObjectUrlFromBlob(html.Blob(chunks, 'video/webm'));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.queryParameters['camera'] != 'fake') {
    final devices = html.window.navigator.mediaDevices! as JSObject;
    devices.setProperty(
        'getUserMedia'.toJS,
        ((JSAny? _) =>
            Future<JSObject>.value(_syntheticStream() as JSObject).toJS).toJS);
  }
  final views = int.tryParse(Uri.base.queryParameters['views'] ?? '') ?? 0;
  final backgroundUrl = views > 0 ? await _backgroundVideo() : null;
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('he', 'IL'),
    supportedLocales: const [Locale('he', 'IL')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: ThemeData(colorSchemeSeed: Colors.blue),
    builder: (context, child) {
      final content =
          Directionality(textDirection: TextDirection.rtl, child: child!);
      return Uri.base.queryParameters['boundary'] == '0'
          ? content
          : RepaintBoundary(child: content);
    },
    home: _CaptureRepro(backgroundUrl: backgroundUrl, views: views),
  ));
}

class _CaptureRepro extends StatefulWidget {
  const _CaptureRepro({required this.backgroundUrl, required this.views});
  final String? backgroundUrl;
  final int views;
  @override
  State<_CaptureRepro> createState() => _CaptureReproState();
}

class _CaptureReproState extends State<_CaptureRepro> {
  String _result = 'No capture';

  Future<void> _capture(bool video) async {
    final file = video
        ? await captureWebVideo(context, creatorId: 'repro')
        : await captureWebPhoto(context, creatorId: 'repro');
    final bytes = await file?.readAsBytes();
    if (!mounted) return;
    setState(() => _result =
        file == null ? 'Cancelled' : '${file.name}: ${bytes!.length} bytes');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Camera reproduction')),
      body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (widget.backgroundUrl != null)
          SizedBox(
              width: 600,
              child: Wrap(spacing: 12, runSpacing: 12, children: [
                for (var i = 0; i < widget.views; i++)
                  NativeWebVideoPlayer(url: widget.backgroundUrl!),
              ])),
        FilledButton(
            onPressed: () => _capture(true), child: const Text('Open video')),
        const SizedBox(height: 16),
        FilledButton(
            onPressed: () => _capture(false), child: const Text('Open photo')),
        const SizedBox(height: 16),
        Text(_result),
      ])));
}
