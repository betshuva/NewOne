import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';

Future<XFile?> captureWebCamera(BuildContext context,
        {required String creatorId,
        bool imagesAllowed = true,
        bool videoAllowed = true,
        String? api,
        String? token,
        Duration maxDuration = const Duration(minutes: 2)}) async =>
    null;

Future<XFile?> captureWebPhoto(BuildContext context,
        {required String creatorId}) async =>
    null;
Future<XFile?> captureWebVideo(BuildContext context,
        {required String creatorId,
        String? api,
        String? token,
        Duration maxDuration = const Duration(minutes: 2)}) async =>
    null;
