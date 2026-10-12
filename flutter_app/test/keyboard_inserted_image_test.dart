import 'package:betshuva/keyboard_inserted_image.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2]);
final _jpeg = Uint8List.fromList([255, 216, 255, 224, 1, 2]);
final _gif87 = Uint8List.fromList([71, 73, 70, 56, 55, 97, 1, 2]);
final _gif89 = Uint8List.fromList([71, 73, 70, 56, 57, 97, 1, 2]);
final _webp =
    Uint8List.fromList([82, 73, 70, 70, 4, 0, 0, 0, 87, 69, 66, 80, 1, 2]);

KeyboardInsertedContent _content(Uint8List? bytes,
        {String mimeType = 'image/png',
        String uri = 'content://keyboard/image'}) =>
    KeyboardInsertedContent(mimeType: mimeType, uri: uri, data: bytes);

Matcher _error(String code) => isA<KeyboardInsertedImageException>()
    .having((error) => error.code, 'code', code)
    .having((error) => error.message, 'readable message', isNotEmpty);

void main() {
  test('keyboard capability advertises only supported server image formats',
      () {
    expect(keyboardInsertedImageMimeTypes,
        ['image/png', 'image/jpeg', 'image/webp', 'image/gif']);
    expect(maxKeyboardInsertedImageBytes, 10 * 1024 * 1024);
  });

  for (final fixture in [
    (mime: 'image/png', bytes: _png, extension: 'png'),
    (mime: 'image/jpeg', bytes: _jpeg, extension: 'jpg'),
    (mime: 'image/webp', bytes: _webp, extension: 'webp'),
    (mime: 'image/gif', bytes: _gif87, extension: 'gif'),
    (mime: 'image/gif', bytes: _gif89, extension: 'gif'),
  ]) {
    test('accepts ${fixture.mime} signature ${fixture.bytes.take(6).toList()}',
        () {
      final original = fixture.bytes.toList();
      final parsed = parseKeyboardInsertedImage(_content(fixture.bytes,
          mimeType: fixture.mime,
          uri: 'content://keyboard/traversal/../../wrong.svg?token=private'));
      expect(parsed.mimeType, fixture.mime);
      expect(parsed.fileName, 'keyboard-image.${fixture.extension}');
      expect(parsed.bytes, orderedEquals(original));
      expect(fixture.bytes, orderedEquals(original));
      expect(parsed.fileName, isNot(contains('private')));
    });
  }

  test('missing or empty bytes cannot fall back to a remote content URI', () {
    expect(
        () => parseKeyboardInsertedImage(
            _content(null, uri: 'https://example.invalid/private.png')),
        throwsA(_error('missing_data')));
    expect(
        () => parseKeyboardInsertedImage(
            _content(Uint8List(0), uri: 'content://keyboard/image')),
        throwsA(_error('empty_data')));
  });

  test('rejects unsupported MIME types instead of guessing from URI', () {
    for (final mime in [
      'image/svg+xml',
      'image/bmp',
      'image/jpg',
      'application/octet-stream',
      'image/png; charset=utf-8',
    ]) {
      expect(
          () => parseKeyboardInsertedImage(_content(_png,
              mimeType: mime, uri: 'content://keyboard/valid.png')),
          throwsA(_error('unsupported_type')),
          reason: mime);
    }
  });

  test('rejects a valid image whose signature does not match declared MIME',
      () {
    for (final mismatch in [
      (mime: 'image/png', bytes: _jpeg),
      (mime: 'image/jpeg', bytes: _gif89),
      (mime: 'image/gif', bytes: _webp),
      (mime: 'image/webp', bytes: _png),
    ]) {
      expect(
          () => parseKeyboardInsertedImage(
              _content(mismatch.bytes, mimeType: mismatch.mime)),
          throwsA(_error('mismatch')),
          reason: mismatch.mime);
    }
  });

  test('rejects truncated image signatures', () {
    for (final image in [
      (mime: 'image/png', bytes: _png, signatureSize: 8),
      (mime: 'image/jpeg', bytes: _jpeg, signatureSize: 3),
      (mime: 'image/gif', bytes: _gif89, signatureSize: 6),
      (mime: 'image/webp', bytes: _webp, signatureSize: 12),
    ]) {
      expect(
          () => parseKeyboardInsertedImage(_content(
              Uint8List.sublistView(image.bytes, 0, image.signatureSize - 1),
              mimeType: image.mime)),
          throwsA(_error('mismatch')),
          reason: image.mime);
    }
  });

  test('WebP requires WEBP container signature in addition to RIFF', () {
    final riffWav =
        Uint8List.fromList([82, 73, 70, 70, 4, 0, 0, 0, 87, 65, 86, 69, 1, 2]);
    expect(
        () => parseKeyboardInsertedImage(
            _content(riffWav, mimeType: 'image/webp')),
        throwsA(_error('mismatch')));
  });

  test('rejects corrupt PNG magic bytes', () {
    for (var index = 0; index < 8; index++) {
      final bytes = Uint8List.fromList(_png);
      bytes[index] = (bytes[index] + 1) % 256;
      expect(() => parseKeyboardInsertedImage(_content(bytes)),
          throwsA(_error('mismatch')),
          reason: 'PNG signature byte $index');
    }
  });

  test('accepts size limit and rejects one extra byte before upload', () {
    final atLimit = Uint8List(maxKeyboardInsertedImageBytes);
    atLimit.setRange(0, _png.length, _png);
    expect(parseKeyboardInsertedImage(_content(atLimit)).bytes.length,
        maxKeyboardInsertedImageBytes);
    final oversized = Uint8List(maxKeyboardInsertedImageBytes + 1);
    oversized.setRange(0, _png.length, _png);
    expect(() => parseKeyboardInsertedImage(_content(oversized)),
        throwsA(_error('too_large')));
  });

  test('filename and MIME are canonical and independent of the supplied URI',
      () {
    final parsed = parseKeyboardInsertedImage(_content(_jpeg,
        mimeType: 'IMAGE/JPEG', uri: 'file:///etc/no-image.svg'));
    expect(parsed.mimeType, 'image/jpeg');
    expect(parsed.fileName, 'keyboard-image.jpg');
    expect(parsed.bytes, orderedEquals(_jpeg));
  });
}
