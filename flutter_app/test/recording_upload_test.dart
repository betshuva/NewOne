import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:betshuva/recording_upload.dart';

void main() {
  test(
      'uploads before stop, repairs rewritten headers, seals and sends only once approved',
      () async {
    var source = Uint8List.fromList(List.filled(9000, 3));
    var remote = <int>[];
    final methods = <String>[];
    var sends = 0;
    final client = MockClient((request) async {
      methods.add('${request.method} ${request.url.path}');
      if (request.url.path == '/api/upload-sessions') {
        final body = jsonDecode(request.body);
        expect(body['recording'], true);
        expect(body['size'], 0);
        expect(body.containsKey('fields'), false);
      } else if (request.method == 'PUT') {
        expect(int.parse(request.headers['Upload-Offset']!), remote.length);
        remote.addAll(request.bodyBytes);
        return http.Response(jsonEncode({'offset': remote.length}), 200);
      } else if (request.method == 'PATCH') {
        final start = int.parse(request.headers['Upload-Offset']!);
        remote.setRange(
            start, start + request.bodyBytes.length, request.bodyBytes);
      } else if (request.url.path.endsWith('/seal')) {
        final body = jsonDecode(request.body);
        expect(body['sha256'], sha256.convert(remote).toString());
        expect(remote, source);
        expect(body['fields']['toUserId'], 'self');
        expect(sends, 0);
      } else if (request.url.path == '/api/upload') {
        sends++;
        // A lost send response must retry the SAME id, never use multipart.
        if (sends == 1) throw http.ClientException('response lost');
        return http.Response('{"id":"receipt"}', 200);
      }
      return http.Response('{}', 200);
    });
    final stage = RecordingUpload(
        api: 'https://example.test/api',
        token: 'token',
        name: 'recording.wav',
        mime: 'audio/wav',
        client: client,
        autoStart: false,
        length: () async => source.length,
        read: (start, end) async => Uint8List.sublistView(source, start, end));
    await stage.pump();
    expect(remote.length, 9000);
    expect(sends, 0);
    source = Uint8List.fromList(
        [82, 73, 70, 70, ...source.sublist(4), ...List.filled(1000, 9)]);
    final file =
        XFile.fromData(source, name: 'recording.wav', mimeType: 'audio/wav');
    stage.attach(file);
    final result = await RecordingUpload.upload(
        file: file,
        token: 'token',
        name: 'recording.wav',
        fields: {'toUserId': 'self'});
    expect(result?.statusCode, 200);
    expect(sends, 2);
    expect(methods.where((v) => v.startsWith('PATCH')).length, 1);
    expect(
        await RecordingUpload.upload(
            file: file, token: 'token', name: 'recording.wav', fields: {}),
        isNull);
  });

  test('cancel removes staging without sealing or sending', () async {
    final requests = <String>[];
    final client = MockClient((r) async {
      requests.add(r.method);
      return http.Response(r.method == 'PUT' ? '{"offset":5000}' : '{}', 200);
    });
    final bytes = Uint8List(5000);
    final stage = RecordingUpload(
        api: 'https://example.test/api',
        token: 'token',
        name: 'movie.mp4',
        mime: 'video/mp4',
        client: client,
        autoStart: false,
        length: () async => bytes.length,
        read: (s, e) async => Uint8List.sublistView(bytes, s, e));
    await stage.pump();
    await stage.cancel();
    expect(requests, ['POST', 'PUT', 'DELETE']);
  });

  test(
      'failed early transfer preserves local recording and falls back before delivery',
      () async {
    final bytes = Uint8List(5000);
    var sends = 0;
    var deleted = false;
    final client = MockClient((r) async {
      if (r.url.path == '/api/upload') sends++;
      if (r.method == 'PUT') throw http.ClientException('offline');
      if (r.method == 'DELETE') deleted = true;
      return http.Response('{}', 200);
    });
    final stage = RecordingUpload(
        api: 'https://example.test/api',
        token: 'token',
        name: 'voice.wav',
        mime: 'audio/wav',
        client: client,
        autoStart: false,
        length: () async => bytes.length,
        read: (s, e) async => Uint8List.sublistView(bytes, s, e));
    await stage.pump();
    final file = XFile.fromData(bytes);
    expect(await stage.finish(file, name: 'voice.wav', fields: {}), isNull);
    expect(await file.readAsBytes(), bytes);
    expect(deleted, true);
    expect(sends, 0);
  });

  test('account switch discards the old private recording session', () async {
    var deleted = false;
    final client = MockClient((r) async {
      if (r.method == 'DELETE') deleted = true;
      return http.Response(r.method == 'PUT' ? '{"offset":5000}' : '{}', 200);
    });
    final bytes = Uint8List(5000);
    final stage = RecordingUpload(
        api: 'https://example.test/api',
        token: 'original',
        name: 'voice.wav',
        mime: 'audio/wav',
        client: client,
        autoStart: false,
        length: () async => bytes.length,
        read: (s, e) async => Uint8List.sublistView(bytes, s, e));
    await stage.pump();
    final file = XFile.fromData(bytes);
    stage.attach(file);
    expect(
        await RecordingUpload.upload(
            file: file, token: 'different', name: 'voice.wav', fields: {}),
        isNull);
    expect(deleted, true);
  });
}
