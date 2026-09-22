import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:betshuva/captured_photo_name.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:http_parser/http_parser.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:mime/mime.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'own_media_filter_test.dart' as fixtures;

class _Photo extends XFile {
  _Photo(
      {this.fileName = 'camera-original.PNG',
      this.modified,
      this.failStat = false})
      : super(fileName, name: fileName, mimeType: 'image/png');

  final String fileName;
  final DateTime? modified;
  final bool failStat;

  @override
  Future<Uint8List> readAsBytes() async => fixtures.png;

  @override
  Future<int> length() async => fixtures.png.length;

  @override
  Future<DateTime> lastModified() async {
    if (failStat) throw const FileSystemException('test unavailable timestamp');
    return modified ?? DateTime(2026, 9, 23, 14, 7, 36, 250);
  }
}

class _Picker extends fixtures.TestImagePicker {
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    requestedSources.add(source);
    return _Photo();
  }
}

class _TemporaryPath extends PathProviderPlatform {
  _TemporaryPath(this.path);
  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Recorder extends RecordPlatform {
  _Recorder(this.bytes);
  final Uint8List bytes;
  String? recordingPath;
  RecordConfig? config;
  bool recording = false;

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();

  @override
  Future<void> start(String recorderId, RecordConfig config,
      {required String path}) async {
    recordingPath = path;
    this.config = config;
    File(path).writeAsBytesSync(bytes);
    recording = true;
  }

  @override
  Future<bool> isRecording(String recorderId) async => recording;

  @override
  Future<String?> stop(String recorderId) async {
    recording = false;
    return recordingPath;
  }

  @override
  Future<void> dispose(String recorderId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UploadedFile {
  final fields = <String, String>{};
  String? name;
  String? mime;
  List<int>? bytes;
}

Uint8List _recordedWav() {
  final bytes = Uint8List(32044);
  final header = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  header.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  header.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}

Future<_UploadedFile> _readMultipart(http.Request request) async {
  final result = _UploadedFile();
  final boundary =
      MediaType.parse(request.headers['content-type']!).parameters['boundary']!;
  final parts =
      MimeMultipartTransformer(boundary).bind(Stream.value(request.bodyBytes));
  await for (final part in parts) {
    final disposition = HeaderValue.parse(part.headers['content-disposition']!);
    final bytes =
        await part.fold<List<int>>([], (all, data) => all..addAll(data));
    if (disposition.parameters['filename'] case final String name) {
      result.name = name;
      result.mime = part.headers['content-type'];
      result.bytes = bytes;
    } else {
      result.fields[disposition.parameters['name']!] = utf8.decode(bytes);
    }
  }
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('captured photo uses its native capture timestamp and actual extension',
      () async {
    expect(
      await capturedPhotoFileName(
          _Photo(modified: DateTime(2026, 9, 23, 14, 7, 36, 250)),
          creatorId: 'photo-time-test'),
      'betshuva-photo-2026-09-23_14-07-36-25-ID-photo-time-test.png',
    );
  });

  test(
      'captured photo falls back to the clock only when file time is unavailable',
      () async {
    final name = await withClock(
        Clock.fixed(DateTime(2026, 9, 23, 15, 8, 37, 990)),
        () => capturedPhotoFileName(_Photo(failStat: true),
            creatorId: 'fallback-test'));
    expect(name, 'betshuva-photo-2026-09-23_15-08-37-99-ID-fallback-test.png');
  });

  test('captured photo rejects unsupported formats without disguising the file',
      () async {
    await expectLater(
        capturedPhotoFileName(_Photo(fileName: 'image.pdf'),
            creatorId: 'viewer'),
        throwsFormatException);
  });

  for (final group in [false, true]) {
    final scope = group ? 'group' : 'private';
    for (final camera in [true, false]) {
      testWidgets(
          '$scope ${camera ? 'camera gets capture name' : 'gallery retains original name'}',
          (tester) async {
        fixtures.size(tester);
        SharedPreferences.setMockInitialValues({});
        final previous = ImagePickerPlatform.instance;
        final picker = _Picker();
        ImagePickerPlatform.instance = picker;
        addTearDown(() => ImagePickerPlatform.instance = previous);
        final uploads = <_UploadedFile>[];
        await http.runWithClient(() async {
          await tester.pumpWidget(fixtures.chat(group));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          await tester.tap(find.text(
              camera ? (group ? 'מצלמה' : 'צלם תמונה') : 'גלריה (עד 10)'));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 500));
          expect(uploads, hasLength(1));
          final uploaded = uploads.single;
          expect(uploaded.mime, 'image/png');
          expect(uploaded.bytes, fixtures.png);
          expect(uploaded.fields.containsKey('recordedAudio'), isFalse);
          expect(uploaded.fields[group ? 'groupId' : 'toUserId'],
              group ? 'group' : 'friend');
          if (camera) {
            expect(
                uploaded.name,
                matches(RegExp(
                    r'^betshuva-photo-2026-09-23_14-07-36-25-ID-viewer(?:_\d+)?\.png$')));
            expect(picker.requestedSources, [ImageSource.camera]);
          } else {
            expect(uploaded.name, 'own-image.png');
            expect(picker.requestedSources, [ImageSource.gallery]);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull);
        },
            () => MockClient((request) async {
                  if (fixtures.isHistory(request, group)) {
                    return fixtures.json([]);
                  }
                  if (request.method == 'POST' &&
                      request.url.path.endsWith('/upload')) {
                    final upload = await _readMultipart(request);
                    uploads.add(upload);
                    return fixtures.json({
                      'url': fixtures.url,
                      'status': 'pending',
                      'fileName': upload.name
                    });
                  }
                  return fixtures.defaultResponse(request);
                }));
      });
    }

    for (final pending in [true, false]) {
      testWidgets(
          '$scope recording uploads real WAV and uses returned MP3 name when ${pending ? 'pending' : 'approved'}',
          (tester) async {
        fixtures.size(tester);
        SharedPreferences.setMockInitialValues({});
        final directory =
            Directory.systemTemp.createTempSync('betshuva-recording-widget-');
        final previousPath = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _TemporaryPath(directory.path);
        final previousRecorder = RecordPlatform.instance;
        final wav = _recordedWav();
        final recorder = _Recorder(wav);
        RecordPlatform.instance = recorder;
        addTearDown(() {
          RecordPlatform.instance = previousRecorder;
          PathProviderPlatform.instance = previousPath;
          directory.deleteSync(recursive: true);
        });
        _UploadedFile? uploaded;
        String? storedName;
        Map<String, dynamic>? sent;
        final done = Completer<void>();
        await http.runWithClient(() async {
          await tester.pumpWidget(fixtures.chat(group));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.mic));
          await tester.pump(const Duration(milliseconds: 100));
          expect(recorder.recording, isTrue);
          expect(recorder.config?.encoder, AudioEncoder.wav);
          expect(
              recorder.recordingPath!.split('/').last,
              matches(RegExp(
                  r'^betshuva-audio-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-\d{2}-ID-viewer(?:_\d+)?\.wav$')));
          await tester.pump(const Duration(seconds: 1));
          await tester.tap(find.byIcon(Icons.stop_circle));
          await tester.pump();
          // XFile uses actual native I/O; alternate real event-loop turns with
          // fake-clock pumps to complete both reads and multipart delivery.
          for (var attempt = 0; attempt < 30 && !done.isCompleted; attempt++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)));
            if (!done.isCompleted) await tester.pump();
          }
          expect(done.isCompleted, isTrue);
          expect(uploaded, isNotNull);
          expect(uploaded!.name, recorder.recordingPath!.split('/').last);
          expect(uploaded!.mime, 'audio/wav');
          expect(uploaded!.bytes, wav);
          expect(uploaded!.fields['recordedAudio'], 'true');
          expect(uploaded!.fields[group ? 'groupId' : 'toUserId'],
              group ? 'group' : 'friend');
          if (pending) {
            await tester.pump(const Duration(milliseconds: 100));
            expect(find.text(storedName!), findsOneWidget);
            expect(find.text(uploaded!.name!), findsNothing);
            expect(sent, isNull);
          } else {
            expect(sent?['fileName'], storedName);
            expect(sent?['fileType'], 'audio');
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull);
        },
            () => MockClient((request) async {
                  if (fixtures.isHistory(request, group)) {
                    return fixtures.json([]);
                  }
                  if (request.method == 'POST' &&
                      request.url.path.endsWith('/upload')) {
                    uploaded = await _readMultipart(request);
                    storedName =
                        uploaded!.name!.replaceFirst(RegExp(r'\.wav$'), '.mp3');
                    if (pending) done.complete();
                    return fixtures.json({
                      'url': 'https://example.test/$storedName',
                      'status': pending ? 'pending' : 'approved',
                      'fileName': storedName
                    });
                  }
                  if (request.method == 'POST' &&
                      request.url.path.endsWith('/messages')) {
                    sent = jsonDecode(request.body) as Map<String, dynamic>;
                    done.complete();
                    return fixtures
                        .json({'id': 'recorded-message', 'status': 'sent'});
                  }
                  return fixtures.defaultResponse(request);
                }));
      });
    }
  }
}
