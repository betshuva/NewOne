import 'dart:io';
import 'dart:typed_data';
import 'package:betshuva/chat_attachment_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('audio-only WebM uses audio filters and duration limits', () {
    final bytes = File('../test/fixtures/webm-audio.webm').readAsBytesSync();
    expect(chatAttachmentType('recording.WEBM', bytes: bytes), 'audio');
  });

  test('WebM with both audio and video retains video handling', () {
    final bytes = File('../test/fixtures/webm-video.webm').readAsBytesSync();
    expect(chatAttachmentType('clip.webm', bytes: bytes), 'video');
  });

  test('invalid or missing metadata cannot classify a WebM as audio', () {
    final bytes = File('../test/fixtures/webm-audio.webm').readAsBytesSync();
    for (final length in [0, 3, 12, 60]) {
      expect(
          chatAttachmentType('broken.webm',
              bytes: Uint8List.sublistView(bytes, 0, length)),
          'video');
    }
    expect(chatAttachmentType('unknown.webm'), 'video');
    expect(chatAttachmentType('file.exe', bytes: bytes), isNull);
  });
}
