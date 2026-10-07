@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:betshuva/recording_audio_web.dart';
import 'package:betshuva/recording_upload.dart';

void main() {
  test('real Opus microphone chunks stage before stop and remain playable',
      () async {
    final context = (html.window as JSObject).getProperty<JSFunction>('AudioContext'.toJS).callAsConstructor<JSObject>();
    final destination = context.callMethod<JSObject>('createMediaStreamDestination'.toJS);
    final oscillator = context.callMethod<JSObject>('createOscillator'.toJS);
    oscillator.callMethod('connect'.toJS, destination);
    oscillator.callMethod('start'.toJS);
    await context.callMethod<JSPromise>('resume'.toJS).toDart;
    final devices = html.window.navigator.mediaDevices! as JSObject;
    final original = devices.getProperty<JSFunction>('getUserMedia'.toJS);
    devices.setProperty(
        'getUserMedia'.toJS,
        ((JSAny? _) => Future.value(destination.getProperty<JSObject>('stream'.toJS)).toJS)
            .toJS);
    addTearDown(() async {
      devices.setProperty('getUserMedia'.toJS, original);
      oscillator.callMethod('stop'.toJS);
      await context.callMethod<JSPromise>('close'.toJS).toDart;
    });
    final remote = <int>[];
    var sends = 0;
    final client = MockClient((r) async {
      if (r.method == 'PUT') {
        expect(int.parse(r.headers['Upload-Offset']!), remote.length);
        remote.addAll(r.bodyBytes);
        return http.Response(jsonEncode({'offset': remote.length}), 200);
      }
      if (r.url.path.endsWith('/seal')) {
        expect(jsonDecode(r.body)['sha256'], sha256.convert(remote).toString());
      }
      if (r.url.path == '/api/upload') sends++;
      return http.Response('{}', 200);
    });
    final recorder = await http.runWithClient(
        () => startWebRecordingAudio(
            api: 'https://example.test/api',
            token: 'fixture',
            name: 'synthetic.webm'),
        () => client);
    expect(recorder, isNotNull);
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(remote.length, greaterThan(0));
    expect(recorder!.recording, true);
    expect(sends, 0);
    final path = await recorder.stop();
    final file = XFile(path!, mimeType: 'audio/webm');
    final response = await RecordingUpload.upload(
        file: file,
        token: 'fixture',
        name: 'synthetic.webm',
        fields: {'recordedAudio': 'true', 'toUserId': 'self'});
    expect(response?.statusCode, 200);
    expect(remote, await file.readAsBytes());
    expect(sends, 1);
    final audio = html.AudioElement()..muted = true;
    final loaded =
        audio.onLoadedData.first.timeout(const Duration(seconds: 10));
    audio.src = path;
    await loaded;
    await audio.play();
    audio.pause();
    html.Url.revokeObjectUrl(path);
  });
}
