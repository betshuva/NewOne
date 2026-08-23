// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

Future<XFile?> _capture(String accept) async {
  final input = html.FileUploadInputElement()
    ..accept = accept
    ..setAttribute('capture', 'environment')
    ..style.display = 'none';
  html.document.body?.append(input);
  final completer = Completer<XFile?>();

  void finish(XFile? value) {
    if (!completer.isCompleted) completer.complete(value);
    input.remove();
  }

  input.onChange.first.then((_) async {
    final file = input.files?.isNotEmpty == true ? input.files!.first : null;
    if (file == null) return finish(null);
    final reader = html.FileReader()..readAsArrayBuffer(file);
    await reader.onLoad.first;
    final result = reader.result;
    final bytes = result is ByteBuffer
        ? Uint8List.view(result)
        : result is Uint8List
            ? result
            : Uint8List(0);
    finish(XFile.fromData(bytes, name: file.name, mimeType: file.type));
  });
  html.window.onFocus.first.then((_) {
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (input.files?.isNotEmpty != true) finish(null);
    });
  });
  input.click();
  return completer.future;
}

Future<XFile?> captureWebPhoto() => _capture('image/*');
Future<XFile?> captureWebVideo() => _capture('video/*');
