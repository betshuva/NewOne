import 'package:clock/clock.dart';

String? normalizeCaptureCreatorId(String value) {
  final id = value.trim();
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(id) ? id : null;
}

final captureFileNames = CaptureFileNameGenerator();

class CaptureFileNameGenerator {
  CaptureFileNameGenerator({this.maxRememberedNames = 512}) {
    if (maxRememberedNames < 1) {
      throw ArgumentError.value(maxRememberedNames, 'maxRememberedNames');
    }
  }

  final int maxRememberedNames;
  final _counts = <String, int>{};

  String create({
    required String kind,
    required String extension,
    required String creatorId,
    DateTime? capturedAt,
  }) {
    if (!const {'photo', 'video', 'audio', 'screenshot'}.contains(kind)) {
      throw ArgumentError.value(kind, 'kind');
    }
    final suffix =
        extension.startsWith('.') ? extension.substring(1) : extension;
    if (!RegExp(r'^[A-Za-z0-9]{1,10}$').hasMatch(suffix)) {
      throw ArgumentError.value(extension, 'extension');
    }
    final creator = normalizeCaptureCreatorId(creatorId);
    if (creator == null) {
      throw ArgumentError.value(creatorId, 'creatorId',
          'A filesystem-safe ASCII creator ID is required');
    }
    final time = (capturedAt ?? clock.now()).toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final date = '${time.year.toString().padLeft(4, '0')}-'
        '${two(time.month)}-${two(time.day)}';
    final timestamp = '${two(time.hour)}-${two(time.minute)}-'
        '${two(time.second)}-${two(time.millisecond ~/ 10)}';
    final base = 'betshuva-$kind-${date}_$timestamp-ID-$creator';
    // Ignore the extension so later audio conversion cannot merge two names.
    final count = (_counts.remove(base) ?? 0) + 1;
    _counts[base] = count;
    if (_counts.length > maxRememberedNames) _counts.remove(_counts.keys.first);
    return '$base${count == 1 ? '' : '_$count'}.$suffix';
  }
}
