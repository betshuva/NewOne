@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:betshuva/attachment_read_error.dart';
import 'package:betshuva/clipboard_image_paste_web.dart';
import 'package:betshuva/web_chat_attachments_web.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

@JS('DOMException')
extension type _ReadDomException._(JSObject _) implements JSObject {
  external factory _ReadDomException(String message, String name);
}

html.ClipboardEvent paste(List<html.File> files,
    {String? text, void Function(html.DataTransferItem)? prepareItem}) {
  final data = html.DataTransfer();
  for (final file in files) {
    final item = data.items!.addFile(file)!;
    prepareItem?.call(item);
  }
  if (text != null) data.setData('text/plain', text);
  final event = html.ClipboardEvent('paste', {
    'clipboardData': data,
    'bubbles': true,
    'cancelable': true,
  });
  html.document.dispatchEvent(event);
  return event;
}

Future<T> browserValue<T>(WidgetTester tester, Future<T> future) async {
  T? value;
  Object? error;
  var done = false;
  future.then((result) {
    value = result;
    done = true;
  }, onError: (Object failure) {
    error = failure;
    done = true;
  });
  for (var i = 0; i < 200 && !done; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  if (error != null) throw error!;
  expect(done, isTrue, reason: 'Browser snapshot did not complete');
  return value as T;
}

void main() {
  for (final count in [101, 200]) {
    testWidgets('pasting $count files rejects all before accessing file handles',
        (tester) async {
      final focus = FocusNode();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: TextField(focusNode: focus))));
      focus.requestFocus();
      await tester.pump();
      final rejected = <int>[];
      var queued = 0;
      final listener = ClipboardImagePasteListener(
        focusNode: focus,
        onImage: (bytes, name, mime) async => fail('Must not read image'),
        onFiles: (_) async { queued++; },
        onTooManyFiles: rejected.add,
      );
      final prototype = (html.window as JSObject)
          .getProperty<JSFunction>('DataTransferItem'.toJS)
          .getProperty<JSObject>('prototype'.toJS);
      final original = prototype.getProperty<JSFunction>('getAsFile'.toJS);
      var accessed = 0;
      JSObject? unexpectedRead() { accessed++; return null; }
      prototype.setProperty('getAsFile'.toJS, unexpectedRead.toJS);
      addTearDown(() => prototype.setProperty('getAsFile'.toJS, original));
      final event = paste([for (var i = 0; i < count; i++) html.File(['data'], 'file-$i.docx')]);
      await tester.pump();
      expect(event.defaultPrevented, isTrue);
      expect(rejected, [count]);
      expect(queued, 0);
      expect(accessed, 0);
      // A rejected paste must not prevent the next valid paste.
      prototype.setProperty('getAsFile'.toJS, original);
      paste([html.File(['data'], 'one.docx')]);
      await tester.pump();
      expect(queued, 1);
      listener.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('DOM failure codes survive without exposing the browser message',
      (tester) async {
    final source = html.File(['data'], 'private-document.docx');
    JSObject failStream() => throw _ReadDomException(
        'PRIVATE local path', 'NotReadableError');
    (source as JSObject).setProperty('stream'.toJS, failStream.toJS);
    final trace = ClipboardReadDiagnostics(batchSize: 2, index: 1);
    final file = WebChatAttachmentFile.clipboard(source, diagnostics: trace);
    addTearDown(() => releaseWebChatAttachments([file]));
    await expectLater(file.uploadSource,
        throwsA(isA<AttachmentReadException>().having(
            (error) => error.diagnostics, 'technical metadata', {
          'origin': 'clipboard', 'batchSize': 2, 'index': 1,
          'events': [
            {'stage': 'snapshot', 'code': 'started'},
            {'stage': 'snapshot', 'code': 'NotReadableError'},
            {'stage': 'fallback', 'code': 'unavailable'},
          ],
        })));
  });
  for (final count in [1, 3, 100]) {
    testWidgets(
        'browser pastes $count files and retains blobs across navigation',
        (tester) async {
      final focus = FocusNode();
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TextField(focusNode: focus))));
      focus.requestFocus();
      await tester.pump();
      final gate = Completer<void>();
      List<PlatformFile>? captured;
      var calls = 0;
      final listener = ClipboardImagePasteListener(
        focusNode: focus,
        onImage: (bytes, name, mime) async =>
            fail('File paste must use the shared upload queue'),
        onFiles: (files) async {
          calls++;
          captured = files;
          await gate.future;
        },
      );
      final sources = [
        for (var i = 0; i < count; i++)
          html.File(
              [
                Uint8List.fromList([37, 80, 68, 70, i])
              ],
              'מסמך-$i.pdf',
              {'type': 'application/pdf'})
      ];
      final event = paste(sources);
      expect(event.defaultPrevented, isTrue);
      expect(calls, 1);
      expect(captured!.map((f) => f.name), sources.map((f) => f.name));
      expect(captured!.every((f) => f.bytes == null && f.size == 5), isTrue);
      // A duplicate paste while the same operation is running is ignored.
      paste(sources);
      expect(calls, 1);
      final copies = await browserValue(
          tester,
          Future.wait(captured!
              .cast<WebChatAttachmentFile>()
              .map((file) => file.uploadSource)));
      expect(copies.length, count);
      for (var i = 0; i < count; i++) {
        expect(identical(copies[i], sources[i]), isFalse);
        expect(copies[i].name, sources[i].name);
        expect(copies[i].size, sources[i].size);
      }
      final contents = await tester.runAsync(() async {
        final reader = html.FileReader()..readAsArrayBuffer(copies.first);
        await reader.onLoadEnd.first;
        expect(reader.error, isNull);
        return reader.result as Uint8List;
      });
      expect(contents, [37, 80, 68, 70, 0]);
      final url = (captured!.first as WebChatAttachmentFile).objectUrl;
      listener.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
      final response =
          await tester.runAsync(() => html.HttpRequest.request(url));
      expect(response!.status, 200);
      // The file stays readable after the chat closes, until its queue ends.
      gate.complete();
      await tester.pump();
      await tester.runAsync(() async {
        await expectLater(html.HttpRequest.request(url), throwsA(anything));
      });
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'paste captures a file handle immediately and recovers an unreadable reference',
      (tester) async {
    final focus = FocusNode();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TextField(focusNode: focus))));
    focus.requestFocus();
    await tester.pump();
    final gate = Completer<void>();
    WebChatAttachmentFile? captured;
    var handleRequests = 0;
    final listener = ClipboardImagePasteListener(
        focusNode: focus,
        onImage: (bytes, name, mime) async => fail('Expected file queue'),
        onFiles: (files) async {
          captured = files.single as WebChatAttachmentFile;
          await gate.future;
        });
    final stale = html.File(['old'], 'document.docx');
    final fresh = html.File(['fresh'], 'document.docx');
    JSObject failStream() =>
        throw StateError('clipboard reference is unreadable');
    (stale as JSObject).setProperty('stream'.toJS, failStream.toJS);
    final event = paste([stale], prepareItem: (item) {
      final handle = JSObject();
      handle.setProperty('kind'.toJS, 'file'.toJS);
      handle.setProperty(
          'getFile'.toJS, (() => Future.value(fresh as JSObject).toJS).toJS);
      final object = (html.window as JSObject)
          .getProperty<JSFunction>('DataTransferItem'.toJS)
          .getProperty<JSObject>('prototype'.toJS);
      final oldFile = object.getProperty<JSFunction>('getAsFile'.toJS);
      final oldHandle =
          object.getProperty<JSFunction>('getAsFileSystemHandle'.toJS);
      addTearDown(() {
        object.setProperty('getAsFile'.toJS, oldFile);
        object.setProperty('getAsFileSystemHandle'.toJS, oldHandle);
      });
      object.setProperty('getAsFile'.toJS, (() => stale as JSObject).toJS);
      object.setProperty(
          'getAsFileSystemHandle'.toJS,
          (() {
            handleRequests++;
            return Future<JSObject?>.value(handle).toJS;
          }).toJS);
    });
    expect(event.defaultPrevented, isTrue);
    expect(handleRequests, 1);
    final copy = await browserValue(tester, captured!.uploadSource);
    expect(copy.name, 'document.docx');
    expect(copy.size, 5);
    gate.complete();
    await tester.pump();
    listener.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'an unreadable clipboard source is reported by name without breaking the next file',
      (tester) async {
    final source = html.File(['data'], 'unreadable.docx');
    JSObject failStream() => throw StateError('source no longer readable');
    (source as JSObject).setProperty('stream'.toJS, failStream.toJS);
    final broken = WebChatAttachmentFile.clipboard(source);
    final good =
        WebChatAttachmentFile.clipboard(html.File(['data'], 'good.docx'));
    // Snapshot errors can happen while the user is still confirming the batch.
    // They must stay attached to their own file, not escape as zone errors.
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await expectLater(
        broken.uploadSource,
        throwsA(isA<AttachmentReadException>().having(
            (error) => error.fileName, 'file name', 'unreadable.docx').having(
            (error) => error.diagnostics?['events'], 'safe failure stages', [
              {'stage': 'snapshot', 'code': 'started'},
              {'stage': 'snapshot', 'code': 'StateError'},
              {'stage': 'fallback', 'code': 'unavailable'},
            ])));
    final copy = await browserValue(tester, good.uploadSource);
    expect(copy.name, 'good.docx');
    releaseWebChatAttachments([broken, good]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'text and an unfocused chat do not intercept paste; mixed files keep names',
      (tester) async {
    final focus = FocusNode();
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TextField(focusNode: focus))));
    final gate = Completer<void>();
    List<PlatformFile>? captured;
    final listener = ClipboardImagePasteListener(
      focusNode: focus,
      onImage: (bytes, name, mime) async =>
          fail('Unexpected legacy image callback'),
      onFiles: (files) async {
        captured = files;
        await gate.future;
      },
    );
    final files = [
      html.File(['pdf'], 'אישור.pdf', {'type': 'application/pdf'}),
      html.File(
          ['docx'],
          'מסמך.docx',
          {
            'type':
                'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
          }),
      html.File(
          ['xlsx'],
          'טבלה.xlsx',
          {
            'type':
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
          }),
      html.File(['png'], 'image.png', {'type': 'image/png'}),
    ];
    expect(paste(files).defaultPrevented, isFalse);
    expect(captured, isNull);
    focus.requestFocus();
    await tester.pump();
    expect(paste([], text: 'טקסט רגיל').defaultPrevented, isFalse);
    expect(captured, isNull);
    expect(paste(files).defaultPrevented, isTrue);
    expect(captured!.map((f) => f.name),
        ['אישור.pdf', 'מסמך.docx', 'טבלה.xlsx', 'image.png']);
    gate.complete();
    await tester.pump();
    listener.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
  });
}
