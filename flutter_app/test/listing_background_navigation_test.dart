import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:betshuva/listing_video_draft.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as video;

import 'helpers/listing_upload_browser.dart';

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');

class _ImageFile extends XFile {
  _ImageFile(super.path) : super(mimeType: 'image/png');

  @override
  String get name => path;

  @override
  Future<Uint8List> readAsBytes() async => _png;

  @override
  Future<int> length() async => _png.length;
}

class _VideoFile extends XFile {
  _VideoFile(super.path) : super(mimeType: 'video/mp4');

  @override
  String get name => path;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList([0, 0, 0, 20]);

  @override
  Future<int> length() async => 4;
}

class _VideoProbe extends video.VideoPlayerPlatform {
  _VideoProbe({this.duration = const Duration(seconds: 10)});
  final Duration duration;
  var nextId = 0;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(video.VideoCreationOptions options) async =>
      ++nextId;
  @override
  Stream<video.VideoEvent> videoEventsFor(int id) {
    return Stream.value(video.VideoEvent(
        eventType: video.VideoEventType.initialized,
        duration: duration,
        size: const Size(100, 100)));
  }

  @override
  Future<void> dispose(int id) async {}
  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
      int id, bool prevents) async {}
  @override
  Future<void> setLooping(int id, bool looping) async {}
  @override
  Future<void> setVolume(int id, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int id, double speed) async {}
  @override
  Future<void> pause(int id) async {}
  @override
  Widget buildView(int id) => const SizedBox.shrink();
}

class _Picker extends ImagePickerPlatform {
  _Picker(this.batches, {this.videoFile});
  final List<List<XFile>> batches;
  XFile? videoFile;
  var selections = 0;
  var videoSelections = 0;

  @override
  Future<XFile?> getVideo({
    required ImageSource source,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    Duration? maxDuration,
  }) async {
    expect(source, ImageSource.gallery);
    videoSelections++;
    return videoFile;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async =>
      batches[selections++];
}

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

class _Server {
  _Server(this.listingId, Iterable<String> names,
      {this.pendingImages = const {}})
      : uploadGates = {for (final name in names) name: Completer<void>()};

  final String listingId;
  final Map<String, Completer<void>> uploadGates;
  final Set<String> pendingImages;
  final _nativeUploads = <http.Request>[];
  final browser = ListingUploadBrowser();
  List<http.Request> get uploads => kIsWeb ? browser.requests : _nativeUploads;
  final listingWrites = <http.Request>[];
  final imageWrites = <http.Request>[];
  final scanRequests = <http.Request>[];
  final listing = <String, dynamic>{
    'id': 'listing-original',
    'title': 'מודעה קיימת',
    'description': 'פרטי המודעה שנשמרו בעבר',
    'category': 'אחר',
    'price': 50,
    'city': 'רחובות',
    'images': <String>['https://example.test/existing.png'],
  };

  Future<http.Response> respond(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/upload')) {
      _nativeUploads.add(request);
      final body = latin1.decode(request.bodyBytes);
      final name = RegExp(r'filename="([^"]+)"').firstMatch(body)!.group(1)!;
      expect(
          body,
          contains(
              'name="${name.endsWith('.mp4') ? 'listingVideo' : 'listingImage'}"'));
      expect(request.headers['Authorization'], 'Bearer original-token');
      await uploadGates[name]!.future;
      return _json({
        'status': pendingImages.contains(name) ? 'pending' : 'approved',
        'url': 'https://example.test/$name'
      });
    }
    if (path.endsWith('/listing-image-status')) {
      scanRequests.add(request);
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer original-token');
      final body = jsonDecode(request.body) as Map;
      final videos = body.containsKey('video_urls');
      return _json({
        videos ? 'videos' : 'images': [
          for (final url in body[videos ? 'video_urls' : 'image_urls'] as List)
            {
              'url': url,
              'status': scanRequests.length == 1 ? 'pending' : 'approved'
            }
        ],
      });
    }
    if (path.endsWith('/listings/$listingId/images')) {
      imageWrites.add(request);
      expect(request.method, 'POST');
      expect(request.headers['Authorization'], 'Bearer original-token');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      // Completion must append images only. Replaying a stale form here would
      // overwrite edits saved after the publishing screen has been disposed.
      expect(body.keys, isNot(contains('title')));
      expect(body.keys, isNot(contains('description')));
      expect(body.keys, isNot(contains('city')));
      expect(body.keys, isNot(contains('category')));
      final images = (listing['images'] as List).cast<String>();
      for (final url in (body['image_urls'] as List).cast<String>()) {
        if (!images.contains(url)) images.add(url);
      }
      if (body.containsKey('video_url')) {
        expect(body.containsKey('expected_old_video_url'), isTrue);
        if (listing['video_url'] == body['expected_old_video_url']) {
          listing['video_url'] = body['video_url'];
        }
      }
      return _json({
        'id': listingId,
        'images': images,
        if (listing.containsKey('video_url')) 'video_url': listing['video_url'],
      });
    }
    if (request.method == 'POST' && path.endsWith('/listings') ||
        request.method == 'PUT' && path.endsWith('/listings/$listingId')) {
      listingWrites.add(request);
      expect(request.headers['Authorization'], 'Bearer original-token');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      listing.addAll(body);
      listing['images'] = List<String>.from(body['image_urls'] ?? const []);
      return _json({'id': listingId});
    }
    if (request.method == 'GET' && path.endsWith('/listings/$listingId')) {
      return _json(listing);
    }
    if (path.endsWith('.png')) {
      return http.Response.bytes(_png, 200,
          headers: {'content-type': 'image/png'});
    }
    if (path.endsWith('/listing-catalog.json')) return _json({});
    return _json([]);
  }

  void completeUploads() {
    for (final name in uploadGates.keys) {
      completeUpload(name);
    }
  }

  void completeUpload(String name) {
    final gate = uploadGates[name]!;
    if (!gate.isCompleted) gate.complete();
    browser.complete(name);
  }
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 250 && !done(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue, reason: 'The background operation did not finish');
}

Finder _field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label);

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
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

void _prepare(WidgetTester tester, _Picker picker) {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final originalPicker = ImagePickerPlatform.instance;
  ImagePickerPlatform.instance = picker;
  addTearDown(() => ImagePickerPlatform.instance = originalPicker);
}

void _installVideoProbe(_VideoProbe probe) {
  final previous = video.VideoPlayerPlatform.instance;
  video.VideoPlayerPlatform.instance = probe;
  addTearDown(() => video.VideoPlayerPlatform.instance = previous);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'shared gallery photos seed a draft and retain their sources through early publication',
      (tester) async {
    final names = [for (var i = 0; i < 8; i++) 'shared-$i.png'];
    final server = _Server('listing-created', names);
    final picker = _Picker([]);
    _prepare(tester, picker);
    server.browser.install();
    addTearDown(server.browser.dispose);
    addTearDown(server.completeUploads);
    var processed = false;
    await http.runWithClient(() async {
      await tester.pumpWidget(_app(PostListingScreen(
          token: 'original-token',
          me: const {'city': 'רחובות'},
          initialImages: [for (final name in names) _ImageFile(name)],
          onInitialImagesProcessed: () => processed = true)));
      await tester.tap(find.text('פתיחת מודעה'));
      await _until(tester, () => server.uploads.length == 2);
      await tester.pump(const Duration(seconds: 1));
      await _until(tester, () => _field('כותרת המודעה *').evaluate().isNotEmpty);
      await tester.enterText(_field('כותרת המודעה *'), 'רכב למכירה');
      await tester.enterText(
          _field('תיאור מפורט *'), 'תמונות ששותפו מהגלריה ונשמרות ברקע');
      await _tapVisible(tester, find.text('פרסם'));
      await _until(tester, () => server.listingWrites.length == 1);
      await _until(
          tester, () => find.byType(PostListingScreen).evaluate().isEmpty);
      expect(processed, isFalse,
          reason:
              'The native source queue cannot be acknowledged before all uploads read the photos');
      expect(picker.selections, 0);
      server.completeUploads();
      await _until(tester, () => processed && server.imageWrites.isNotEmpty);
      expect(server.uploads.length, 8);
      expect(jsonDecode(server.imageWrites.single.body)['image_urls'],
          [for (final name in names) 'https://example.test/$name']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => MockClient(server.respond));
  });

  for (final editing in [false, true]) {
    testWidgets(
        'saving ${editing ? 'existing' : 'new'} listing retains eight photo slots and one scanned video after navigation',
        (tester) async {
      final names = [
        for (var i = 0; i < (editing ? 7 : 8); i++) 'media-$i.png'
      ];
      const videoName = 'listing-video.mp4';
      const oldVideo = 'https://example.test/old-video.mp4';
      final server = _Server(editing ? 'listing-original' : 'listing-created',
          [...names, videoName],
          pendingImages: {videoName});
      if (editing) server.listing['video_url'] = oldVideo;
      final picker = _Picker([
        [for (final name in names) _ImageFile(name)]
      ], videoFile: _VideoFile(videoName));
      _prepare(tester, picker);
      final probe = _VideoProbe();
      _installVideoProbe(probe);
      server.browser.install();
      server.browser.markPending(videoName);
      addTearDown(server.browser.dispose);
      addTearDown(server.completeUploads);

      await http.runWithClient(() async {
        await tester.pumpWidget(_app(editing
            ? const EditListingScreen(
                listingId: 'listing-original', token: 'original-token')
            : const PostListingScreen(
                token: 'original-token', me: {'city': 'רחובות'})));
        await tester.tap(find.text('פתיחת מודעה'));
        await tester.pumpAndSettle();
        final originalState = tester.state(
            find.byType(editing ? EditListingScreen : PostListingScreen));
        if (!editing) {
          await tester.enterText(_field('כותרת המודעה *'), 'רכב למכירה');
          await tester.enterText(
              _field('תיאור מפורט *'), 'תיאור מלא שיישמר עם המודעה החדשה');
        }
        await _tapVisible(
            tester, find.text(editing ? 'הוסף תמונות' : 'בחירת תמונות'));
        await _until(tester, () => server.uploads.length == 2);
        await _tapVisible(
            tester, find.text(editing ? 'החלפת סרטון' : 'בחירת סרטון'));
        await _until(tester, () => server.uploads.length == 3);
        final videoButton = tester.widget<OutlinedButton>(find.widgetWithText(
            OutlinedButton, editing ? 'החלפת סרטון' : 'בחירת סרטון'));
        expect(videoButton.onPressed, isNull);
        expect(picker.videoSelections, 1);
        expect(server.imageWrites, isEmpty);

        await _tapVisible(tester, find.text(editing ? 'שמור שינויים' : 'פרסם'));
        await _until(tester, () => server.listingWrites.length == 1);
        await _until(tester, () => !originalState.mounted);
        final saved = jsonDecode(server.listingWrites.single.body) as Map;
        expect(saved.containsKey('video_url'), isFalse);
        expect(server.listing['video_url'], editing ? oldVideo : null);
        expect(server.imageWrites, isEmpty);

        await tester.pumpWidget(const MaterialApp(
          home: PostListingScreen(
            key: ValueKey('different-listing-video'),
            token: 'different-token',
            me: {'city': 'תל אביב'},
            embedded: true,
          ),
        ));
        await tester.pump();
        server.listing['title'] = 'שינוי מאוחר יותר';
        server.listing['city'] = 'חיפה';
        for (final name in names) {
          server.completeUpload(name);
        }
        await _until(tester, () => server.uploads.length == names.length + 1);
        expect(server.imageWrites, isEmpty,
            reason: 'Pending video must not become public before approval');
        server.completeUpload(videoName);
        await _until(tester, () => server.scanRequests.length == 1);
        expect(jsonDecode(server.scanRequests.single.body), {
          'video_urls': ['https://example.test/$videoName']
        });
        expect(server.imageWrites, isEmpty);
        await tester.pump(const Duration(seconds: 15));
        await _until(tester, () => server.imageWrites.isNotEmpty);
        final attached = jsonDecode(server.imageWrites.single.body) as Map;
        expect(attached['video_url'], 'https://example.test/$videoName');
        expect(attached['expected_old_video_url'], editing ? oldVideo : null);
        expect(attached.containsKey('expected_old_video_url'), isTrue);
        expect(attached['image_urls'],
            [for (final name in names) 'https://example.test/$name']);
        expect(server.listing['images'], [
          if (editing) 'https://example.test/existing.png',
          for (final name in names) 'https://example.test/$name'
        ]);
        expect((server.listing['images'] as List).length, 8);
        expect(server.listing['video_url'], 'https://example.test/$videoName');
        expect(server.listing['title'], 'שינוי מאוחר יותר');
        expect(server.listing['city'], 'חיפה');
        expect(server.listingWrites.length, 1);
        expect(server.scanRequests.length, 2);
        expect(picker.videoSelections, 1);
        expect(server.uploads.length, names.length + 1);
        if (kIsWeb) {
          final fields = (server.browser.records.singleWhere(
                  (record) => record['meta']['name'] == videoName)['meta']
              as Map)['fields'] as Map;
          expect(fields, {'listingVideo': 'true'});
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }, () => MockClient(server.respond));
    });
  }

  testWidgets('gallery video longer than ten seconds is not uploaded',
      (tester) async {
    final server = _Server('listing-created', ['long.mp4']);
    final picker = _Picker([], videoFile: _VideoFile('long.mp4'));
    _prepare(tester, picker);
    _installVideoProbe(
        _VideoProbe(duration: const Duration(milliseconds: 10001)));
    server.browser.install();
    addTearDown(server.browser.dispose);
    await http.runWithClient(() async {
      await tester.pumpWidget(_app(const PostListingScreen(
          token: 'original-token', me: {'city': 'רחובות'})));
      await tester.tap(find.text('פתיחת מודעה'));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('בחירת סרטון'));
      await _until(
          tester,
          () => find
              .text('ניתן לשלוח סרטון באורך של עד 10 שניות')
              .evaluate()
              .isNotEmpty);
      await _until(
          tester,
          () =>
              tester
                  .widget<OutlinedButton>(
                      find.widgetWithText(OutlinedButton, 'בחירת סרטון'))
                  .onPressed !=
              null);
      expect(
          find.text('ניתן לשלוח סרטון באורך של עד 10 שניות'), findsOneWidget);
      expect(server.uploads, isEmpty);
      expect(server.listingWrites, isEmpty);
      expect(picker.videoSelections, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => MockClient(server.respond));
  });

  for (final clearBeforePending in [false, true]) {
    testWidgets(
        'save commits the ${clearBeforePending ? 'removed' : 'approved replacement'} video before linking the next pending replacement',
        (tester) async {
      const oldVideo = 'https://example.test/original-video.mp4';
      const approvedName = 'first-video.mp4';
      const pendingName = 'next-video.mp4';
      const approvedVideo = 'https://example.test/$approvedName';
      const pendingVideo = 'https://example.test/$pendingName';
      final server = _Server('listing-original', [approvedName, pendingName]);
      server.listing['video_url'] = oldVideo;
      final picker = _Picker([], videoFile: _VideoFile(approvedName));
      _prepare(tester, picker);
      _installVideoProbe(_VideoProbe());
      server.browser.install();
      addTearDown(server.browser.dispose);
      addTearDown(server.completeUploads);
      await http.runWithClient(() async {
        await tester.pumpWidget(_app(const EditListingScreen(
            listingId: 'listing-original', token: 'original-token')));
        await tester.tap(find.text('פתיחת מודעה'));
        await tester.pumpAndSettle();
        final originalState = tester.state(find.byType(EditListingScreen));
        final draft = tester
            .widget<ListingVideoPicker>(find.byType(ListingVideoPicker))
            .draft;
        expect(draft.url, oldVideo);
        if (clearBeforePending) {
          await _tapVisible(tester, find.text('הסרת סרטון'));
          expect(draft.url, isNull);
        } else {
          await _tapVisible(tester, find.text('החלפת סרטון'));
          await _until(tester, () => server.uploads.length == 1);
          server.completeUpload(approvedName);
          await _until(tester, () => draft.url == approvedVideo);
        }
        expect(draft.changed, isTrue);
        picker.videoFile = _VideoFile(pendingName);
        await _tapVisible(tester,
            find.text(clearBeforePending ? 'בחירת סרטון' : 'החלפת סרטון'));
        await _until(tester,
            () => server.uploads.length == (clearBeforePending ? 1 : 2));
        expect(draft.pendingUpload, isNotNull);
        await _tapVisible(tester, find.text('שמור שינויים'));
        await _until(tester, () => !originalState.mounted);
        expect(server.listingWrites.length, 1);
        final saved = jsonDecode(server.listingWrites.single.body) as Map;
        final expectedOld = clearBeforePending ? null : approvedVideo;
        expect(saved.containsKey('video_url'), isTrue);
        expect(saved['video_url'], expectedOld);
        expect(server.listing['video_url'], expectedOld);
        expect(server.imageWrites, isEmpty);
        server.listing['title'] = 'כותרת ששונתה לאחר השמירה';
        server.completeUpload(pendingName);
        await _until(tester, () => server.imageWrites.isNotEmpty);
        final attached = jsonDecode(server.imageWrites.single.body) as Map;
        expect(attached['expected_old_video_url'], expectedOld);
        expect(attached['video_url'], pendingVideo);
        expect(server.listing['video_url'], pendingVideo);
        expect(server.listing['title'], 'כותרת ששונתה לאחר השמירה');
        expect(server.listingWrites.length, 1);
        expect(server.uploads.length, clearBeforePending ? 1 : 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }, () => MockClient(server.respond));
    });
  }

  for (final editing in [false, true]) {
    for (final partlyApproved in [false, true]) {
      testWidgets(
          'saving ${editing ? 'existing' : 'new'} listing keeps image uploads alive after navigation partlyApproved=$partlyApproved',
          (tester) async {
        // Only two workers start immediately. The third file exercises token
        // capture when its worker first runs after the original route is gone.
        const names = ['first.png', 'second.png', 'third.png'];
        final server =
            _Server(editing ? 'listing-original' : 'listing-created', names);
        final picker = _Picker([
          [for (final name in names) _ImageFile(name)],
        ]);
        _prepare(tester, picker);
        server.browser.install();
        addTearDown(server.browser.dispose);
        addTearDown(server.completeUploads);

        await http.runWithClient(() async {
          await tester.pumpWidget(_app(editing
              ? const EditListingScreen(
                  listingId: 'listing-original', token: 'original-token')
              : const PostListingScreen(
                  token: 'original-token', me: {'city': 'רחובות'})));
          await tester.tap(find.text('פתיחת מודעה'));
          await tester.pumpAndSettle();
          final originalState = tester.state(
              find.byType(editing ? EditListingScreen : PostListingScreen));

          if (!editing) {
            await tester.enterText(_field('כותרת המודעה *'), 'רכב למכירה');
            await tester.enterText(
                _field('תיאור מפורט *'), 'תיאור מלא שיישמר עם המודעה החדשה');
          }
          await _tapVisible(
              tester, find.text(editing ? 'הוסף תמונות' : 'בחירת תמונות'));
          await _until(tester, () => server.uploads.length == 2);
          expect(server.imageWrites, isEmpty);
          expect(server.uploadGates.values.every((gate) => !gate.isCompleted),
              isTrue);
          if (partlyApproved) {
            server.completeUpload(names.first);
            await _until(tester, () => server.uploads.length == 3);
          }

          await _tapVisible(
              tester, find.text(editing ? 'שמור שינויים' : 'פרסם'));
          await _until(tester, () => server.listingWrites.length == 1);
          await _until(tester, () => !originalState.mounted);
          expect(find.text('פתיחת מודעה'), findsOneWidget);
          expect(server.imageWrites, isEmpty);
          final saved = jsonDecode(server.listingWrites.single.body)
              as Map<String, dynamic>;
          expect(saved['title'], editing ? 'מודעה קיימת' : 'רכב למכירה');
          // A mixed completed/pending selection is delivered together in the
          // user's selection order rather than adding completed files twice.
          expect(saved['image_urls'] ?? const [], [
            if (editing) 'https://example.test/existing.png',
          ]);

          // A different account and a different form now occupy the UI. The
          // pending queue must retain its original token and target listing.
          await tester.pumpWidget(const MaterialApp(
            home: PostListingScreen(
              key: ValueKey('different-listing'),
              token: 'different-token',
              me: {'city': 'תל אביב'},
              embedded: true,
            ),
          ));
          await tester.pump();
          server.listing['title'] = 'שינוי מאוחר יותר';
          server.listing['city'] = 'חיפה';
          server.completeUploads();
          await _until(
              tester,
              () => names.every((name) => (server.listing['images'] as List)
                  .contains('https://example.test/$name')));
          expect(server.listingWrites.length, 1);
          expect(server.listing['title'], 'שינוי מאוחר יותר');
          expect(server.listing['city'], 'חיפה');
          expect(server.imageWrites, isNotEmpty);
          expect(server.uploads.length, 3);
          expect(
              server.uploads.every((request) =>
                  request.headers['Authorization'] == 'Bearer original-token'),
              isTrue);
          expect(server.listing['images'], [
            if (editing) 'https://example.test/existing.png',
            for (final name in names) 'https://example.test/$name',
          ]);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }, () => MockClient(server.respond));
      });
    }
  }

  testWidgets('additional selection reserves pending slots and caps at eight',
      (tester) async {
    final first = [for (var i = 0; i < 6; i++) 'first-$i.png'];
    final second = [for (var i = 0; i < 6; i++) 'second-$i.png'];
    final expected = [...first, ...second.take(2)];
    final server = _Server('listing-created', [...first, ...second]);
    final picker = _Picker([
      [for (final name in first) _ImageFile(name)],
      [for (final name in second) _ImageFile(name)],
    ]);
    _prepare(tester, picker);
    server.browser.install();
    addTearDown(server.browser.dispose);
    addTearDown(server.completeUploads);

    await http.runWithClient(() async {
      await tester.pumpWidget(_app(const PostListingScreen(
          token: 'original-token', me: {'city': 'רחובות'})));
      await tester.tap(find.text('פתיחת מודעה'));
      await tester.pumpAndSettle();
      final originalState = tester.state(find.byType(PostListingScreen));
      await tester.enterText(_field('כותרת המודעה *'), 'רכב למכירה');
      await tester.enterText(
          _field('תיאור מפורט *'), 'תיאור מלא שיישמר עם המודעה החדשה');
      await _tapVisible(tester, find.text('בחירת תמונות'));
      await _until(tester, () => server.uploads.length == 2);
      await _tapVisible(tester, find.text('הוסף תמונות'));
      await _until(tester, () => server.uploads.length == 4);
      expect(picker.selections, 2);
      expect(find.text('הוסף תמונות'), findsNothing);
      expect(find.text('ניתן לצרף עד 8 תמונות למודעה'), findsOneWidget);
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .removeCurrentSnackBar();
      await tester.pump();

      await _tapVisible(tester, find.text('פרסם'));
      await _until(tester, () => server.listingWrites.length == 1);
      await _until(tester, () => !originalState.mounted);
      expect(server.imageWrites, isEmpty);
      server.completeUploads();
      await _until(
          tester,
          () => expected.every((name) => (server.listing['images'] as List)
              .contains('https://example.test/$name')));
      expect(server.uploads.length, 8);
      expect((server.listing['images'] as List).toSet().length, 8);
      expect(server.listingWrites.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => MockClient(server.respond));
  });

  testWidgets('pending scan is approved and attached after the form closes',
      (tester) async {
    const name = 'pending-scan.png';
    final server = _Server('listing-created', [name], pendingImages: {name});
    final picker = _Picker([
      [_ImageFile(name)]
    ]);
    _prepare(tester, picker);
    server.browser.install();
    server.browser.markPending(name);
    addTearDown(server.browser.dispose);
    addTearDown(server.completeUploads);

    await http.runWithClient(() async {
      await tester.pumpWidget(_app(const PostListingScreen(
          token: 'original-token', me: {'city': 'רחובות'})));
      await tester.tap(find.text('פתיחת מודעה'));
      await tester.pumpAndSettle();
      final originalState = tester.state(find.byType(PostListingScreen));
      await tester.enterText(_field('כותרת המודעה *'), 'רכב למכירה');
      await tester.enterText(
          _field('תיאור מפורט *'), 'תיאור מלא שיישמר עם המודעה החדשה');
      await _tapVisible(tester, find.text('בחירת תמונות'));
      await _until(tester, () => server.uploads.length == 1);
      await _tapVisible(tester, find.text('פרסם'));
      await _until(tester, () => !originalState.mounted);
      expect(server.imageWrites, isEmpty);
      server.completeUploads();
      await _until(tester, () => server.scanRequests.length == 1);
      expect(server.imageWrites, isEmpty);
      expect(jsonDecode(server.scanRequests.single.body), {
        'image_urls': ['https://example.test/$name']
      });
      await tester.pump(const Duration(seconds: 15));
      await _until(tester, () => server.imageWrites.isNotEmpty);
      expect(server.scanRequests.length, 2);
      expect(server.listing['images'], ['https://example.test/$name']);
      expect(server.listingWrites.length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => MockClient(server.respond));
  });
}
