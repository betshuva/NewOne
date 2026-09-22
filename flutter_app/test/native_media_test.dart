import 'dart:async';
import 'package:betshuva/clipboard_image_paste_stub.dart';
import 'package:betshuva/file_download_stub.dart';
import 'package:betshuva/image_clipboard_stub.dart';
import 'package:betshuva/video_recording_limit.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.betshuva.app/media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('copy sends only successful image downloads to the Android clipboard',
      () async {
    var copies = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'copyImage');
      expect(call.arguments['mimeType'], 'image/png');
      expect(call.arguments['bytes'], Uint8List.fromList([1, 2, 3]));
      copies++;
      return true;
    });
    final result = await http.runWithClient(
        () => copyImageToClipboard('https://example.test/image.png'),
        () => MockClient((_) async => http.Response.bytes([1, 2, 3], 200,
            headers: {'content-type': 'image/png'})));
    expect(result, isNull);
    expect(copies, 1);
    final error = await http.runWithClient(
        () => copyImageToClipboard('https://example.test/missing.png'),
        () => MockClient((_) async => http.Response('missing', 404)));
    expect(error, isNotNull);
    expect(copies, 1);
  });

  testWidgets('video stops at 30 seconds exactly once', (tester) async {
    var stops = 0;
    final limit = VideoRecordingLimit(
        duration: const Duration(seconds: 30), onLimit: () => stops++);
    limit.start();
    await tester.pump(const Duration(seconds: 29));
    expect(stops, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(stops, 1);
    await tester.pump(const Duration(seconds: 60));
    expect(stops, 1);
    limit.cancel();
  });

  testWidgets('cancelled and restarted recording has a fresh deadline',
      (tester) async {
    var stops = 0;
    final limit = VideoRecordingLimit(
        duration: const Duration(seconds: 30), onLimit: () => stops++);
    limit.start();
    await tester.pump(const Duration(seconds: 20));
    limit.start();
    await tester.pump(const Duration(seconds: 10));
    expect(stops, 0);
    limit.cancel();
    await tester.pump(const Duration(seconds: 60));
    expect(stops, 0);
  });

  test('paste is explicit, ignores invalid data, and avoids duplicate sends',
      () async {
    final focus = FocusNode();
    var reads = 0, sends = 0;
    final send = Completer<void>();
    final listener = ClipboardImagePasteListener(
        focusNode: focus,
        onImage: (bytes, name, mime) {
          sends++;
          return send.future;
        });
    messenger.setMockMethodCallHandler(channel, (call) async {
      reads++;
      return {
        'bytes': Uint8List.fromList([1, 2, 3]),
        'fileName': 'image.png',
        'mimeType': 'image/png'
      };
    });
    expect(reads, 0);
    final first = listener.pasteImage();
    expect(await listener.pasteImage(), false);
    send.complete();
    expect(await first, true);
    expect(sends, 1);
    messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
              'bytes': Uint8List.fromList([1]),
              'fileName': 'text.txt',
              'mimeType': 'text/plain'
            });
    expect(await listener.pasteImage(), false);
    expect(sends, 1);
    listener.dispose();
    expect(await listener.pasteImage(), false);
    focus.dispose();
  });

  test('paste completion after disposal never sends', () async {
    final response = Completer<Map<String, dynamic>>();
    final focus = FocusNode();
    var sends = 0;
    final listener = ClipboardImagePasteListener(
        focusNode: focus,
        onImage: (bytes, name, mime) async {
          sends++;
        });
    messenger.setMockMethodCallHandler(channel, (_) => response.future);
    final paste = listener.pasteImage();
    listener.dispose();
    response.complete({
      'bytes': Uint8List.fromList([1]),
      'fileName': 'image.png',
      'mimeType': 'image/png'
    });
    expect(await paste, false);
    expect(sends, 0);
    focus.dispose();
  });

  test('save waits for the destination and reports cancellation', () async {
    final selected = Completer<bool>();
    messenger.setMockMethodCallHandler(channel, (call) {
      expect(call.method, 'saveFile');
      expect(call.arguments['bytes'], Uint8List.fromList([1, 2]));
      expect(call.arguments['fileName'], 'screenshot.png');
      return selected.future;
    });
    final saved = triggerBytesDownload([1, 2], 'screenshot.png', 'image/png');
    selected.complete(true);
    expect(await saved, true);
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    expect(
        await triggerBytesDownload([1], 'screenshot.png', 'image/png'), false);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'media');
    });
    expect(
        await triggerBytesDownload([1], 'screenshot.png', 'image/png'), false);
  });
}
