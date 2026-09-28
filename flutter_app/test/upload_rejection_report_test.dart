import 'dart:convert';
import 'package:betshuva/upload_rejection_report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  Future<bool> report() => reportRejectedUpload(api: 'https://example.test/api',
      token: 'fixture', fileName: 'large.mp3', fileSize: 157286401,
      fileType: 'audio', maxBytes: 157286400);

  test('rejected upload sends only metadata and waits for recording confirmation', () async {
    await http.runWithClient(() async => expect(await report(), isTrue),
        () => MockClient((request) async {
          expect(request.url.path, '/api/upload-attempts/rejected');
          expect(request.headers['Authorization'], 'Bearer fixture');
          expect(jsonDecode(request.body), {
            'fileName': 'large.mp3', 'fileSize': 157286401,
            'fileType': 'audio', 'maxBytes': 157286400,
            'reasonCode': 'file_too_large',
          });
          return http.Response('{"recorded":true,"status":"rejected"}', 200);
        }));
  });

  test('network errors and unconfirmed responses are not treated as recorded', () async {
    for (final response in [http.Response('{}', 200), http.Response('', 503)]) {
      await http.runWithClient(() async => expect(await report(), isFalse),
          () => MockClient((_) async => response));
    }
    await http.runWithClient(() async => expect(await report(), isFalse),
        () => MockClient((_) async => throw http.ClientException('offline')));
  });
}
