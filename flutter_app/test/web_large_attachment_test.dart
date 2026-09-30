@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:convert';
import 'package:betshuva/web_chat_attachments_web.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final clipboard in [false, true]) {
    test(
        '201MB browser upload resumes without resending bytes clipboard=$clipboard',
        () async {
      final part = html.Blob([Uint8List(1024 * 1024)]);
      final source =
          html.File(List.filled(201, part), 'large.mp4', {'type': 'video/mp4'});
      final file = clipboard
          ? WebChatAttachmentFile.clipboard(source)
          : WebChatAttachmentFile(source);
      try {
        expect(file.bytes, isNull);
        expect(await file.xFile.length(), 201 * 1024 * 1024);
        final result = await uploadPickedWebAttachment(
            file: file,
            url: 'http://127.0.0.1:18763/upload',
            token: 'fixture-token',
            fields: {'groupId': 'fixture-group'});
        expect(result!.statusCode, 200);
        final body = jsonDecode(result.body) as Map;
        expect(body['size'], 201 * 1024 * 1024);
        expect(body['name'], 'large.mp4');
        expect(body['disk'], true);
        expect(body['buffered'], false);
        expect(body['groupId'], 'fixture-group');
        expect(body['acceptedBytes'], (clipboard ? 2 : 1) * 201 * 1024 * 1024);
        expect(body['scans'], clipboard ? 2 : 1);
        expect(body['recoveredInterruptions'], clipboard ? 2 : 1);
      } finally {
        releaseWebChatAttachments([file]);
      }
    });
  }
}
