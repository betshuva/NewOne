import 'package:clock/clock.dart';
import 'package:image_picker/image_picker.dart';

import 'capture_file_name.dart';

Future<String> capturedPhotoFileName(XFile photo,
    {required String creatorId}) async {
  final extension = photo.name.split('.').last.toLowerCase();
  if (!const {'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'}
      .contains(extension)) {
    throw const FormatException('Unsupported captured photo format');
  }
  DateTime capturedAt;
  try {
    capturedAt = await photo.lastModified();
  } catch (_) {
    capturedAt = clock.now();
  }
  return captureFileNames.create(
    kind: 'photo',
    extension: extension,
    creatorId: creatorId,
    capturedAt: capturedAt,
  );
}
