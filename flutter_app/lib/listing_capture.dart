import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'native_photo_capture.dart';
import 'native_video_capture.dart';
import 'web_capture_picker.dart';

const listingVideoCaptureLimit = Duration(seconds: 10);
// Leave a small margin for the encoder's final frames and container close.
const _listingVideoRecordingDeadline = Duration(milliseconds: 9500);

/// Collects a bounded draft. Cancelling a later capture keeps earlier photos.
/// The caller owns the returned files and starts their uploads after capture.
Future<List<XFile>> captureListingPhotos(BuildContext context,
    {required int maxPhotos, String creatorId = 'listing'}) async {
  final limit = maxPhotos.clamp(0, 8);
  final photos = <XFile>[];
  while (photos.length < limit) {
    if (!context.mounted) break;
    final photo = kIsWeb
        ? await captureWebPhoto(context, creatorId: creatorId)
        : await captureNativePhoto(context);
    if (photo == null) break;
    photos.add(photo);
    if (!context.mounted || photos.length == limit) break;
    final continueCapture = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                title: const Text('תמונות למודעה'),
                content: Text('צולמו ${photos.length} מתוך $limit תמונות'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('סיום')),
                  FilledButton.icon(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('צילום נוסף')),
                ],
              ),
            ));
    if (continueCapture != true) break;
  }
  return photos;
}

/// The listing upload flow performs its own scan after this short capture.
Future<XFile?> captureListingVideo(BuildContext context,
    {String creatorId = 'listing'}) {
  if (!context.mounted) return Future.value(null);
  return kIsWeb
      ? captureWebVideo(context,
          creatorId: creatorId, maxDuration: _listingVideoRecordingDeadline)
      : captureNativeVideo(context,
          creatorId: creatorId, maxDuration: _listingVideoRecordingDeadline);
}
