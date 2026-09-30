import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:betshuva/chat_attachment_files.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/attachment_picker.dart';
import 'own_media_filter_test.dart' as fixtures;

void main() {
  FilePicker.platform = AttachmentPicker([]);
  test('picker covers supported formats without accepting arbitrary files', () {
    for (final ext in ['JPG', 'jpeg', 'png', 'gif', 'webp']) {
      expect(chatAttachmentType('photo.$ext'), 'image');
    }
    for (final ext in ['mp4', 'mov', 'webm']) {
      expect(chatAttachmentType('video.$ext'), 'video');
    }
    for (final ext in ['mp3', 'aac', 'm4a', 'wav', 'ogg']) {
      expect(chatAttachmentType('sound.$ext'), 'audio');
    }
    for (final ext in ['pdf', 'docx', 'xlsx']) {
      expect(chatAttachmentType('document.$ext'), 'document');
    }
    expect(chatAttachmentType('fake.pdf.exe'), isNull);
    expect(chatAttachmentType('no-extension'), isNull);
  });

  for (final group in [false, true]) {
    for (final blockImages in [false, true]) {
      testWidgets('mixed selection group=$group blockedImages=$blockImages',
          (tester) async {
        fixtures.size(tester);
        SharedPreferences.setMockInitialValues({});
        final previous = FilePicker.platform;
        final picker = AttachmentPicker([
          MemoryPickedFile('photo.png', fixtures.png),
          MemoryPickedFile('sound.mp3', Uint8List.fromList([73, 68, 51]),
              reportedSize: 150 * 1024 * 1024),
          MemoryPickedFile('too-large.mp3', Uint8List.fromList([73, 68, 51]),
              reportedSize: 150 * 1024 * 1024 + 1),
          MemoryPickedFile('recording.webm',
              File('../test/fixtures/webm-audio.webm').readAsBytesSync()),
          MemoryPickedFile('table-large.xlsx', Uint8List.fromList([80, 75]),
              reportedSize: 51 * 1024 * 1024),
          MemoryPickedFile('table.xlsx', Uint8List.fromList([80, 75])),
          MemoryPickedFile('paper.pdf', Uint8List.fromList([37, 80, 68, 70])),
        ]);
        FilePicker.platform = picker;
        addTearDown(() => FilePicker.platform = previous);
        final sentTypes = <String>[];
        final uploadBodies = <String>[];
        final rejectedAttempts = <Map>[];
        await http.runWithClient(() async {
          await tester.pumpWidget(fixtures.chat(group));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          await tester.tap(find.text('העלאת קבצים'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('כן, העלה'));
          for (var i = 0; i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(picker.calls, 1);
          expect(picker.multiple, isTrue);
          expect(picker.extensions,
              containsAll(['mp3', 'png', 'pdf', 'xlsx', 'mp4']));
          expect(
              sentTypes,
              blockImages
                  ? ['audio', 'audio', 'document', 'document']
                  : ['image', 'audio', 'audio', 'document', 'document']);
          expect(uploadBodies.length, sentTypes.length);
          expect(rejectedAttempts.length, 2);
          expect(rejectedAttempts.first['fileName'], 'too-large.mp3');
          expect(rejectedAttempts.first['fileSize'], 150 * 1024 * 1024 + 1);
          expect(rejectedAttempts.first['maxBytes'], 150 * 1024 * 1024);
          expect(rejectedAttempts.last['fileName'], 'table-large.xlsx');
          expect(rejectedAttempts.last['maxBytes'], 50 * 1024 * 1024);
          expect(uploadBodies.join(), isNot(contains('table-large.xlsx')));
          expect(uploadBodies.join(), isNot(contains('too-large.mp3')));
          expect(uploadBodies.join(), contains('audio/mpeg'));
          expect(uploadBodies.join(), contains('spreadsheetml.sheet'));
          expect(uploadBodies.join(), contains('application/pdf'));
          if (blockImages) {
            expect(uploadBodies.join(), isNot(contains('photo.png')));
          }
          expect(
              find.byKey(const ValueKey('chat-attachment-menu')), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
            () => MockClient((request) async {
                  if (fixtures.isHistory(request, group)) {
                    return fixtures.json([]);
                  }
                  if (request.url.path.endsWith(group
                          ? '/groups/group/filter-settings'
                          : '/receiving-filter') &&
                      blockImages) {
                    return fixtures.json({
                      'filter': {
                        'text': true,
                        'video': false,
                        'men': false,
                        'women': false,
                        'children': false,
                        'nonHumanImages': false,
                      }
                    });
                  }
                  if (request.url.path.endsWith('/upload-attempts/rejected')) {
                    rejectedAttempts.add(jsonDecode(request.body) as Map);
                    return fixtures.json({'recorded': true, 'status': 'rejected'});
                  }
                  if (request.url.path.endsWith('/upload')) {
                    uploadBodies.add(latin1.decode(request.bodyBytes));
                    return fixtures.json({
                      'url': '/uploads/test-${uploadBodies.length}',
                      if (uploadBodies.last.contains('recording.webm'))
                        'fileType': 'audio',
                      'status': 'approved'
                    });
                  }
                  if (request.method == 'POST' &&
                      request.url.path.endsWith('/messages')) {
                    sentTypes.add((jsonDecode(request.body) as Map)['fileType']
                        as String);
                    return fixtures.json({
                      'id': 'message-${sentTypes.length}',
                      'status': 'sent'
                    });
                  }
                  return fixtures.defaultResponse(request);
                }));
      });
    }
  }
}
