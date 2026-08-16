// ignore: deprecated_member_use
import 'dart:html' as html;

Future<bool> triggerFileDownload(String url, String fileName) async {
  try {
    final anchor = html.AnchorElement(href: url)
      ..download = fileName
      ..style.display = 'none';
    html.document.body?.children.add(anchor);
    anchor.click();
    anchor.remove();
    return true;
  } catch (_) {
    return false;
  }
}
