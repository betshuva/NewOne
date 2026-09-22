import 'package:betshuva/capture_file_name.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final capturedAt = DateTime(2026, 9, 23, 14, 7, 36, 429);
  late CaptureFileNameGenerator names;

  setUp(() => names = CaptureFileNameGenerator());

  test('records the local date, time, hundredths, and creator ID', () {
    expect(
        names.create(
            kind: 'video',
            extension: 'mp4',
            creatorId: '2739e1c8-0f22-4af3-aa24-dbfebea8ea66',
            capturedAt: capturedAt),
        'betshuva-video-2026-09-23_14-07-36-42-ID-'
        '2739e1c8-0f22-4af3-aa24-dbfebea8ea66.mp4');
  });

  test('uses the injectable clock when capture time is not supplied', () {
    final name = withClock(
        Clock.fixed(capturedAt),
        () => names.create(
            kind: 'photo', extension: 'jpg', creatorId: 'creator-id'));
    expect(name, 'betshuva-photo-2026-09-23_14-07-36-42-ID-creator-id.jpg');
  });

  test('pads every timestamp component and truncates rather than rounds', () {
    expect(
        names.create(
            kind: 'audio',
            extension: '.m4a',
            creatorId: '42',
            capturedAt: DateTime(2026, 1, 2, 3, 4, 5, 9)),
        'betshuva-audio-2026-01-02_03-04-05-00-ID-42.m4a');
    expect(
        names.create(
            kind: 'audio',
            extension: 'mp3',
            creatorId: '42',
            capturedAt: DateTime(2026, 1, 2, 23, 59, 59, 999)),
        'betshuva-audio-2026-01-02_23-59-59-99-ID-42.mp3');
  });

  test('converts supplied UTC capture times to the device local time', () {
    final utc = DateTime.utc(2026, 9, 23, 14, 7, 36, 429);
    final first = names.create(
        kind: 'video', extension: 'webm', creatorId: 'id', capturedAt: utc);
    final second = CaptureFileNameGenerator().create(
        kind: 'video',
        extension: 'webm',
        creatorId: 'id',
        capturedAt: utc.toLocal());
    expect(first, second);
  });

  test('preserves actual extensions for every supported capture type', () {
    for (final (kind, extension) in [
      ('photo', 'jpeg'),
      ('video', 'MOV'),
      ('video', 'webm'),
      ('audio', 'm4a'),
      ('audio', 'mp3'),
      ('screenshot', 'png'),
    ]) {
      expect(
          names.create(
              kind: kind,
              extension: extension,
              creatorId: 'creator-id',
              capturedAt: capturedAt),
          endsWith('.$extension'));
    }
  });

  test('same-hundredth collisions append a counter independent of extension',
      () {
    final first = names.create(
        kind: 'audio',
        extension: 'm4a',
        creatorId: 'creator-id',
        capturedAt: capturedAt);
    final second = names.create(
        kind: 'audio',
        extension: 'webm',
        creatorId: 'creator-id',
        capturedAt: capturedAt.add(const Duration(milliseconds: 0)));
    final third = names.create(
        kind: 'audio',
        extension: 'mp3',
        creatorId: 'creator-id',
        capturedAt: capturedAt.subtract(const Duration(milliseconds: 8)));
    expect(first, endsWith('-creator-id.m4a'));
    expect(second, endsWith('-creator-id_2.webm'));
    expect(third, endsWith('-creator-id_3.mp3'));
  });

  test('new hundredths and different creators or kinds do not collide', () {
    for (final (kind, creatorId, time) in [
      ('video', 'user-a', capturedAt),
      ('video', 'user-b', capturedAt),
      ('photo', 'user-a', capturedAt),
      ('video', 'user-a', capturedAt.add(const Duration(milliseconds: 10))),
    ]) {
      expect(
          names.create(
              kind: kind,
              extension: 'mp4',
              creatorId: creatorId,
              capturedAt: time),
          isNot(contains('_2.')));
    }
  });

  test('retains recently used counters within a bounded memory', () {
    names = CaptureFileNameGenerator(maxRememberedNames: 2);
    String create(String creatorId) => names.create(
        kind: 'photo',
        extension: 'jpg',
        creatorId: creatorId,
        capturedAt: capturedAt);
    create('a');
    create('b');
    expect(create('a'), endsWith('-a_2.jpg'));
    create('c');
    expect(create('a'), endsWith('-a_3.jpg'));
    expect(create('b'), endsWith('-b.jpg'));
  });

  test('validates IDs without deriving a personal-data fallback', () {
    expect(normalizeCaptureCreatorId('  abc-123_456  '), 'abc-123_456');
    for (final id in [
      '',
      ' ',
      '../name',
      'a/b',
      r'a\b',
      'a b',
      'a@b.com',
      '\u05d9\u05e0\u05d9\u05d1',
      'a' * 129
    ]) {
      expect(normalizeCaptureCreatorId(id), isNull);
      expect(() => names.create(kind: 'video', extension: 'mp4', creatorId: id),
          throwsArgumentError);
    }
  });

  test('rejects unsupported types, unsafe extensions, and unbounded settings',
      () {
    expect(() => CaptureFileNameGenerator(maxRememberedNames: 0),
        throwsArgumentError);
    expect(
        () => names.create(kind: 'document', extension: 'pdf', creatorId: 'id'),
        throwsArgumentError);
    for (final extension in ['', 'video/mp4', '../mp4', 'm p4', '..mp4']) {
      expect(
          () => names.create(
              kind: 'video', extension: extension, creatorId: 'id'),
          throwsArgumentError);
    }
  });
}
