import 'dart:convert';
import 'package:betshuva/attachment_read_error.dart';
import 'package:betshuva/attachment_read_report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final trace = ClipboardReadDiagnostics(batchSize: 2, index: 1)
    ..record('snapshot', 'NotReadableError');
  Future<void> report(AttachmentReadException error) =>
      reportAttachmentReadFailure(
          api: 'https://example.test/api',
          token: 'fixture',
          error: error,
          fileSize: 123);

  test('reports only technical codes without file name or raw failure',
      () async {
    await http.runWithClient(
        () => report(AttachmentReadException('private-document.docx',
            'PRIVATE path and message', trace.toJson())),
        () => MockClient((request) async {
              expect(request.url.path, '/api/attachment-read-failures');
              expect(request.headers['Authorization'], 'Bearer fixture');
              expect(jsonDecode(request.body), {
                'origin': 'clipboard',
                'batchSize': 2,
                'index': 1,
                'events': [
                  {'stage': 'snapshot', 'code': 'NotReadableError'}
                ],
                'extension': 'docx',
                'fileSize': 123,
              });
              expect(request.body, isNot(contains('private-document')));
              expect(request.body, isNot(contains('PRIVATE')));
              return http.Response('', 202);
            }));
  });

  test('network failure does not escape and non-clipboard errors are not sent',
      () async {
    await http.runWithClient(() async {
      await report(const AttachmentReadException('file.docx'));
    }, () => MockClient((_) async => fail('Must not send')));
    await http.runWithClient(
        () =>
            report(AttachmentReadException('file.docx', null, trace.toJson())),
        () => MockClient((_) async => throw http.ClientException('offline')));
  });
}
