import 'dart:typed_data';

const maxChatAttachments = 100;

// Matches the upload endpoint's supported formats; the server still validates
// the actual content and applies sender/recipient moderation to every file.
const _types = <String, String>{
  'jpg': 'image',
  'jpeg': 'image',
  'png': 'image',
  'webp': 'image',
  'gif': 'image',
  'pdf': 'document',
  'docx': 'document',
  'xlsx': 'document',
  'mp3': 'audio',
  'aac': 'audio',
  'm4a': 'audio',
  'ogg': 'audio',
  'wav': 'audio',
  'mp4': 'video',
  'webm': 'video',
  'mov': 'video',
  // These are imported locally through dedicated previews, never uploaded as media.
  'ics': 'calendar',
  'vcf': 'contact',
};

final chatAttachmentExtensions = _types.keys.toList(growable: false);

String? chatAttachmentType(String name, {Uint8List? bytes}) {
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  if (extension == 'webm' && bytes != null) {
    return _webmTrackType(bytes) ?? 'video';
  }
  return _types[extension];
}

// This is an early UI hint for duration limits and recipient filters. The
// server independently inspects the container before accepting any upload.
String? _webmTrackType(Uint8List bytes) {
  try {
    if (bytes.length < 4 ||
        bytes[0] != 0x1a ||
        bytes[1] != 0x45 ||
        bytes[2] != 0xdf ||
        bytes[3] != 0xa3) {
      return null;
    }
    for (final root in _webmElements(bytes, 0, bytes.length)) {
      if (root.id != 0x18538067) continue; // Segment
      for (final element in _webmElements(bytes, root.start, root.end)) {
        if (element.id != 0x1654ae6b) continue; // Tracks
        final types = <int>[];
        for (final track in _webmElements(bytes, element.start, element.end)) {
          if (track.id != 0xae) continue; // TrackEntry
          int? type;
          for (final field in _webmElements(bytes, track.start, track.end)) {
            if (field.id != 0x83) continue; // TrackType
            if (field.end - field.start != 1 || type != null) return null;
            type = bytes[field.start];
          }
          if (type == null) return null;
          types.add(type);
        }
        if (types.contains(1)) return 'video';
        if (types.isNotEmpty && types.every((type) => type == 2)) {
          return 'audio';
        }
        return null;
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

Iterable<({int id, int start, int end})> _webmElements(
    Uint8List bytes, int start, int end) sync* {
  var position = start;
  var count = 0;
  while (position < end) {
    if (++count > 10000) throw const FormatException('Too many elements');
    final id = _webmInteger(bytes, position, end, identifier: true);
    final size = _webmInteger(bytes, id.next, end);
    // Only the outer Segment may have an unknown size in the headers read here.
    if (size.value == null && id.value != 0x18538067) {
      throw const FormatException('Unknown element size');
    }
    final declaredStop = size.value == null ? end : size.next + size.value!;
    final stop = id.value == 0x18538067 && declaredStop > end ? end : declaredStop;
    if (stop > end) throw const FormatException('Truncated element');
    yield (id: id.value!, start: size.next, end: stop);
    position = stop;
  }
}

({int? value, int next}) _webmInteger(Uint8List bytes, int start, int end,
    {bool identifier = false}) {
  if (start >= end || bytes[start] == 0) {
    throw const FormatException('Invalid element header');
  }
  var mask = 128;
  var length = 1;
  while ((bytes[start] & mask) == 0) {
    mask >>= 1;
    length++;
  }
  if (length > (identifier ? 4 : 8) || start + length > end) {
    throw const FormatException('Invalid integer length');
  }
  var value = identifier ? bytes[start] : bytes[start] & (mask - 1);
  var unknown = !identifier && value == mask - 1;
  for (var index = 1; index < length; index++) {
    final byte = bytes[start + index];
    unknown = unknown && byte == 255;
    value = value * 256 + byte;
  }
  if (!unknown && value > 9007199254740991) {
    throw const FormatException('Element size exceeds exact integer range');
  }
  return (value: unknown ? null : value, next: start + length);
}
