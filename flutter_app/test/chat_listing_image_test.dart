import 'dart:async';
import 'dart:convert';

import 'package:betshuva/chat_listing_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _id = '00000000-0000-4000-8000-000000000123';
const _image = <String, dynamic>{
  'id': _id,
  'fileType': 'image',
  'fileUrl': 'https://example.test/private-image.png',
  'status': 'sent',
};

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _openChooser(WidgetTester tester, http.Client client,
    void Function(ChatListingImageTarget?) onResult) async {
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: Builder(
    builder: (context) => TextButton(
      onPressed: () async => onResult(await showChatListingImageTargetChooser(
          context: context,
          api: 'https://example.test/api',
          token: 'actor-token',
          client: client)),
      child: const Text('open'),
    ),
  ))));
  await tester.tap(find.text('open'));
  await tester.pump();
}

void main() {
  test('only available, saved chat images expose the listing action', () {
    for (final status in ['sent', 'delivered', 'read']) {
      expect(canAddChatImageToListing({..._image, 'status': status}), isTrue);
    }
    for (final status in [
      'uploading',
      'pending_scan',
      'failed',
      'rejected_scan',
      'stopped_scan',
      'blocked_content',
      'awaiting_contact_approval'
    ]) {
      expect(
          canAddChatImageToListing(
              {..._image, 'status': status, 'forwardAllowed': true}),
          isFalse,
          reason: status);
    }
    for (final values in [
      {'id': 'temp_1'},
      {'id': null},
      {'fileType': 'video'},
      {'fileType': 'sticker'},
      {'fileUrl': ''},
      {'fileUrl': null},
      {'contentPurged': true},
      {'content_purged_at': '2026-10-07'},
      {'scanStopped': true},
      {'fileDeleted': true},
      {'filterHidden': true},
      {'isUploadBatchNotice': true},
      {'moderationStatus': 'pending'},
      {'moderationStatus': 'rejected'},
      {'deletedForEveryone': true},
      {'deleted_for_everyone': true},
      {'isDeleted': true},
    ]) {
      expect(canAddChatImageToListing({..._image, ...values}), isFalse,
          reason: values.toString());
    }
  });

  test('approved contact-request image is owner-only and keeps its namespace',
      () {
    const requestId = 'request_$_id';
    final request = {
      ..._image,
      'id': requestId,
      'from': 'actor',
      'status': 'awaiting_contact_approval',
      'moderationStatus': 'approved',
    };
    final before = jsonEncode(request);
    expect(canAddChatImageToListing(request, currentUserId: 'actor'), isTrue);
    expect(chatListingImageSourceId(request), requestId);
    expect(canAddChatImageToListing(request, currentUserId: 'other'), isFalse);
    expect(canAddChatImageToListing(request), isFalse);
    expect(canAddChatImageToListing(request, currentUserId: ''), isFalse);
    for (final senderKey in ['senderId', 'sender_id']) {
      final alias = {...request}..remove('from');
      alias[senderKey] = 'actor';
      expect(canAddChatImageToListing(alias, currentUserId: 'actor'), isTrue);
    }
    const upperUuid = 'ABCDEFAB-ABCD-4ABC-8ABC-ABCDEFABCDEF';
    expect(
        canAddChatImageToListing({...request, 'id': 'request_$upperUuid'},
            currentUserId: 'actor'),
        isTrue);
    expect(contactRequestListingImageSourceId(upperUuid), 'request_$upperUuid');
    expect(jsonEncode(request), before);
    // Existing saved-message access remains delegated to the server and does
    // not become restricted to the original sender.
    expect(
        canAddChatImageToListing({..._image, 'from': 'other'},
            currentUserId: 'actor'),
        isTrue);
    expect(chatListingImageSourceId(_image), _id);
  });

  test('request source requires approved bytes and a genuine request identity',
      () {
    final request = {
      ..._image,
      'id': 'request_$_id',
      'from': 'actor',
      'status': 'awaiting_contact_approval',
      'moderationStatus': 'approved',
    };
    for (final values in <Map<String, dynamic>>[
      {'id': _id}, // Arbitrary saved-message UUID awaiting contact approval.
      {'id': 'request_temp_1'},
      {'id': 'request_request_$_id'},
      {'id': 'REQUEST_$_id'},
      {'from': null},
      {'from': 'other'},
      {'status': 'sent'},
      {'status': 'pending_scan'},
      {'status': 'rejected_scan', 'forwardAllowed': true},
      {'moderationStatus': null},
      {'moderationStatus': 'pending'},
      {'moderationStatus': 'rejected'},
      {'fileType': 'video'},
      {'fileUrl': ''},
      {'fileDeleted': true},
      {'file_deleted': true},
      {'filterHidden': true},
      {'filter_hidden': true},
      {'contentPurged': true},
      {'content_purged_at': '2026-10-07'},
      {'scanStopped': true},
      {'deletedForEveryone': true},
      {'deleted_for_everyone': true},
      {'isDeleted': true},
      {'isUploadBatchNotice': true},
    ]) {
      expect(
          canAddChatImageToListing({...request, ...values},
              currentUserId: 'actor'),
          isFalse,
          reason: values.toString());
    }
  });

  test(
      'explicit pending-request ACK normalizes once without guessing message ids',
      () {
    expect(contactRequestListingImageSourceId(_id), 'request_$_id');
    expect(contactRequestListingImageSourceId('request_$_id'), 'request_$_id');
    for (final value in <Object?>[
      null,
      '',
      123,
      'temp_1',
      'request_temp',
      'request_request_$_id',
      'REQUEST_$_id',
      '../../other'
    ]) {
      expect(contactRequestListingImageSourceId(value), isNull,
          reason: value.toString());
    }
    // The ACK helper can deliberately create a source binding; the generic
    // message resolver must never infer that binding from an awaiting UUID.
    expect(
        chatListingImageSourceId(
            {..._image, 'status': 'awaiting_contact_approval'}),
        isNull);
  });

  test(
      'pending acknowledgement must bind the raw UUID to its exact request source',
      () {
    final ack = {
      ..._image,
      'from': 'actor',
      'status': 'awaiting_contact_approval',
      'moderationStatus': 'approved',
      'listingImageSourceId': 'request_$_id',
    };
    expect(canAddChatImageToListing(ack, currentUserId: 'actor'), isTrue);
    expect(chatListingImageSourceId(ack), 'request_$_id');
    for (final source in [
      _id,
      'request_00000000-0000-4000-8000-000000000456',
      'request_temp',
      '../../requests',
    ]) {
      expect(
          canAddChatImageToListing({...ack, 'listingImageSourceId': source},
              currentUserId: 'actor'),
          isFalse,
          reason: source);
    }
  });

  test('contact-request source fetch sends only namespaced identity and auth',
      () async {
    var count = 0;
    final bytes = utf8.encode('approved source from pending contact request');
    final client = MockClient((request) async {
      count++;
      expect(request.method, 'GET');
      expect(
          request.url.path, '/api/messages/request_$_id/listing-image-source');
      expect(request.headers['Authorization'], 'Bearer actor-token');
      expect(request.body, isEmpty);
      return http.Response.bytes(bytes, 200, headers: {
        'content-type': 'image/png',
        'x-image-file-name': Uri.encodeComponent('מקור.png'),
      });
    });
    final file = await loadChatListingImageSource(
        api: 'https://example.test/api',
        token: 'actor-token',
        messageId: 'request_$_id',
        client: client);
    expect(file.name, 'מקור.png');
    expect(await file.readAsBytes(), bytes);
    expect(count, 1);
  });

  test('source request uses message identity and actor auth; decodes filename',
      () async {
    final bytes = utf8.encode('approved source bytes');
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.toString(),
          'https://example.test/api/messages/$_id/listing-image-source');
      expect(request.headers['Authorization'], 'Bearer actor-token');
      expect(request.body, isEmpty);
      return http.Response.bytes(bytes, 200, headers: {
        'Content-Type': 'image/png; charset=binary',
        'X-Image-File-Name': Uri.encodeComponent('צילום מהשיחה.png'),
      });
    });
    final file = await loadChatListingImageSource(
        api: 'https://example.test/api',
        token: 'actor-token',
        messageId: _id,
        client: client);
    expect(file.name, 'צילום מהשיחה.png');
    expect(file.mimeType, 'image/png');
    expect(await file.readAsBytes(), bytes);
  });

  test('source filename is bounded to a safe image basename', () async {
    for (final name in ['../../a.png', r'C:\private\a.png', 'a\u0000.png']) {
      final file = await loadChatListingImageSource(
          api: 'https://example.test/api',
          token: 'actor-token',
          messageId: _id,
          client: MockClient((_) async => http.Response.bytes([1], 200,
              headers: {
                'content-type': 'image/png',
                'x-image-file-name': Uri.encodeComponent(name)
              })));
      expect(file.name, 'a.png');
    }
    for (final name in ['program.exe', '%invalid', '']) {
      final file = await loadChatListingImageSource(
          api: 'https://example.test/api',
          token: 'actor-token',
          messageId: _id,
          client: MockClient((_) async => http.Response.bytes([1], 200,
              headers: {
                'content-type': 'image/webp',
                'x-image-file-name': name
              })));
      expect(file.name, 'chat-image.webp');
    }
  });

  test('server access and moderation error is shown without uploading',
      () async {
    final client = MockClient((_) async =>
        _json({'error': 'התמונה אינה נגישה או שטרם אושרה בסריקה'}, 404));
    await expectLater(
        loadChatListingImageSource(
            api: 'https://example.test/api',
            token: 'actor-token',
            messageId: _id,
            client: client),
        throwsA(isA<ChatListingImageException>().having(
            (error) => error.message,
            'message',
            'התמונה אינה נגישה או שטרם אושרה בסריקה')));
  });

  test(
      'unsupported MIME, empty body and transport failure never become source files',
      () async {
    final responses = [
      http.Response.bytes([1], 200, headers: {'content-type': 'text/html'}),
      http.Response.bytes([1], 200, headers: {'content-type': 'video/mp4'}),
      http.Response.bytes([], 200, headers: {'content-type': 'image/png'}),
      http.Response('<html>error</html>', 503),
    ];
    for (final response in responses) {
      await expectLater(
          loadChatListingImageSource(
              api: 'https://example.test/api',
              token: 'actor-token',
              messageId: _id,
              client: MockClient((_) async => response)),
          throwsA(isA<ChatListingImageException>().having(
              (error) => error.message,
              'message',
              contains('לא ניתן לצרף את התמונה'))));
    }
    await expectLater(
        loadChatListingImageSource(
            api: 'https://example.test/api',
            token: 'actor-token',
            messageId: _id,
            client: MockClient((_) async => throw Exception('private-token'))),
        throwsA(isA<ChatListingImageException>().having(
            (error) => error.message,
            'message',
            isNot(contains('private-token')))));
  });

  test('invalid IDs do not request any path; a stalled source has a timeout',
      () async {
    var requests = 0;
    final gate = Completer<http.Response>();
    final client = MockClient((_) {
      requests++;
      return gate.future;
    });
    for (final id in [
      'temp_1',
      '../../other',
      '',
      'request_temp',
      'request_request_$_id',
      'REQUEST_$_id',
      'request_$_id/../../other',
      'request_'
    ]) {
      await expectLater(
          loadChatListingImageSource(
              api: 'https://example.test/api',
              token: 'actor-token',
              messageId: id,
              client: client),
          throwsA(isA<ChatListingImageException>()));
    }
    expect(requests, 0);
    await expectLater(
        loadChatListingImageSource(
            api: 'https://example.test/api',
            token: 'actor-token',
            messageId: _id,
            client: client,
            timeout: const Duration(milliseconds: 1)),
        throwsA(isA<ChatListingImageException>()));
    expect(requests, 1);
    gate.complete(
        http.Response.bytes([1], 200, headers: {'content-type': 'image/png'}));
  });

  testWidgets('new draft can be selected while existing listings are loading',
      (tester) async {
    final gate = Completer<http.Response>();
    ChatListingImageTarget? target;
    final client = MockClient((request) {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/listings');
      expect(request.url.queryParameters['mine'], 'true');
      expect(request.headers['Authorization'], 'Bearer actor-token');
      return gate.future;
    });
    await _openChooser(tester, client, (result) => target = result);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('chat-listing-image-new')));
    await tester.pumpAndSettle();
    expect(target?.isNewListing, isTrue);
    expect(
        find.byKey(const ValueKey('chat-listing-image-targets')), findsNothing);
    gate.complete(_json([]));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'existing target selection preserves full ads and cancel changes nothing',
      (tester) async {
    ChatListingImageTarget? target;
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.method, 'GET');
      expect(request.url.path, '/api/listings');
      return _json([
        {
          'id': 'full',
          'title': 'מודעה מלאה',
          'images': List<String>.filled(8, 'https://example.test/image.png')
        },
        {
          'id': 'mine',
          'title': 'מודעה שלי',
          'images': ['old-image']
        },
      ]);
    });
    await _openChooser(tester, client, (result) => target = result);
    await tester.pumpAndSettle();
    final full = tester.widget<ListTile>(
        find.byKey(const ValueKey('chat-listing-image-existing-full')));
    expect(full.enabled, isFalse);
    expect(full.onTap, isNull);
    await tester
        .tap(find.byKey(const ValueKey('chat-listing-image-existing-mine')));
    await tester.pumpAndSettle();
    expect(target?.listingId, 'mine');
    expect(target?.isNewListing, isFalse);
    target = null;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(target, isNull);
    expect(requests, 2);
    expect(
        find.byKey(const ValueKey('chat-listing-image-targets')), findsNothing);
  });

  testWidgets('listing load failure offers retry and retains new draft action',
      (tester) async {
    var requests = 0;
    final client = MockClient((request) async =>
        ++requests == 1 ? http.Response('unavailable', 503) : _json([]));
    await _openChooser(tester, client, (_) {});
    await tester.pumpAndSettle();
    expect(find.text('לא ניתן לטעון את המודעות שלך כרגע'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('chat-listing-image-new')), findsOneWidget);
    await tester.tap(find.text('נסה שוב'));
    await tester.pumpAndSettle();
    expect(find.text('אין לך מודעות קיימות'), findsOneWidget);
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'own listings pagination reaches later ads without duplicate rows',
      (tester) async {
    ChatListingImageTarget? target;
    final requestedPages = <String>[];
    final firstPage = [
      for (var index = 0; index < 20; index++)
        {'id': 'listing-$index', 'title': 'מודעה $index', 'images': <String>[]},
    ];
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.queryParameters['mine'], 'true');
      expect(request.headers['Authorization'], 'Bearer actor-token');
      final page = request.url.queryParameters['page']!;
      requestedPages.add(page);
      return _json(page == '1'
          ? firstPage
          : [
              firstPage.last,
              {'id': 'later', 'title': 'מודעה נוספת שלי', 'images': <String>[]},
            ]);
    });
    await _openChooser(tester, client, (result) => target = result);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('מודעות נוספות'), 250);
    await tester.tap(find.text('מודעות נוספות'));
    await tester.pumpAndSettle();
    expect(requestedPages, ['1', '2']);
    expect(find.byKey(const ValueKey('chat-listing-image-existing-listing-19')),
        findsOneWidget);
    final later =
        find.byKey(const ValueKey('chat-listing-image-existing-later'));
    await tester.ensureVisible(later);
    await tester.pumpAndSettle();
    await tester.tap(later);
    await tester.pumpAndSettle();
    expect(target?.listingId, 'later');
    expect(
        find.byKey(const ValueKey('chat-listing-image-targets')), findsNothing);
  });
}
