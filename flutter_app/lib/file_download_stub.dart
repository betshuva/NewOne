import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

Future<bool> triggerFileDownload(String url, String fileName) async {
  return launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

Future<bool> triggerBytesDownload(
    List<int> bytes, String fileName, String mimeType) async {
  try {
    return await const MethodChannel('com.betshuva.app/media')
            .invokeMethod<bool>('saveFile', {
          'bytes': Uint8List.fromList(bytes),
          'fileName': fileName,
          'mimeType': mimeType,
        }) ??
        false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
