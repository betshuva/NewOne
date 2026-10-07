import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:betshuva/listing_background_images.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/listing_upload_browser.dart';

const _messageId = '44444444-4444-4444-8444-444444444444';
const _listingEntry = ValueKey('forward-listings-target');
const _chooser = ValueKey('chat-listing-image-targets');
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');

Map<String, dynamic> _image() => {
      'id': _messageId,
      'fileUrl': '/uploads/original-chat.png',
      'fileName': 'original-chat.png',
      'fileType': 'image',
      'status': 'sent',
      'moderationStatus': 'approved',
      'text': 'תיאור פרטי מתוך השיחה',
    };

http.Response _json(Object value, [int status = 200]) => http.Response(
      jsonEncode(value),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

class _Server {
  _Server(this.token,
      {this.sourceId = _messageId,
      this.imageCount = 1,
      this.previewFails = false,
      this.scanRejected = false,
      this.targetListsFail = false,
      this.contact = const {'id': 'bob', 'name': 'Bob'}});

  final String token;
  final String sourceId;
  final int imageCount;
  final bool previewFails;
  final bool scanRejected;
  final bool targetListsFail;
  final Map<String, dynamic> contact;
  final browser = ListingUploadBrowser();
  final sourceGate = Completer<http.Response>();
  final uploadGate = Completer<void>();
  final requests = <http.Request>[];
  final _nativeUploads = <http.Request>[];
  final sourceRequests = <http.Request>[];
  final listingWrites = <http.Request>[];
  final imageWrites = <http.Request>[];
  final scanRequests = <http.Request>[];
  final listing = <String, dynamic>{
    'id': 'my-listing',
    'title': 'מודעה קיימת שלי',
    'description': 'תיאור קיים שלא יוחלף בתיאור הפרטי מהשיחה',
    'category': 'אחר',
    'city': 'רחובות',
    'price': 50,
    'images': <String>[],
  };

  List<http.Request> get uploads => kIsWeb ? browser.requests : _nativeUploads;
  String get uploadedName => RegExp(r'filename="([^"]+)"')
      .firstMatch(latin1.decode(uploads.single.bodyBytes))!
      .group(1)!;
  String get uploadedUrl => 'https://example.test/$uploadedName';
  List<http.Request> get chatWrites => requests
      .where((r) =>
          r.method != 'GET' &&
          (r.url.path.endsWith('/messages') ||
              RegExp(r'/groups/[^/]+/messages$').hasMatch(r.url.path)))
      .toList();

  void install() {
    listing['images'] = [
      for (var i = 0; i < imageCount; i++)
        'https://example.test/existing-$i.png',
    ];
    browser.install();
  }

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (targetListsFail &&
        request.method == 'GET' &&
        (path.endsWith('/users') ||
            path.endsWith('/groups') ||
            path.endsWith('/users/directory'))) {
      return _json({}, 503);
    }
    if (path.endsWith('/forward/filter-preview')) {
      if (previewFails) return _json({}, 503);
      final payload = jsonDecode(request.body) as Map;
      expect(
          (payload['targets'] as List).every(
              (target) => const ['user', 'group'].contains(target['kind'])),
          isTrue);
      return _json({
        'targets': [
          for (final target in payload['targets'])
            {...target, 'status': 'allowed'},
        ],
      });
    }
    if (request.method == 'GET' && path.endsWith('/users')) {
      return _json([contact]);
    }
    if (request.method == 'GET' && path.endsWith('/groups')) {
      return _json([
        {'id': 'study', 'name': 'Study group'},
      ]);
    }
    if (path.endsWith('/messages/$sourceId/listing-image-source')) {
      expect(request.method, 'GET');
      expect(request.headers['Authorization'], 'Bearer $token');
      sourceRequests.add(request);
      return sourceGate.future;
    }
    if (path.endsWith('/upload')) {
      _nativeUploads.add(request);
      final body = latin1.decode(request.bodyBytes);
      expect(body, contains('name="listingImage"'));
      expect(body, isNot(contains('name="toUserId"')));
      expect(body, isNot(contains('name="groupId"')));
      expect(request.headers['Authorization'], 'Bearer $token');
      await uploadGate.future;
      return _json({'status': 'pending', 'url': uploadedUrl});
    }
    if (path.endsWith('/listing-image-status')) {
      scanRequests.add(request);
      expect(request.headers['Authorization'], 'Bearer $token');
      expect(jsonDecode(request.body), {
        'image_urls': [uploadedUrl],
      });
      return _json({
        'images': [
          {
            'url': uploadedUrl,
            'status': scanRejected
                ? 'rejected'
                : scanRequests.length == 1
                    ? 'pending'
                    : 'approved',
            if (scanRejected) 'reason': 'במודעות מותרות תמונות ללא אנשים בלבד',
          },
        ],
      });
    }
    if (path.endsWith('/listings/my-listing/images') ||
        path.endsWith('/listings/new-listing/images')) {
      imageWrites.add(request);
      final payload = jsonDecode(request.body) as Map;
      expect(payload.keys, isNot(contains('title')));
      expect(payload.keys, isNot(contains('description')));
      for (final url in payload['image_urls'] as List) {
        if (!(listing['images'] as List).contains(url)) {
          (listing['images'] as List).add(url);
        }
      }
      return _json({'images': listing['images']});
    }
    if (request.method == 'GET' && path.endsWith('/listings')) {
      expect(request.url.queryParameters['mine'], 'true');
      expect(request.headers['Authorization'], 'Bearer $token');
      return _json([listing]);
    }
    if (request.method == 'GET' && path.endsWith('/listings/my-listing')) {
      return _json(listing);
    }
    if ((request.method == 'POST' && path.endsWith('/listings')) ||
        (request.method == 'PUT' && path.endsWith('/listings/my-listing'))) {
      listingWrites.add(request);
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      listing.addAll(payload);
      listing['images'] = List<String>.from(payload['image_urls'] ?? const []);
      return _json({
        'id': request.method == 'POST' ? 'new-listing' : 'my-listing',
      });
    }
    if (request.method == 'POST' && path.endsWith('/messages')) {
      return _json({'id': 'forwarded'});
    }
    if (path.endsWith('.png')) {
      return http.Response.bytes(_png, 200,
          headers: {'content-type': 'image/png'});
    }
    if (path.endsWith('/listing-catalog.json')) return _json({});
    return _json([]);
  }

  void completeSource({bool rejected = false}) {
    if (sourceGate.isCompleted) return;
    sourceGate.complete(rejected
        ? _json({'error': 'המקור אינו זמין'}, 403)
        : http.Response.bytes(_png, 200, headers: {
            'content-type': 'image/png',
            'x-image-file-name': Uri.encodeComponent('original-chat.png'),
          }));
  }

  void completeUpload() {
    if (!uploadGate.isCompleted) uploadGate.complete();
    if (kIsWeb && uploads.isNotEmpty) {
      browser.markPending(uploadedName);
      browser.complete(uploadedName);
    }
  }

  void dispose() {
    completeSource(rejected: true);
    completeUpload();
    browser.dispose();
  }
}

void _prepare(WidgetTester tester, _Server server) {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  server.install();
  addTearDown(server.dispose);
}

Future<BuildContext> _mount(WidgetTester tester) async {
  late BuildContext screen;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: Builder(builder: (context) {
      screen = context;
      return const Text('המקור נשאר בשיחה');
    })),
  ));
  return screen;
}

Future<ForwardChatResult> _forward(BuildContext context, _Server server,
        List<Map<String, dynamic>> messages,
        {String? initialRecipientId, bool Function()? canForward}) =>
    forwardChatMessages(context, server.token, null, messages,
        me: const {'id': 'actor', 'city': 'רחובות'},
        initialRecipientId: initialRecipientId,
        canForward: canForward);

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 250 && !done(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue,
      reason: 'The forwarding/listing operation did not finish');
}

Finder _field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label);

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  for (final element in find.byType(ScaffoldMessenger).evaluate()) {
    ((element as StatefulElement).state as ScaffoldMessengerState)
        .removeCurrentSnackBar();
  }
  await tester.pump(const Duration(milliseconds: 200));
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(finder);
  await tester.pump();
}

void _expectNoCopies(_Server server) {
  expect(server.chatWrites, isEmpty);
  _expectNoContactActions(server);
  expect(server.sourceRequests, isEmpty);
  expect(server.uploads, isEmpty);
  expect(server.listingWrites, isEmpty);
  expect(server.imageWrites, isEmpty);
}

void _expectNoContactActions(_Server server) {
  expect(
      server.requests.where((request) =>
          request.method != 'GET' &&
          !request.url.path.endsWith('/forward/filter-preview') &&
          !request.url.path.endsWith('/upload') &&
          !request.url.path.endsWith('/listing-image-status') &&
          !RegExp(r'/listings(?:/[^/]+(?:/images)?)?$')
              .hasMatch(request.url.path)),
      isEmpty,
      reason:
          'Attaching own media cannot send a chat message or approve contacts');
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'eligible image has ads next to unchanged contact and group targets',
      (tester) async {
    final server = _Server('forward-listing-visible');
    _prepare(tester, server);
    await http.runWithClient(() async {
      final context = await _mount(tester);
      final result = _forward(context, server, [_image()]);
      await tester.pumpAndSettle();
      final tile = tester.widget<ListTile>(find.byKey(_listingEntry));
      expect(tile.enabled, isTrue);
      expect(tile.onTap, isNotNull);
      expect(find.text('מודעות'), findsOneWidget);
      expect(find.byKey(const ValueKey('forward-target-user:bob')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('forward-target-group:study')),
          findsOneWidget);
      _expectNoCopies(server);
      await tester.tap(find.byTooltip('ביטול העברה'));
      await tester.pumpAndSettle();
      expect((await result).cancelled, isTrue);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  for (final previewFails in [false, true]) {
    testWidgets(
        '${previewFails ? 'failed filter preview keeps' : 'selecting ads opens'} the listing chooser; cancel creates no copies',
        (tester) async {
      final server = _Server('forward-listing-cancel-$previewFails',
          previewFails: previewFails);
      _prepare(tester, server);
      await http.runWithClient(() async {
        final context = await _mount(tester);
        final original = _image();
        final originalJson = jsonEncode(original);
        final result = _forward(context, server, [original]);
        await tester.pumpAndSettle();
        if (previewFails) {
          expect(find.text('הסינון טרם נבדק'), findsWidgets);
        }
        // A prior contact selection must not leak a delivery when entering the
        // separate listing workflow.
        await tester.tap(find.byKey(const ValueKey('forward-target-user:bob')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(_listingEntry));
        await tester.pumpAndSettle();
        expect(find.byKey(_chooser), findsOneWidget);
        expect(find.text('מודעה חדשה'), findsOneWidget);
        expect(find.text('מודעה קיימת שלי'), findsOneWidget);
        expect(find.byKey(const ValueKey('forward-target-user:bob')),
            findsNothing);
        _expectNoCopies(server);
        await tester.tap(find.text('ביטול'));
        await tester.pumpAndSettle();
        final outcome = await result;
        expect(outcome.cancelled, isTrue);
        expect(outcome.completedMessageIndexes, isEmpty);
        expect(outcome.sentCount, 0);
        expect(outcome.totalDeliveries, 0);
        expect(jsonEncode(original), originalJson);
        _expectNoCopies(server);
        await _unmount(tester);
      }, () => MockClient(server.respond));
    });
  }

  for (final variant in [
    (editing: false, rejected: false, source: 'saved'),
    (editing: true, rejected: false, source: 'saved'),
    (editing: false, rejected: true, source: 'saved'),
    (editing: false, rejected: false, source: 'request'),
    (editing: true, rejected: false, source: 'request'),
    (editing: false, rejected: true, source: 'request'),
    (editing: false, rejected: false, source: 'request-ack'),
  ]) {
    final editing = variant.editing;
    testWidgets(
        '${variant.source} ads target opens real ${editing ? 'existing' : 'new'} editor and ${variant.rejected ? 'rejects an unsafe listing image' : 'rescans original bytes'} after early save',
        (tester) async {
      final server = _Server(
          'forward-listing-save-${variant.source}-$editing-${variant.rejected}',
          sourceId:
              variant.source == 'saved' ? _messageId : 'request_$_messageId',
          imageCount: editing ? 1 : 0,
          scanRejected: variant.rejected);
      _prepare(tester, server);
      await http.runWithClient(() async {
        final context = await _mount(tester);
        final original = {
          ..._image(),
          if (variant.source != 'saved') ...{
            'id': variant.source == 'request-ack'
                ? _messageId
                : 'request_$_messageId',
            'from': 'actor',
            'status': 'awaiting_contact_approval',
            if (variant.source == 'request-ack')
              'listingImageSourceId': 'request_$_messageId',
          },
        };
        final originalJson = jsonEncode(original);
        final result = _forward(context, server, [original]);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(_listingEntry));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(editing
            ? 'chat-listing-image-existing-my-listing'
            : 'chat-listing-image-new')));
        await tester.pump(const Duration(milliseconds: 400));
        await _until(tester, () => server.sourceRequests.length == 1);
        // The source request can start while the new route is still entering.
        await tester.pump(const Duration(milliseconds: 400));
        final editor = editing
            ? find.byType(EditListingScreen)
            : find.byType(PostListingScreen);
        expect(editor, findsOneWidget);
        final state = tester.state(editor);
        if (editing) {
          final screen = tester.widget<EditListingScreen>(editor);
          expect(screen.initialMessageId, server.sourceId);
          expect(screen.listingId, 'my-listing');
          expect(tester.widget<TextField>(_field('תיאור')).controller!.text,
              'תיאור קיים שלא יוחלף בתיאור הפרטי מהשיחה');
        } else {
          final screen = tester.widget<PostListingScreen>(editor);
          expect(screen.initialMessageId, server.sourceId);
          expect(
              tester
                  .widget<TextField>(_field('כותרת המודעה *'))
                  .controller!
                  .text,
              isEmpty);
          expect(
              tester
                  .widget<TextField>(_field('תיאור מפורט *'))
                  .controller!
                  .text,
              isEmpty);
          await tester.enterText(
              _field('כותרת המודעה *'), 'כותרת חדשה מהמשתמש');
          await tester.enterText(
              _field('תיאור מפורט *'), 'תיאור ציבורי שהמשתמש מילא');
        }
        expect(server.uploads, isEmpty);
        await _tapVisible(tester, find.text(editing ? 'שמור שינויים' : 'פרסם'));
        await _until(tester, () => !state.mounted);
        final outcome = await result;
        expect(outcome.cancelled, isFalse);
        expect(outcome.completedMessageIndexes, isEmpty);
        expect(outcome.sentCount, 0);
        expect(outcome.totalDeliveries, 0);
        expect(server.listingWrites.length, 1);
        expect(server.imageWrites, isEmpty);
        expect(server.listing['images'], [
          if (editing) 'https://example.test/existing-0.png',
        ]);
        server.completeSource();
        await _until(tester, () => server.uploads.length == 1);
        expect(latin1.decode(server.uploads.single.bodyBytes),
            contains('name="listingImage"'));
        expect(server.uploads.single.headers['Authorization'],
            'Bearer ${server.token}');
        if (kIsWeb) {
          expect(server.browser.chunks.single['bytes'], _png);
        } else {
          expect(latin1.decode(server.uploads.single.bodyBytes),
              contains(latin1.decode(_png)));
        }
        server.completeUpload();
        await _until(tester, () => server.scanRequests.length == 1);
        expect(server.imageWrites, isEmpty,
            reason: 'An already approved chat file still needs a listing scan');
        if (variant.rejected) {
          await _until(
              tester,
              () =>
                  listingBackgroundImages.forToken(server.token).isNotEmpty &&
                  !listingBackgroundImages
                      .forToken(server.token)
                      .last
                      .isActive);
          expect(server.scanRequests.length, 1);
          expect(server.imageWrites, isEmpty);
          expect(server.listing['images'], isEmpty);
        } else {
          await tester.pump(const Duration(seconds: 15));
          await _until(tester, () => server.imageWrites.length == 1);
          expect(server.scanRequests.length, 2);
          expect(server.listing['images'], [
            if (editing) 'https://example.test/existing-0.png',
            server.uploadedUrl,
          ]);
        }
        expect(server.chatWrites, isEmpty);
        _expectNoContactActions(server);
        expect(jsonEncode(original), originalJson);
        expect(server.listing['description'], isNot(original['text']));
        await _unmount(tester);
      }, () => MockClient(server.respond));
    });
  }

  testWidgets('cancel editor before source response never uploads or publishes',
      (tester) async {
    final server = _Server('forward-listing-editor-cancel');
    _prepare(tester, server);
    await http.runWithClient(() async {
      final context = await _mount(tester);
      final result = _forward(context, server, [_image()]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_listingEntry));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-listing-image-new')));
      await tester.pump(const Duration(milliseconds: 400));
      await _until(tester, () => server.sourceRequests.length == 1);
      await tester.pump(const Duration(milliseconds: 400));
      final state = tester.state(find.byType(PostListingScreen));
      Navigator.of(state.context).pop();
      await _until(tester, () => !state.mounted);
      expect((await result).cancelled, isTrue);
      server.completeSource();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(server.uploads, isEmpty);
      expect(server.chatWrites, isEmpty);
      expect(server.listingWrites, isEmpty);
      expect(server.imageWrites, isEmpty);
      expect(listingBackgroundImages.forToken(server.token), isEmpty);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets('existing listing with eight images stays disabled in forwarding',
      (tester) async {
    final server = _Server('forward-listing-full', imageCount: 8);
    _prepare(tester, server);
    await http.runWithClient(() async {
      final context = await _mount(tester);
      final result = _forward(context, server, [_image()]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_listingEntry));
      await tester.pumpAndSettle();
      final full =
          find.byKey(const ValueKey('chat-listing-image-existing-my-listing'));
      expect(tester.widget<ListTile>(full).enabled, isFalse);
      expect(tester.widget<ListTile>(full).onTap, isNull);
      expect(find.text('המודעה כבר כוללת 8 תמונות'), findsOneWidget);
      await tester.tap(full);
      await tester.pumpAndSettle();
      expect(find.byKey(_chooser), findsOneWidget);
      _expectNoCopies(server);
      await tester.tap(find.text('ביטול'));
      await tester.pumpAndSettle();
      expect((await result).cancelled, isTrue);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  final unsupported = <String, List<Map<String, dynamic>>>{
    'text': [
      {'text': 'a normal message'},
    ],
    'video': [
      {..._image(), 'fileType': 'video', 'fileUrl': '/uploads/video.mp4'},
    ],
    'local bytes': [
      {
        ..._image(),
        'localBytes': Uint8List.fromList([1, 2, 3])
      },
    ],
    'local path': [
      {..._image(), 'localPath': '/local/image.png'},
    ],
    'multiple images': [_image(), _image()],
    'unsupported source id': [
      {..._image(), 'id': 'local-only-id'},
    ],
    'foreign pending request': [
      {
        ..._image(),
        'id': 'request_$_messageId',
        'from': 'other',
        'status': 'awaiting_contact_approval'
      },
    ],
    'ownerless pending request': [
      {
        ..._image(),
        'id': 'request_$_messageId',
        'status': 'awaiting_contact_approval'
      },
    ],
    'raw UUID awaiting contact approval': [
      {..._image(), 'from': 'actor', 'status': 'awaiting_contact_approval'},
    ],
    'unapproved pending request': [
      {
        ..._image(),
        'id': 'request_$_messageId',
        'from': 'actor',
        'status': 'awaiting_contact_approval',
        'moderationStatus': 'pending'
      },
    ],
    'deleted pending request': [
      {
        ..._image(),
        'id': 'request_$_messageId',
        'from': 'actor',
        'status': 'awaiting_contact_approval',
        'fileDeleted': true
      },
    ],
    'hidden pending request': [
      {
        ..._image(),
        'id': 'request_$_messageId',
        'from': 'actor',
        'status': 'awaiting_contact_approval',
        'filterHidden': true
      },
    ],
    'hidden image': [
      {..._image(), 'filterHidden': true},
    ],
    'rejected image permitted for contact forwarding': [
      {..._image(), 'status': 'rejected_scan', 'forwardAllowed': true},
    ],
  };
  for (final entry in unsupported.entries) {
    testWidgets('${entry.key} cannot enter ads and has a clear explanation',
        (tester) async {
      final server = _Server('forward-listing-unsupported-${entry.key}');
      _prepare(tester, server);
      await http.runWithClient(() async {
        final context = await _mount(tester);
        final result = _forward(context, server, entry.value);
        await tester.pumpAndSettle();
        final tile = tester.widget<ListTile>(find.byKey(_listingEntry));
        expect(tile.enabled, isFalse);
        expect(tile.onTap, isNull);
        expect(tile.subtitle, isA<Text>());
        expect(
            (tile.subtitle as Text).data,
            entry.key == 'multiple images'
                ? 'בחר תמונה אחת מהשיחה כדי להוסיף למודעה'
                : const ['text', 'video'].contains(entry.key)
                    ? 'ניתן להוסיף למודעה תמונה מהשיחה'
                    : const ['local bytes', 'local path'].contains(entry.key)
                        ? 'אפשר להוסיף רק תמונה שכבר נשמרה בשיחה'
                        : const ['hidden image', 'hidden pending request']
                                .contains(entry.key)
                            ? 'התמונה מוסתרת לפי הסינון'
                            : entry.key == 'deleted pending request'
                                ? 'התמונה אינה זמינה עוד'
                                : entry.key == 'unapproved pending request'
                                    ? 'אפשר להוסיף לאחר השלמת הסריקה'
                                    : const [
                                        'foreign pending request',
                                        'ownerless pending request',
                                        'raw UUID awaiting contact approval'
                                      ].contains(entry.key)
                                        ? 'התמונה ממתינה לאישור חברות ואינה זמינה להוספה למודעה'
                                        : entry.key == 'unsupported source id'
                                            ? 'התמונה אינה מקושרת להודעה שמורה בשיחה'
                                            : 'התמונה לא אושרה בסריקה');
        await tester.tap(find.byKey(_listingEntry));
        await tester.pumpAndSettle();
        expect(find.byKey(_chooser), findsNothing);
        _expectNoCopies(server);
        await tester.tap(find.byTooltip('ביטול העברה'));
        await tester.pumpAndSettle();
        expect((await result).cancelled, isTrue);
        await _unmount(tester);
      }, () => MockClient(server.respond));
    });
  }

  for (final contact in <Map<String, dynamic>>[
    {'id': 'bob', 'name': 'Bob'},
    {'id': 'bob', 'name': null},
    {'id': 'bob'},
  ]) {
    testWidgets(
        'direct contact sharing with ${contact.containsKey('name') ? contact['name'] ?? 'null name' : 'missing name'} keeps scope without ads entry',
        (tester) async {
      final server = _Server(
          'forward-listing-direct-${contact.keys.length}-${contact['name']}',
          contact: contact);
      _prepare(tester, server);
      await http.runWithClient(() async {
        final context = await _mount(tester);
        final result =
            _forward(context, server, [_image()], initialRecipientId: 'bob');
        await tester.pumpAndSettle();
        if (contact['name'] != null) {
          expect(find.text('שליחה אל Bob'), findsOneWidget);
        }
        expect(find.byKey(_listingEntry), findsNothing);
        expect(find.byKey(const ValueKey('forward-target-group:study')),
            findsNothing);
        await tester.tap(find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
        await tester.pumpAndSettle();
        final outcome = await result;
        expect(outcome.sentCount, 1);
        expect(outcome.completedMessageIndexes, {0});
        expect(server.chatWrites.length, 1);
        expect(jsonDecode(server.chatWrites.single.body)['fileUrl'],
            '/uploads/original-chat.png');
        expect(server.sourceRequests, isEmpty);
        expect(server.uploads, isEmpty);
        expect(server.listingWrites, isEmpty);
        await _unmount(tester);
      }, () => MockClient(server.respond));
    });
  }

  testWidgets('ads remain available when contacts and groups could not load',
      (tester) async {
    final server =
        _Server('forward-listing-targets-failed', targetListsFail: true);
    _prepare(tester, server);
    await http.runWithClient(() async {
      final context = await _mount(tester);
      final result = _forward(context, server, [_image()]);
      await tester.pumpAndSettle();
      expect(
          tester.widget<ListTile>(find.byKey(_listingEntry)).onTap, isNotNull);
      await tester.enterText(
          find.byKey(const ValueKey('forward-target-search')),
          'no matching contact');
      await tester.pumpAndSettle();
      expect(find.byKey(_listingEntry), findsOneWidget);
      await tester.tap(find.byKey(_listingEntry));
      await tester.pumpAndSettle();
      expect(find.byKey(_chooser), findsOneWidget);
      await tester.tap(find.text('ביטול'));
      await tester.pumpAndSettle();
      expect((await result).cancelled, isTrue);
      _expectNoCopies(server);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  for (final status in ['pending_scan', 'rejected_scan']) {
    testWidgets('$status cannot bypass the existing safety guard through ads',
        (tester) async {
      final server = _Server('forward-listing-safety-$status');
      _prepare(tester, server);
      await http.runWithClient(() async {
        final context = await _mount(tester);
        final result = _forward(context, server, [
          {..._image(), 'status': status},
        ]);
        await tester.pumpAndSettle();
        final outcome = await result;
        expect(outcome.completedMessageIndexes, isEmpty);
        expect(find.byKey(_listingEntry), findsNothing);
        expect(find.textContaining('לא ניתן להעביר קובץ שנכשל בבדיקת הבטיחות'),
            findsOneWidget);
        expect(server.requests, isEmpty);
        _expectNoCopies(server);
        await _unmount(tester);
      }, () => MockClient(server.respond));
    });
  }

  testWidgets('a stale permission cannot enter the listing workflow',
      (tester) async {
    final server = _Server('forward-listing-stale-permission');
    _prepare(tester, server);
    await http.runWithClient(() async {
      var allowed = true;
      final context = await _mount(tester);
      final result =
          _forward(context, server, [_image()], canForward: () => allowed);
      await tester.pumpAndSettle();
      allowed = false;
      await tester.tap(find.byKey(_listingEntry));
      await tester.pumpAndSettle();
      expect((await result).cancelled, isTrue);
      expect(find.byKey(_chooser), findsNothing);
      _expectNoCopies(server);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets('permission is checked again after choosing an existing listing',
      (tester) async {
    final server = _Server('forward-listing-stale-after-chooser');
    _prepare(tester, server);
    await http.runWithClient(() async {
      var allowed = true;
      final context = await _mount(tester);
      final result =
          _forward(context, server, [_image()], canForward: () => allowed);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_listingEntry));
      await tester.pumpAndSettle();
      expect(find.byKey(_chooser), findsOneWidget);
      allowed = false;
      await tester.tap(
          find.byKey(const ValueKey('chat-listing-image-existing-my-listing')));
      await tester.pumpAndSettle();
      expect((await result).cancelled, isTrue);
      expect(find.byType(EditListingScreen), findsNothing);
      _expectNoCopies(server);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets(
      'selected contact and keyboard leave ads reachable on a small phone',
      (tester) async {
    final server = _Server('forward-listing-keyboard');
    _prepare(tester, server);
    tester.view.physicalSize = const Size(390, 650);
    addTearDown(tester.view.resetViewInsets);
    await http.runWithClient(() async {
      final context = await _mount(tester);
      final result = _forward(context, server, [_image()]);
      await tester.pumpAndSettle();
      final contact = find.byKey(const ValueKey('forward-target-user:bob'));
      await tester.ensureVisible(contact);
      await tester.tap(contact);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(contact).value, isTrue);
      // The count is now part of the scrollable middle, so return to its row
      // before checking it rather than treating offscreen lazy items as missing.
      await tester.scrollUntilVisible(find.text('1 פריטים • 1 יעדים'), -100,
          scrollable: find.byWidgetPredicate((widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down));
      await tester.pumpAndSettle();
      expect(find.text('1 פריטים • 1 יעדים'), findsOneWidget);
      expect(find.text('העבר ל־1 יעדים'), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason:
              'The added ads target must not overflow with an open keyboard');
      final search = find.byKey(const ValueKey('forward-target-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, 'no matching contact');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('forward-selected-user:bob')),
          findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(_listingEntry), -100,
          scrollable: find.byWidgetPredicate((widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_listingEntry));
      // Closing the sheet dismisses its keyboard on a real device.
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(find.byKey(_chooser), findsOneWidget);
      await tester.tap(find.text('ביטול'));
      await tester.pumpAndSettle();
      expect((await result).cancelled, isTrue);
      _expectNoCopies(server);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });
}
