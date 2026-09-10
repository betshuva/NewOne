import 'dart:convert';

import 'package:betshuva/guide_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _api = 'https://betshuva.com/betshuva-app/api';
const _id = 'c2a8d3d5-d7dc-457b-b80f-a95fa2117478';
const _path = '/betshuva-app/api/guide-files/$_id/download';

Map<String, dynamic> _metadata({String? downloadUrl}) => {
      'id': _id,
      'fileUrl': _path,
      'fileName': 'חברי הקבוצה.xlsx',
      'fileType': 'document',
      'fileSize': 4200,
      'downloadUrl': downloadUrl ?? '$_path?ticket=signed-download',
      'backupStatus': 'verified',
    };

http.Response _json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test('recognizes only this app’s persistent guide download paths', () {
    expect(guideFileIdFromUrl(_path, _api), _id);
    expect(guideFileIdFromUrl('https://betshuva.com$_path', _api), _id);
    expect(guideFileIdFromUrl('$_path?ticket=old', _api), _id);
    for (final value in [
      'https://other.example$_path',
      'http://betshuva.com$_path',
      'https://betshuva.com:444$_path',
      'https://user:secret@betshuva.com$_path',
      '//other.example$_path',
      'javascript:alert(1)',
      '$_path#fragment',
      '$_path/extra',
      '/betshuva-app/uploads/ordinary.xlsx',
      '/betshuva-app/api/guide-files/not-a-uuid/download',
    ]) {
      expect(guideFileIdFromUrl(value, _api), isNull, reason: value);
    }
    expect(guideFileIdFromUrl(_path, '/relative-api'), isNull);
  });

  test('file lookup authenticates the account and preserves a Hebrew filename',
      () async {
    final client = MockClient((request) async {
      expect(request.url.toString(), '$_api/guide-files/$_id');
      expect(request.headers['Authorization'], 'Bearer current-account-token');
      expect(request.url.query, isEmpty);
      return _json(_metadata());
    });
    final file = await loadGuideFile(
        api: _api, token: 'current-account-token', id: _id, client: client);
    expect(file.fileName, 'חברי הקבוצה.xlsx');
    expect(file.fileUrl, _path);
    expect(file.downloadUrl.toString(),
        'https://betshuva.com$_path?ticket=signed-download');
    expect(
        file.downloadUrl.toString(), isNot(contains('current-account-token')));
  });

  test('reopening a saved link obtains a fresh signed URL each time', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return _json(_metadata(downloadUrl: '$_path?ticket=$calls'));
    });
    final first =
        await loadGuideFile(api: _api, token: 'token', id: _id, client: client);
    final second =
        await loadGuideFile(api: _api, token: 'token', id: _id, client: client);
    expect(first.downloadUrl.queryParameters['ticket'], '1');
    expect(second.downloadUrl.queryParameters['ticket'], '2');
    expect(calls, 2);
  });

  test('a missing or unauthorized file cannot supply a download URL', () async {
    for (final status in [401, 403, 404, 503]) {
      await expectLater(
          loadGuideFile(
              api: _api,
              token: 'token',
              id: _id,
              client: MockClient((request) async => http.Response('', status))),
          throwsFormatException);
    }
  });

  test('metadata cannot redirect a download outside this account file path',
      () async {
    for (final download in [
      'https://attacker.example/export.xlsx',
      '//attacker.example/export.xlsx',
      'javascript:alert(1)',
      '/betshuva-app/api/guide-files/'
          'aaaa0000-0000-0000-0000-000000000000/download?ticket=other',
      '/betshuva-app/api/admin/export',
      'https://secret@betshuva.com$_path',
    ]) {
      await expectLater(
          loadGuideFile(
              api: _api,
              token: 'token',
              id: _id,
              client: MockClient(
                  (request) async => _json(_metadata(downloadUrl: download)))),
          throwsFormatException,
          reason: download);
    }
  });

  test('invalid metadata and unknown IDs fail before file opening', () async {
    for (final metadata in [
      {},
      {..._metadata(), 'fileUrl': '/betshuva-app/uploads/public.xlsx'},
      {..._metadata(), 'fileType': 'image'},
      {..._metadata(), 'fileName': ''},
      {..._metadata(), 'downloadUrl': null},
    ]) {
      await expectLater(
          loadGuideFile(
              api: _api,
              token: 'token',
              id: _id,
              client: MockClient((request) async => _json(metadata))),
          throwsFormatException);
    }
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return _json(_metadata());
    });
    await expectLater(
        loadGuideFile(api: _api, token: '', id: _id, client: client),
        throwsFormatException);
    await expectLater(
        loadGuideFile(
            api: _api, token: 'token', id: '../other', client: client),
        throwsFormatException);
    expect(calls, 0);
  });
}
