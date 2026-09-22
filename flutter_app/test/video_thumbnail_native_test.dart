@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:betshuva/video_thumbnail.dart';
import 'package:betshuva/video_thumbnail_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('com.betshuva.app/media');
final _jpeg = base64Decode(
    '/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzU4LjQyLjEwMAD/2wBDAAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABMAAEBAAAAAAAAAAAAAAAAAAAABgEBAQAAAAAAAAAAAAAAAAAABgcQAQAAAAAAAAAAAAAAAAAAAAARAQAAAAAAAAAAAAAAAAAAAAD/wAARCAACAAIDASIAAhEAAxEA/9oADAMBAAIRAxEAPwCLAFF/f//Z');
int _nextUrl = 0;
String _url() => 'https://example.test/thumbnail-${_nextUrl++}.mp4';

void _mockThumbnail(FutureOr<Uint8List?> Function(String url) handler) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_channel, (call) async {
    expectSync(call.method, 'videoThumbnail');
    expectSync(call.arguments, {'url': isA<String>()});
    return handler((call.arguments as Map)['url'] as String);
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
}

Future<void> _mount(WidgetTester tester, String url) async {
  await tester.pumpWidget(MaterialApp(
    home: Center(
      child: SizedBox(
        width: 160,
        height: 90,
        child: VideoThumbnail(url: url, fallback: const Text('fallback')),
      ),
    ),
  ));
  await tester.pump();
}

Uint8List _shownBytes(WidgetTester tester) =>
    (tester.widget<Image>(find.byType(Image)).image as MemoryImage).bytes;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HTTP and HTTPS thumbnails use the native channel and cache success',
      () async {
    final urls = [_url(), _url().replaceFirst('https:', 'http:')];
    final calls = <String>[];
    _mockThumbnail((url) {
      calls.add(url);
      return _jpeg;
    });
    for (final url in urls) {
      final first = await loadVideoThumbnail(url);
      expect(first, _jpeg);
      expect(await loadVideoThumbnail(url), same(first));
    }
    expect(calls, urls);
  });

  test('invalid URLs never reach the native thumbnail decoder', () async {
    var calls = 0;
    _mockThumbnail((_) {
      calls++;
      return _jpeg;
    });
    for (final url in [
      '',
      '/uploads/video.mp4',
      'file:///tmp/video.mp4',
      'content://media/video/1',
      'javascript:alert(1)',
      'https:video.mp4',
      'https://user:secret@example.test/video.mp4',
      'https://example.test:0/video.mp4',
      'https://example.test:65536/video.mp4',
      'https://[invalid/video.mp4',
    ]) {
      expect(await loadVideoThumbnail(url), isNull, reason: url);
    }
    expect(calls, 0);
  });

  test('unsupported native platforms do not request or reuse Android frames',
      () async {
    final url = _url();
    var calls = 0;
    _mockThumbnail((_) {
      calls++;
      return _jpeg;
    });
    expect(await loadVideoThumbnail(url), _jpeg);
    try {
      for (final target in [
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = target;
        expect(await loadVideoThumbnail(url), isNull);
        expect(await loadVideoThumbnail(_url()), isNull);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(calls, 1);
  });

  testWidgets('identical in-flight URLs share one native request and future',
      (tester) async {
    final url = _url();
    final frame = Completer<Uint8List?>();
    var calls = 0;
    _mockThumbnail((_) {
      calls++;
      return frame.future;
    });
    final first = loadVideoThumbnail(url);
    final second = loadVideoThumbnail(url);
    expect(identical(first, second), isTrue);
    await tester.pump();
    expect(calls, 1);
    frame.complete(_jpeg);
    await tester.pump();
    expect(await first, _jpeg);
    expect(await second, same(await first));
  });

  testWidgets('native thumbnail requests run at most two at a time',
      (tester) async {
    final urls = List.generate(5, (_) => _url());
    final gates = <String, Completer<Uint8List?>>{};
    var active = 0, peak = 0;
    _mockThumbnail((url) async {
      active++;
      if (active > peak) peak = active;
      final gate = Completer<Uint8List?>();
      gates[url] = gate;
      try {
        return await gate.future;
      } finally {
        active--;
      }
    });
    final results = urls.map(loadVideoThumbnail).toList();
    await tester.pump();
    expect(gates.keys, urls.take(2));
    for (final url in urls) {
      await tester.pump();
      expect(gates.containsKey(url), isTrue,
          reason: 'Requested $url; native calls: ${gates.keys}');
      gates[url]!.complete(_jpeg);
      await tester.pump();
      expect(await results[urls.indexOf(url)], _jpeg);
      await tester.pump();
      expect(active, lessThanOrEqualTo(2));
    }
    expect(await Future.wait(results), everyElement(_jpeg));
    expect(peak, 2);
    expect(active, 0);
  });

  for (final failure in ['null', 'empty', 'platform', 'missing-plugin']) {
    test('failed $failure thumbnails can be retried', () async {
      final url = _url();
      var calls = 0;
      _mockThumbnail((_) {
        calls++;
        if (calls > 1) return _jpeg;
        if (failure == 'platform') {
          throw PlatformException(code: 'thumbnailFailed');
        }
        if (failure == 'missing-plugin') throw MissingPluginException();
        return failure == 'empty' ? Uint8List(0) : null;
      });
      final first = loadVideoThumbnail(url);
      expect(await first, isNull);
      final retry = loadVideoThumbnail(url);
      expect(identical(first, retry), isFalse);
      expect(await retry, _jpeg);
      expect(calls, 2);
    });
  }

  testWidgets(
      'timeout permits retry and a late result cannot replace its frame',
      (tester) async {
    final url = _url();
    final lateFrame = Completer<Uint8List?>();
    var calls = 0;
    _mockThumbnail((_) {
      calls++;
      if (calls == 1) return lateFrame.future;
      return _jpeg;
    });
    final first = loadVideoThumbnail(url);
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    expect(await first, isNull);
    final retry = loadVideoThumbnail(url);
    await tester.pump();
    final bytes = await retry;
    expect(bytes, _jpeg);
    lateFrame.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pump();
    expect(await loadVideoThumbnail(url), same(bytes));
    expect(calls, 2);
  });

  test('cache evicts the least recently used frame after 80 entries', () async {
    final calls = <String, int>{};
    final urls = List.generate(81, (_) => _url());
    _mockThumbnail((url) {
      calls.update(url, (count) => count + 1, ifAbsent: () => 1);
      return _jpeg;
    });
    for (final url in urls.take(80)) {
      await loadVideoThumbnail(url);
    }
    await loadVideoThumbnail(urls.first);
    await loadVideoThumbnail(urls.last);
    await loadVideoThumbnail(urls.first);
    await loadVideoThumbnail(urls[1]);
    expect(calls[urls.first], 1);
    expect(calls[urls[1]], 2);
  });

  test('cache also evicts frames when encoded bytes exceed its memory budget',
      () async {
    final urls = [_url(), _url()];
    final largeFrame = Uint8List(5 * 1024 * 1024);
    final calls = <String>[];
    _mockThumbnail((url) {
      calls.add(url);
      return largeFrame;
    });
    await loadVideoThumbnail(urls.first);
    await loadVideoThumbnail(urls.last);
    await loadVideoThumbnail(urls.first);
    expect(calls, [urls.first, urls.last, urls.first]);
  });

  testWidgets('Android widget displays the native JPEG and play overlay',
      (tester) async {
    _mockThumbnail((_) => _jpeg);
    await _mount(tester, _url());
    await tester.pumpAndSettle();
    expect(_shownBytes(tester), _jpeg);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.text('fallback'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('widget falls back after failure and can retry when remounted',
      (tester) async {
    final url = _url();
    var calls = 0;
    _mockThumbnail((_) {
      calls++;
      return calls == 1 ? null : _jpeg;
    });
    await _mount(tester, url);
    await tester.pumpAndSettle();
    expect(find.text('fallback'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await _mount(tester, url);
    await tester.pumpAndSettle();
    expect(_shownBytes(tester), _jpeg);
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('URL changes hide the previous frame while the next is loading',
      (tester) async {
    final oldUrl = _url();
    final newUrl = _url();
    final nextFrame = Completer<Uint8List?>();
    _mockThumbnail((url) {
      if (url == oldUrl) return _jpeg;
      return nextFrame.future;
    });
    await _mount(tester, oldUrl);
    await tester.pumpAndSettle();
    expect(_shownBytes(tester), _jpeg);
    await _mount(tester, newUrl);
    expect(find.text('fallback'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    nextFrame.complete(_jpeg);
    await tester.pumpAndSettle();
    expect(_shownBytes(tester), _jpeg);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('late previous URL completion cannot replace the current frame',
      (tester) async {
    final oldUrl = _url();
    final newUrl = _url();
    final previous = Completer<Uint8List?>();
    _mockThumbnail((url) {
      if (url == oldUrl) return previous.future;
      return _jpeg;
    });
    await _mount(tester, oldUrl);
    await _mount(tester, newUrl);
    await tester.pumpAndSettle();
    expect(_shownBytes(tester), _jpeg);
    previous.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pumpAndSettle();
    expect(_shownBytes(tester), _jpeg);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('completion after disposal is safe and reusable on a later mount',
      (tester) async {
    final url = _url();
    final frame = Completer<Uint8List?>();
    var calls = 0;
    _mockThumbnail((_) {
      calls++;
      return frame.future;
    });
    await _mount(tester, url);
    await tester.pumpWidget(const SizedBox.shrink());
    frame.complete(_jpeg);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await _mount(tester, url);
    await tester.pumpAndSettle();
    expect(_shownBytes(tester), _jpeg);
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
