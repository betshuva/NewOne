import 'package:flutter_test/flutter_test.dart';
import 'package:betshuva/incoming_share.dart';

void main() {
  test('one gallery selection preserves every photo in order', () {
    final messages = incomingShareMessages({
      'files': [
        {'path': '/cache/a', 'name': 'תמונה.jpg', 'mime': 'image/jpeg'},
        {'path': '/cache/b', 'name': 'תמונה נוספת.png', 'mime': 'image/png'},
      ],
    });
    expect(messages.map((m) => m['localPath']), ['/cache/a', '/cache/b']);
    expect(messages.map((m) => m['fileType']), ['image', 'image']);
    expect(messages.first['fileName'], 'תמונה.jpg');
  });

  test('mixed selection uses each provider MIME, not the overall share MIME',
      () {
    final messages = incomingShareMessages({
      'text': ' מצורפים הקבצים ',
      'mime': '*/*',
      'files': [
        {'path': '/cache/a', 'name': 'photo.jpg', 'mime': 'image/jpeg'},
        {'path': '/cache/b', 'name': 'movie', 'mime': 'video/mp4'},
        {'path': '/cache/c', 'name': 'report.pdf', 'mime': 'application/pdf'},
        {'path': '/cache/d', 'name': 'voice.m4a', 'mime': 'audio/mp4'},
        {
          'path': '/cache/e',
          'name': 'sheet.xlsx',
          'mime':
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        },
      ],
    });
    expect(messages.length, 6);
    expect(messages.first, {'text': 'מצורפים הקבצים'});
    expect(messages.skip(1).map((m) => m['fileType']),
        ['image', 'video', 'document', 'audio', 'document']);
    expect(messages[2]['mimeType'], 'video/mp4');
  });

  test('text-only shares work and unreadable entries do not create messages',
      () {
    expect(incomingShareMessages({'text': 'https://example.com'}), [
      {'text': 'https://example.com'}
    ]);
    expect(
        incomingShareMessages({
          'text': ' ',
          'files': [
            null,
            {},
            {'path': ''}
          ]
        }),
        isEmpty);
  });

  test('Direct Share cannot select a recipient from a different account', () {
    expect(incomingShareRecipient('alice:bob', 'alice'), 'bob');
    expect(incomingShareRecipient('alice:bob', 'carol'), isNull);
    expect(incomingShareRecipient('alice:bob', null), isNull);
    expect(incomingShareRecipient('alice:', 'alice'), isNull);
    expect(incomingShareRecipient(null, 'alice'), isNull);
  });
}
