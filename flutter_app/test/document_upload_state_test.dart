import 'dart:async';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/attachment_picker.dart';
import 'own_media_filter_test.dart' as fixtures;

class _Documents extends FilePicker {
  _Documents(this.file);
  final PlatformFile file;
  @override
  Future<FilePickerResult?> pickFiles(
          {String? dialogTitle,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          Function(FilePickerStatus)? onFileLoading,
          bool allowCompression = true,
          int compressionQuality = 30,
          bool allowMultiple = false,
          bool withData = false,
          bool withReadStream = false,
          bool lockParentWindow = false,
          bool readSequential = false}) async =>
      FilePickerResult([file]);
}

void main() {
  FilePicker.platform = _Documents(PlatformFile(name: 'unused.pdf', size: 0));
  for (final group in [false, true]) {
    for (final failed in [false, true]) {
      testWidgets(
          'document survives history refresh group=$group failed=$failed',
          (tester) async {
        fixtures.size(tester);
        SharedPreferences.setMockInitialValues({});
        final previous = FilePicker.platform;
        FilePicker.platform = AttachmentPicker([
          MemoryPickedFile('test.docx', Uint8List.fromList([80, 75])),
        ]);
        addTearDown(() => FilePicker.platform = previous);
        final upload = Completer<http.Response>();
        var historyChanged = false;
        var sends = 0;
        var refreshes = 0;
        const fileUrl = '/uploads/test.docx';
        final document = find.byWidgetPredicate((widget) =>
            widget.runtimeType.toString() == '_OfficeDocumentPreview' &&
            (widget as dynamic).fileUrl == fileUrl);
        await http.runWithClient(() async {
          await tester.pumpWidget(fixtures.chat(group));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          await tester.tap(find.text('העלאת קבצים'));
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(find.textContaining('מעלה ואחר כך סורק'), findsOneWidget);
          historyChanged = true;
          // A changed history response must not remove the ongoing upload,
          // even when another message has exactly the same text as its name.
          await tester.pump(const Duration(seconds: 4));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 100));
          expect(refreshes, greaterThan(0));
          expect(find.textContaining('מעלה ואחר כך סורק'), findsOneWidget);
          upload.complete(failed
              ? fixtures.json({'error': 'test unavailable'}, 503)
              : fixtures.json({
                  'status': 'approved',
                  'url': fileUrl,
                  'fileName': 'test.docx',
                  'fileType': 'document',
                }));
          await tester.pumpAndSettle();
          expect(find.textContaining('מעלה ואחר כך סורק'), findsNothing);
          expect(sends, failed ? 0 : 1);
          expect(document, failed ? findsNothing : findsOneWidget);
          // The persisted message replaces the local result exactly once.
          await tester.pump(const Duration(seconds: 4));
          await tester.pumpAndSettle();
          expect(find.textContaining('מעלה ואחר כך סורק'), findsNothing);
          expect(document, failed ? findsNothing : findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
            () => MockClient((request) async {
                  if (request.url.path.endsWith('/upload'))
                    return upload.future;
                  if (fixtures.isHistory(request, group)) {
                    if (historyChanged) refreshes++;
                    return fixtures.json([
                      if (historyChanged)
                        {
                          'id': 'incoming-during-upload',
                          'sender_id': 'friend',
                          'sender_name': 'חבר',
                          'type': 'text',
                          'body': 'test.docx',
                          'created_at': '2026-09-28T17:20:00Z',
                        },
                      if (sends > 0)
                        {
                          'id': 'document-message',
                          'sender_id': 'viewer',
                          'sender_name': 'אני',
                          'type': 'document',
                          'file_url': fileUrl,
                          'file_name': 'test.docx',
                          'message_status': 'delivered',
                          'created_at': '2026-09-28T17:20:01Z',
                        },
                    ]);
                  }
                  if (request.method == 'POST' &&
                      request.url.path.endsWith('/messages')) {
                    sends++;
                    return fixtures.json({
                      'id': 'document-message',
                      'createdAt': '2026-09-28T17:20:01Z',
                      'status': 'sent',
                    });
                  }
                  return fixtures.defaultResponse(request);
                }));
      });
    }
    for (final oversize in [false, true]) {
      testWidgets(
          'document upload group=$group oversize=$oversize has honest progress and size limit',
          (tester) async {
        fixtures.size(tester);
        SharedPreferences.setMockInitialValues({});
        final previous = FilePicker.platform;
        FilePicker.platform = _Documents(PlatformFile(
            name: 'test.pdf',
            size: oversize ? 51 * 1024 * 1024 : 5,
            bytes: oversize ? null : Uint8List.fromList([37, 80, 68, 70, 45])));
        addTearDown(() => FilePicker.platform = previous);
        final upload = Completer<http.Response>();
        var uploads = 0;
        await http.runWithClient(() async {
          await tester.pumpWidget(fixtures.chat(group));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          await tester.tap(find.text('העלאת קבצים'));
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          if (oversize) {
            expect(uploads, 0);
            expect(find.text('הקובץ גדול מדי. ניתן לשלוח קובץ עד 50 MB'),
                findsOneWidget);
          } else {
            expect(uploads, 1);
            expect(find.textContaining('מעלה ואחר כך סורק'), findsOneWidget);
            expect(find.byIcon(Icons.download), findsNothing);
            expect(find.byIcon(Icons.done), findsNothing);
            upload.complete(fixtures.json({'error': 'test unavailable'}, 503));
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
            () => MockClient((request) async {
                  if (request.url.path.endsWith('/upload')) {
                    uploads++;
                    return upload.future;
                  }
                  if (fixtures.isHistory(request, group)) {
                    return fixtures.json([]);
                  }
                  return fixtures.defaultResponse(request);
                }));
      });
    }
  }
}
