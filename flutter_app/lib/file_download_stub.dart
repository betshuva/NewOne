import 'package:url_launcher/url_launcher.dart';

Future<bool> triggerFileDownload(String url, String fileName) async {
  return launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

Future<bool> triggerBytesDownload(
        List<int> bytes, String fileName, String mimeType) async =>
    false;
