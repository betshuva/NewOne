import 'dart:async';
import 'dart:convert';

import 'package:betshuva/listing_background_images.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/listing_upload_browser.dart';

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');
const _messageId = '33333333-3333-4333-8333-333333333333';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

class _Server {
  _Server(this.token,
      {this.sourceId = _messageId,
      this.imageCount = 0,
      this.scanRejected = false});

  final String token;
  final String sourceId;
  final requests = <http.Request>[];
  final int imageCount;
  final bool scanRejected;
  final browser = ListingUploadBrowser();
  final sourceGate = Completer<http.Response>();
  final uploadGate = Completer<void>();
  final sourceRequests = <http.Request>[];
  final _nativeUploads = <http.Request>[];
  List<http.Request> get uploads => kIsWeb ? browser.requests : _nativeUploads;
  final listingWrites = <http.Request>[];
  final imageWrites = <http.Request>[];
  final scanRequests = <http.Request>[];
  final listing = <String, dynamic>{
    'id': 'listing-original',
    'title': 'מודעה קיימת',
    'description': 'תיאור קיים שצריך להישמר',
    'category': 'אחר',
    'city': 'רחובות',
    'price': 50,
    'images': <String>[],
  };

  void install() {
    listing['images'] = [
      for (var index = 0; index < imageCount; index++)
        'https://example.test/existing-$index.png'
    ];
    browser.install();
  }

  String get uploadedName {
    final body = latin1.decode(uploads.single.bodyBytes);
    return RegExp(r'filename="([^"]+)"').firstMatch(body)!.group(1)!;
  }

  String get uploadedUrl => 'https://example.test/$uploadedName';

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
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
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer $token');
      scanRequests.add(request);
      final body = jsonDecode(request.body) as Map;
      expect(body, {
        'image_urls': [uploadedUrl]
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
          }
        ]
      });
    }
    if (path.endsWith('/listings/listing-original/images') ||
        path.endsWith('/listings/listing-created/images')) {
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer $token');
      imageWrites.add(request);
      final body = jsonDecode(request.body) as Map;
      expect(body.keys, isNot(contains('title')));
      expect(body.keys, isNot(contains('description')));
      expect(body.keys, isNot(contains('city')));
      for (final url in body['image_urls'] as List) {
        if (!(listing['images'] as List).contains(url)) {
          (listing['images'] as List).add(url);
        }
      }
      return _json({'images': listing['images']});
    }
    if (request.method == 'POST' && path.endsWith('/listings') ||
        request.method == 'PUT' &&
            path.endsWith('/listings/listing-original')) {
      expect(request.headers['Authorization'], 'Bearer $token');
      listingWrites.add(request);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      listing.addAll(body);
      listing['images'] = List<String>.from(body['image_urls'] ?? const []);
      return _json({
        'id': request.method == 'POST' ? 'listing-created' : 'listing-original'
      });
    }
    if (request.method == 'GET' &&
        path.endsWith('/listings/listing-original')) {
      return _json(listing);
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
        ? _json({'error': 'התמונה אינה זמינה להעברה'}, 403)
        : http.Response.bytes(_png, 200, headers: {
            'content-type': 'image/png',
            'x-image-file-name': Uri.encodeComponent('conversation.png'),
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

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var index = 0; index < 250 && !done(); index++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue,
      reason: 'The conversation image operation did not finish');
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

Widget _app(Widget screen) => MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => screen),
              ),
              child: const Text('פתיחת מודעה'),
            ),
          ),
        );
      }),
    );

void _prepare(WidgetTester tester, _Server server) {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  server.install();
  addTearDown(server.dispose);
}

Widget _screen(_Server server, bool editing) => editing
    ? EditListingScreen(
        listingId: 'listing-original',
        token: server.token,
        initialMessageId: _messageId,
      )
    : PostListingScreen(
        token: server.token,
        me: const {'city': 'רחובות'},
        initialMessageId: _messageId,
      );

Future<void> _open(WidgetTester tester, _Server server, bool editing) async {
  await tester.pumpWidget(_app(_screen(server, editing)));
  await tester.tap(find.text('פתיחת מודעה'));
  await tester.pump(const Duration(milliseconds: 300));
  await _until(tester, () => server.sourceRequests.length == 1);
  // The HTTP boundary can be reached during the route's first frame. Complete
  // its entrance animation without waiting for the pending progress spinner.
  await tester.pump(const Duration(milliseconds: 400));
  if (!editing) {
    await tester.enterText(_field('כותרת המודעה *'), 'רכב מתמונה בשיחה');
    await tester.enterText(
        _field('תיאור מפורט *'), 'המודעה נשמרת לפני שהתמונה מוכנה');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final variant in [
    (group: false, request: false),
    (group: true, request: false),
    (group: false, request: true),
  ]) {
    final group = variant.group;
    final requestImage = variant.request;
    final sourceId = requestImage ? 'request_$_messageId' : _messageId;
    testWidgets(
        '${requestImage ? 'own approved pending-contact request' : group ? 'group' : 'private'} image menu opens listing chooser and cancels without copying',
        (tester) async {
      final server = _Server(
          'chat-menu-${requestImage ? 'request' : group ? 'group' : 'private'}',
          sourceId: sourceId);
      _prepare(tester, server);
      const allowed = {
        'text': true,
        'video': true,
        'nonHumanImages': true,
        'men': true,
        'women': true,
        'children': true,
      };
      const chatGroup = {
        'id': 'group',
        'name': 'קבוצה לבדיקה',
        'status': 'member',
        'role': 'member',
        'send_permission': 'all',
      };
      final message = {
        'id': sourceId,
        'sender_id': requestImage ? 'viewer' : 'friend',
        'recipient_id': requestImage ? 'friend' : 'viewer',
        'sender_name': 'חבר לבדיקה',
        if (group) 'group_id': 'group',
        'type': 'image',
        'body': 'תמונה מהשיחה לבדיקה',
        'file_url': 'https://example.test/conversation.png',
        'file_name': 'conversation.png',
        'created_at': '2026-10-07T00:00:00Z',
        'message_status': requestImage ? 'awaiting_contact_approval' : 'sent',
        if (requestImage) 'moderation_status': 'approved',
      };
      final originalMessage = jsonEncode(message);
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: group
                ? GroupChatScreen(
                    token: server.token,
                    socket: null,
                    me: const {'id': 'viewer', 'name': 'אני'},
                    group: chatGroup,
                    embedded: true,
                  )
                : ChatScreen(
                    token: server.token,
                    socket: null,
                    me: const {'id': 'viewer', 'name': 'אני'},
                    recipient: const {'id': 'friend', 'name': 'חבר לבדיקה'},
                    embedded: true,
                  ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 400));
        final caption = group
            ? find.byKey(const ValueKey('group-image-$_messageId'))
            : find.text('תמונה מהשיחה לבדיקה');
        await _until(tester, () => caption.evaluate().isNotEmpty);
        expect(caption, findsOneWidget);
        await tester.ensureVisible(caption);
        await tester.longPress(caption);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('הוסף למודעה'), findsOneWidget);
        await tester.tap(find.text('הוסף למודעה'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(const ValueKey('chat-listing-image-targets')),
            findsOneWidget);
        expect(find.text('מודעה חדשה'), findsOneWidget);
        await _until(
            tester, () => find.text('מודעה קיימת').evaluate().isNotEmpty);
        expect(find.text('מודעה קיימת'), findsOneWidget);
        expect(server.sourceRequests, isEmpty);
        await tester.tap(find.text('ביטול'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(PostListingScreen), findsNothing);
        expect(find.byType(EditListingScreen), findsNothing);
        expect(server.sourceRequests, isEmpty);
        expect(server.uploads, isEmpty);
        expect(server.listingWrites, isEmpty);

        await tester.longPress(caption);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('הוסף למודעה'));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const ValueKey('chat-listing-image-new')));
        await _until(tester, () => server.sourceRequests.length == 1);
        await tester.pump(const Duration(milliseconds: 400));
        final form =
            tester.widget<PostListingScreen>(find.byType(PostListingScreen));
        expect(form.initialMessageId, sourceId);
        expect(form.token, server.token);
        final state = tester.state(find.byType(PostListingScreen));
        Navigator.of(state.context).pop();
        await _until(tester, () => !state.mounted);
        server.completeSource();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
        expect(server.uploads, isEmpty);
        expect(server.listingWrites, isEmpty);
        expect(jsonEncode(message), originalMessage);
        expect(
            server.requests.where((request) =>
                request.method != 'GET' &&
                RegExp(r'/(contacts|contact-requests|message-requests|requests)(/|$)')
                    .hasMatch(request.url.path)),
            isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      },
          () => MockClient((request) async {
                final path = request.url.path;
                if (request.method == 'GET' &&
                    (path.endsWith('/messages/friend') ||
                        path.endsWith('/groups/group/messages'))) {
                  return _json([message]);
                }
                if (path.endsWith('/filter-settings')) {
                  return _json({
                    'filter': allowed,
                    'personalFilter': allowed,
                    'requiresChoice': false,
                  });
                }
                if (path.endsWith('/receiving-filter')) {
                  return _json({'filter': allowed});
                }
                if (path.endsWith('/groups/group')) {
                  return _json({...chatGroup, 'members': <Object>[]});
                }
                if (path.endsWith('/listings') &&
                    request.url.queryParameters['mine'] == 'true') {
                  return _json([server.listing]);
                }
                return server.respond(request);
              }));
    });
  }

  for (final editing in [false, true]) {
    testWidgets(
        'conversation image for ${editing ? 'existing' : 'new'} listing survives saving before source bytes and approval',
        (tester) async {
      final server = _Server('chat-import-${editing ? 'edit' : 'new'}',
          imageCount: editing ? 1 : 0);
      _prepare(tester, server);
      await http.runWithClient(() async {
        await _open(tester, server, editing);
        final state = tester.state(
            find.byType(editing ? EditListingScreen : PostListingScreen));
        expect(server.sourceGate.isCompleted, isFalse);
        expect(server.uploads, isEmpty);
        await _tapVisible(tester, find.text(editing ? 'שמור שינויים' : 'פרסם'));
        await _until(tester, () => !state.mounted);
        expect(server.listingWrites.length, 1);
        expect(server.imageWrites, isEmpty);
        expect(server.listing['images'], [
          if (editing) 'https://example.test/existing-0.png',
        ]);

        // The original route and account are gone while its captured operation
        // finishes. It must not borrow this new form's token or content.
        await tester.pumpWidget(const MaterialApp(
          home: PostListingScreen(
            key: ValueKey('other-account'),
            token: 'another-token',
            me: {'city': 'תל אביב'},
            embedded: true,
          ),
        ));
        await tester.pump();
        server.listing['title'] = 'כותרת שעודכנה אחרי השמירה';
        server.listing['city'] = 'חיפה';
        server.completeSource();
        await _until(tester, () => server.uploads.length == 1);
        expect(server.uploads.single.headers['Authorization'],
            'Bearer ${server.token}');
        expect(latin1.decode(server.uploads.single.bodyBytes),
            contains('name="listingImage"'));
        expect(server.imageWrites, isEmpty);
        server.completeUpload();
        await _until(tester, () => server.scanRequests.length == 1);
        expect(server.imageWrites, isEmpty,
            reason: 'A pending scan must never make the source image public');
        await tester.pump(const Duration(seconds: 15));
        await _until(tester, () => server.imageWrites.length == 1);
        expect(server.listing['images'], [
          if (editing) 'https://example.test/existing-0.png',
          server.uploadedUrl,
        ]);
        expect(server.listing['title'], 'כותרת שעודכנה אחרי השמירה');
        expect(server.listing['city'], 'חיפה');
        expect(server.sourceRequests.length, 1);
        expect(server.listingWrites.length, 1);
        expect(server.scanRequests.length, 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }, () => MockClient(server.respond));
    });
  }

  testWidgets('unavailable conversation source never uploads or attaches',
      (tester) async {
    final server = _Server('chat-import-unavailable');
    _prepare(tester, server);
    await http.runWithClient(() async {
      await _open(tester, server, false);
      final state = tester.state(find.byType(PostListingScreen));
      await _tapVisible(tester, find.text('פרסם'));
      await _until(tester, () => !state.mounted);
      server.completeSource(rejected: true);
      await _until(
          tester,
          () =>
              listingBackgroundImages.forToken(server.token).isNotEmpty &&
              !listingBackgroundImages.forToken(server.token).last.isActive);
      expect(server.uploads, isEmpty);
      expect(server.scanRequests, isEmpty);
      expect(server.imageWrites, isEmpty);
      expect(server.listing['images'], isEmpty);
      expect(server.listingWrites.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => MockClient(server.respond));
  });

  testWidgets('full listing does not fetch or replace conversation image',
      (tester) async {
    final server = _Server('chat-import-full', imageCount: 8);
    _prepare(tester, server);
    await http.runWithClient(() async {
      await tester.pumpWidget(_app(_screen(server, true)));
      await tester.tap(find.text('פתיחת מודעה'));
      await tester.pumpAndSettle();
      expect(server.sourceRequests, isEmpty);
      expect(server.uploads, isEmpty);
      expect(server.imageWrites, isEmpty);
      await _tapVisible(tester, find.text('שמור שינויים'));
      await _until(tester, () => server.listingWrites.length == 1);
      expect(server.listing['images'], [
        for (var index = 0; index < 8; index++)
          'https://example.test/existing-$index.png',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => MockClient(server.respond));
  });

  testWidgets('listing rejection leaves chat source out of the public listing',
      (tester) async {
    final server = _Server('chat-import-scan-rejected', scanRejected: true);
    _prepare(tester, server);
    await http.runWithClient(() async {
      await _open(tester, server, false);
      final state = tester.state(find.byType(PostListingScreen));
      await _tapVisible(tester, find.text('פרסם'));
      await _until(tester, () => !state.mounted);
      server.completeSource();
      await _until(tester, () => server.uploads.length == 1);
      server.completeUpload();
      await _until(
          tester,
          () =>
              listingBackgroundImages.forToken(server.token).isNotEmpty &&
              !listingBackgroundImages.forToken(server.token).last.isActive);
      expect(server.sourceRequests.length, 1);
      expect(server.scanRequests.length, 1);
      expect(server.imageWrites, isEmpty);
      expect(server.listing['images'], isEmpty);
      expect(server.listingWrites.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => MockClient(server.respond));
  });

  testWidgets('cancelling before chat bytes arrive does not upload or publish',
      (tester) async {
    final server = _Server('chat-import-cancelled');
    _prepare(tester, server);
    await http.runWithClient(() async {
      await _open(tester, server, false);
      final state = tester.state(find.byType(PostListingScreen));
      Navigator.of(state.context).pop();
      await _until(tester, () => !state.mounted);
      server.completeSource();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(server.sourceRequests.length, 1);
      expect(server.uploads, isEmpty);
      expect(server.listingWrites, isEmpty);
      expect(server.scanRequests, isEmpty);
      expect(server.imageWrites, isEmpty);
      expect(listingBackgroundImages.forToken(server.token), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => MockClient(server.respond));
  });
}
