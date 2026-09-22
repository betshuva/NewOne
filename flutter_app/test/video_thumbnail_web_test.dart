@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'package:betshuva/video_thumbnail_web.dart';
import 'package:flutter_test/flutter_test.dart';

Future<String> _recordVideo() async {
  final canvas = html.CanvasElement(width: 640, height: 360);
  final stream = canvas.captureStream(15);
  final recorder = html.MediaRecorder(stream, {'mimeType': 'video/webm'});
  final chunks = <html.Blob>[];
  final data = recorder.on['dataavailable'].listen((event) {
    chunks.add((event as html.BlobEvent).data!);
  });
  final stopped = recorder.on['stop'].first;
  recorder.start();
  for (var frame = 0; frame < 5; frame++) {
    canvas.context2D
      ..fillStyle = frame.isEven ? '#126ab3' : '#33aaff'
      ..fillRect(0, 0, 640, 360);
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }
  recorder.stop();
  await stopped;
  await data.cancel();
  for (final track in stream.getTracks()) {
    track.stop();
  }
  return html.Url.createObjectUrlFromBlob(html.Blob(chunks, 'video/webm'));
}

void main() {
  test('extracts and caches a bounded JPEG frame from a real browser video',
      () async {
    final url = await _recordVideo();
    try {
      final first = loadVideoThumbnail(url);
      expect(identical(loadVideoThumbnail(url), first), isTrue);
      final bytes = await first;
      expect(bytes, isNotNull);
      expect(bytes!.take(2), [0xff, 0xd8]);
      final image = html.ImageElement();
      final loaded = image.onLoad.first;
      final imageUrl = html.Url.createObjectUrlFromBlob(
        html.Blob([bytes], 'image/jpeg'),
      );
      try {
        image.src = imageUrl;
        await loaded;
        expect(image.naturalWidth, 480);
        expect(image.naturalHeight, 270);
      } finally {
        html.Url.revokeObjectUrl(imageUrl);
      }
      expect(await loadVideoThumbnail(url), same(bytes));
    } finally {
      html.Url.revokeObjectUrl(url);
    }
  });

  test('invalid video falls back without poisoning later attempts', () async {
    final url = html.Url.createObjectUrlFromBlob(html.Blob(['invalid']));
    try {
      final first = loadVideoThumbnail(url);
      expect(await first, isNull);
      final retry = loadVideoThumbnail(url);
      expect(identical(first, retry), isFalse);
      expect(await retry, isNull);
      expect(await loadVideoThumbnail(''), isNull);
    } finally {
      html.Url.revokeObjectUrl(url);
    }
  });
}
