import 'dart:async';
import 'dart:convert';

import 'package:betshuva/listing_background_images.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as video;

const _listingId = '11111111-1111-4111-8111-111111111111';
const _foreignId = '22222222-2222-4222-8222-222222222222';
const _cover = 'https://detail-images.test/cover.png';
const _first = 'https://detail-images.test/first.png';
const _second = 'https://detail-images.test/second.png';
const _foreign = 'https://detail-images.test/foreign.png';
const _title = 'מודעת הבדיקה המעודכנת';
const _city = 'רחובות';
const _backgroundVideo = 'https://detail-images.test/background.mp4';
const _replacementVideo = 'https://detail-images.test/replacement.mp4';

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');

class _Server {
  final writes = <http.Request>[];
  final images = <String, List<String>>{};
  final videos = <String, String?>{};

  Future<http.Response> respond(http.Request request) async {
    final match =
        RegExp(r'/listings/([^/]+)/images$').firstMatch(request.url.path);
    if (request.method == 'POST' && match != null) {
      writes.add(request);
      final listing = match.group(1)!;
      final current = images.putIfAbsent(listing, () => [_cover]);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      for (final url in (body['image_urls'] as List).cast<String>()) {
        if (!current.contains(url)) current.add(url);
      }
      if (body.containsKey('video_url')) {
        videos[listing] = body['video_url'] as String?;
      }
      return http.Response(
        jsonEncode({
          'ok': true,
          'images': current,
          'image_url': current.first,
          if (videos.containsKey(listing)) 'video_url': videos[listing],
          // Image delivery must never replace the detail's current metadata.
          'title': 'כותרת שאינה שייכת למסך',
          'city': 'עיר שאינה שייכת למסך',
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (request.url.path.endsWith('.png')) {
      return http.Response.bytes(_png, 200,
          headers: {'content-type': 'image/png'});
    }
    return http.Response('{}', 200);
  }
}

class _VideoProbe extends video.VideoPlayerPlatform {
  int _nextId = 0;
  final sources = <String>[];
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(video.VideoCreationOptions options) async {
    sources.add(options.dataSource.uri!);
    return ++_nextId;
  }

  @override
  Stream<video.VideoEvent> videoEventsFor(int id) =>
      Stream.value(video.VideoEvent(
          eventType: video.VideoEventType.initialized,
          duration: const Duration(seconds: 9),
          size: const Size(100, 100)));
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

void _prepare(WidgetTester tester, String token) {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() {
    for (final job in listingBackgroundImages.forToken(token).toList()) {
      listingBackgroundImages.dismiss(job);
    }
  });
}

Widget _detail(String token, {Map<String, dynamic>? item}) => MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: ListingDetailScreen(
          token: token,
          socket: null,
          me: const {'id': 'detail-owner'},
          item: item ??
              const {
                'id': _listingId,
                'title': _title,
                'description': 'הפרטים שכבר נשמרו במודעה',
                'type': 'sale',
                'price': 100.0,
                'city': _city,
                'seller_id': 'detail-owner',
                'seller_name': 'בעל המודעה',
                'status': 'active',
                'images': [_cover],
              },
        ),
      ),
    );

List<String> _galleryUrls(WidgetTester tester) => tester
    .widgetList(find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_PersistentMediaImage'))
    .map((widget) => (widget as dynamic).url as String)
    .toList();

List<String> _videoUrls(WidgetTester tester) => tester
    .widgetList(find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_ChatVideoPlayer'))
    .map((widget) => (widget as dynamic).url as String)
    .toList();

ListingBackgroundImageJob _start(
    String token, Completer<ListingImageAttachment?> upload,
    {String listingId = _listingId}) {
  listingBackgroundImages.start(
    api: kApi,
    token: token,
    listingId: listingId,
    title: _title,
    uploads: [upload.future],
  );
  return listingBackgroundImages.forToken(token).last;
}

Future<void> _finish(WidgetTester tester, ListingBackgroundImageJob job) async {
  for (var i = 0; i < 80 && !job.isFinished; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(job.isFinished, isTrue, reason: job.error);
  await job.completion;
  await tester.pump();
}

void _expectMetadata() {
  expect(find.text(_title), findsNWidgets(2));
  expect(find.text(_city), findsOneWidget);
  expect(find.text('כותרת שאינה שייכת למסך'), findsNothing);
  expect(find.text('עיר שאינה שייכת למסך'), findsNothing);
}

void main() {
  for (final freshVideo in [null, _replacementVideo]) {
    testWidgets(
        'fresh same listing ${freshVideo == null ? 'removal' : 'replacement'} '
        'wins over prior background video after an unrelated job finishes',
        (tester) async {
      final token =
          'detail-video-fresh-${freshVideo == null ? 'remove' : 'replace'}';
      _prepare(tester, token);
      final previousVideo = video.VideoPlayerPlatform.instance;
      final probe = _VideoProbe();
      video.VideoPlayerPlatform.instance = probe;
      addTearDown(() => video.VideoPlayerPlatform.instance = previousVideo);
      final server = _Server();
      final original = <String, dynamic>{
        'id': _listingId,
        'title': _title,
        'description': 'הפרטים שכבר נשמרו במודעה',
        'type': 'sale',
        'price': 100.0,
        'city': _city,
        'seller_id': 'detail-owner',
        'seller_name': 'בעל המודעה',
        'status': 'active',
        'images': [_cover],
        'video_url': null,
      };
      await http.runWithClient(() async {
        await tester.pumpWidget(_detail(token, item: original));
        expect(_videoUrls(tester), isEmpty);
        final upload = Completer<ListingImageAttachment?>();
        final job = _start(token, upload);
        upload.complete(
            const ListingImageAttachment(url: _backgroundVideo, video: true));
        await _finish(tester, job);
        await tester.pumpAndSettle();
        expect(_videoUrls(tester), [_backgroundVideo]);
        expect(probe.sources, [_backgroundVideo]);
        expect(_galleryUrls(tester), [_cover]);
        _expectMetadata();

        // A successful edit returns authoritative data for this same listing.
        // Removing the video keeps its original null value, but must clear the
        // background result that has since been displayed in this State.
        server.videos[_listingId] = freshVideo;
        final refreshed = <String, dynamic>{
          ...original,
          'video_url': freshVideo
        };
        await tester.pumpWidget(_detail(token, item: refreshed));
        await tester.pumpAndSettle();
        expect(_videoUrls(tester), freshVideo == null ? isEmpty : [freshVideo]);
        expect(_galleryUrls(tester), [_cover]);
        _expectMetadata();
        expect(listingBackgroundImages.forToken(token), contains(job));

        final unrelatedUpload = Completer<ListingImageAttachment?>();
        final unrelatedJob =
            _start(token, unrelatedUpload, listingId: _foreignId);
        unrelatedUpload.complete(const ListingImageAttachment(url: _foreign));
        await _finish(tester, unrelatedJob);
        await tester.pumpAndSettle();
        expect(
            unrelatedJob.attachedRevision, greaterThan(job.attachedRevision));
        expect(_videoUrls(tester), freshVideo == null ? isEmpty : [freshVideo],
            reason:
                'An old receipt must not restore a removed or replaced video');
        expect(
            probe.sources,
            freshVideo == null
                ? [_backgroundVideo]
                : [_backgroundVideo, freshVideo]);
        expect(_galleryUrls(tester), [_cover]);
        _expectMetadata();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }, () => MockClient(server.respond));
    });
  }

  testWidgets(
      'open listing updates its gallery after background attachment and '
      'keeps it after the finished job is dismissed', (tester) async {
    const token = 'detail-gallery-live-token';
    _prepare(tester, token);
    final server = _Server();
    await http.runWithClient(() async {
      await tester.pumpWidget(_detail(token));
      expect(_galleryUrls(tester), [_cover]);
      _expectMetadata();

      final upload = Completer<ListingImageAttachment?>();
      final job = _start(token, upload);
      await tester.pump();
      expect(_galleryUrls(tester), [_cover]);
      expect(server.writes, isEmpty);

      upload.complete(const ListingImageAttachment(url: _first));
      await _finish(tester, job);
      expect(server.writes, hasLength(1));
      expect(server.writes.single.headers['Authorization'], 'Bearer $token');
      final body =
          jsonDecode(server.writes.single.body) as Map<String, dynamic>;
      expect(body.keys, isNot(contains('title')));
      expect(body.keys, isNot(contains('city')));
      expect(_galleryUrls(tester), [_cover, _first]);
      expect(find.byType(GridView), findsOneWidget);
      _expectMetadata();

      listingBackgroundImages.dismiss(job);
      await tester.pump();
      expect(_galleryUrls(tester), [_cover, _first]);
      _expectMetadata();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, () => MockClient(server.respond));
  });

  testWidgets(
      'foreign listing and foreign account jobs cannot replace the '
      'open listing gallery', (tester) async {
    const token = 'detail-gallery-isolation-token';
    const foreignToken = 'detail-gallery-other-account-token';
    _prepare(tester, token);
    addTearDown(() {
      for (final job
          in listingBackgroundImages.forToken(foreignToken).toList()) {
        listingBackgroundImages.dismiss(job);
      }
    });
    final server = _Server();
    await http.runWithClient(() async {
      await tester.pumpWidget(_detail(token));
      final foreignListingUpload = Completer<ListingImageAttachment?>();
      final foreignListingJob =
          _start(token, foreignListingUpload, listingId: _foreignId);
      foreignListingUpload
          .complete(const ListingImageAttachment(url: _foreign));
      await _finish(tester, foreignListingJob);
      expect(_galleryUrls(tester), [_cover]);

      final foreignAccountUpload = Completer<ListingImageAttachment?>();
      final foreignAccountJob = _start(foreignToken, foreignAccountUpload);
      foreignAccountUpload
          .complete(const ListingImageAttachment(url: _foreign));
      await _finish(tester, foreignAccountJob);
      expect(_galleryUrls(tester), [_cover]);
      _expectMetadata();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, () => MockClient(server.respond));
  });

  testWidgets(
      'out-of-order background jobs use the latest attachment response '
      'rather than the last-created job', (tester) async {
    const token = 'detail-gallery-completion-order-token';
    _prepare(tester, token);
    final server = _Server();
    await http.runWithClient(() async {
      await tester.pumpWidget(_detail(token));
      final olderUpload = Completer<ListingImageAttachment?>();
      final olderJob = _start(token, olderUpload);
      final newerUpload = Completer<ListingImageAttachment?>();
      final newerJob = _start(token, newerUpload);

      newerUpload.complete(const ListingImageAttachment(url: _second));
      await _finish(tester, newerJob);
      expect(_galleryUrls(tester), [_cover, _second]);

      olderUpload.complete(const ListingImageAttachment(url: _first));
      await _finish(tester, olderJob);
      expect(olderJob.attachedRevision, greaterThan(newerJob.attachedRevision));
      expect(_galleryUrls(tester), [_cover, _second, _first]);
      _expectMetadata();

      listingBackgroundImages.dismiss(olderJob);
      await tester.pump();
      expect(_galleryUrls(tester), [_cover, _second, _first]);
      listingBackgroundImages.dismiss(newerJob);
      await tester.pump();
      expect(_galleryUrls(tester), [_cover, _second, _first]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, () => MockClient(server.respond));
  });
}
