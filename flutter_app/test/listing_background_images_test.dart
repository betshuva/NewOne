import 'dart:async';
import 'dart:convert';

import 'package:betshuva/listing_background_images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('video scan polls videos and ignores unrelated image approvals',
      () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.url.path, '/api/listing-image-status');
      expect(request.headers['authorization'], 'Bearer original-account');
      expect(jsonDecode(request.body), {
        'video_urls': ['/uploads/camera.mp4']
      });
      return http.Response(
          jsonEncode({
            'images': [
              {'url': '/uploads/camera.mp4', 'status': 'approved'}
            ],
            'videos': [
              {'url': '/uploads/other.mp4', 'status': 'approved'},
              {
                'url': '/uploads/camera.mp4',
                'status': requests == 1 ? 'pending' : 'approved'
              },
            ],
          }),
          200);
    });
    final result = await waitForListingImageScan(
      api: 'https://test/api',
      token: 'original-account',
      url: '/uploads/camera.mp4',
      video: true,
      client: client,
      pollInterval: Duration.zero,
    );
    expect(requests, 2);
    expect(result.status, 'approved');
  });

  test('video scan rejection preserves its reason', () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({
          'videos': [
            {
              'url': '/uploads/camera.mp4',
              'status': 'rejected',
              'reason': 'filtered video'
            },
          ],
        }),
        200));
    final result = await waitForListingImageScan(
        api: 'https://test/api',
        token: 'account',
        url: '/uploads/camera.mp4',
        video: true,
        client: client,
        pollInterval: Duration.zero);
    expect(result.status, 'rejected');
    expect(result.reason, 'filtered video');
  });

  for (final oldVideo in [null, '/uploads/old.mp4']) {
    test(
        '8 photos and video retain order, token and video identity old=$oldVideo',
        () async {
      final requests = <http.Request>[];
      final video = Completer<ListingImageAttachment?>();
      final photos = [
        for (var i = 0; i < 8; i++) Completer<ListingImageAttachment?>()
      ];
      final urls = [for (var i = 0; i < 8; i++) '/uploads/$i.png'];
      final manager =
          ListingBackgroundImages(client: MockClient((request) async {
        requests.add(request);
        return http.Response(
            jsonEncode({'images': urls, 'video_url': '/uploads/camera.mp4'}),
            200);
      }));
      manager.start(
          api: 'https://test/api',
          token: 'original-account',
          listingId: 'original-listing',
          title: 'מודעה',
          includesVideo: true,
          uploads: [for (final photo in photos) photo.future, video.future]);
      final job = manager.forToken('original-account').single;
      manager.dispose();
      video.complete(ListingImageAttachment(
          url: '/uploads/camera.mp4', video: true, expectedOldUrl: oldVideo));
      // Completion order differs from selection order; delivery must retain
      // the original order and keep video out of the photo URL list.
      for (var i = 7; i >= 0; i--) {
        photos[i].complete(ListingImageAttachment(url: urls[i]));
      }
      await job.completion;
      expect(job.total, 9);
      expect(job.attached, 9);
      expect(job.approvedImages, 8);
      expect(job.approvedVideo, isTrue);
      expect(job.hasVideoResult, isTrue);
      expect(job.videoUrl, '/uploads/camera.mp4');
      expect(job.imageUrls, urls);
      expect(
          requests.single.headers['authorization'], 'Bearer original-account');
      expect(requests.single.url.path, '/api/listings/original-listing/images');
      expect(jsonDecode(requests.single.body), {
        'image_urls': urls,
        'replacements': [],
        'video_url': '/uploads/camera.mp4',
        'expected_old_video_url': oldVideo,
      });
    });
  }

  test('mixed failed attachment retries both cached URLs without reupload',
      () async {
    var uploads = 0;
    final requests = <http.Request>[];
    final manager = ListingBackgroundImages(client: MockClient((request) async {
      requests.add(request);
      return requests.length == 1
          ? http.Response('{}', 503)
          : http.Response(
              jsonEncode({
                'images': ['/uploads/photo.png'],
                'video_url': '/uploads/video.mp4'
              }),
              200);
    }));
    addTearDown(manager.dispose);
    Future<ListingImageAttachment?> upload(String url,
        {bool video = false}) async {
      uploads++;
      return ListingImageAttachment(url: url, video: video);
    }

    manager.start(
        api: 'https://test/api',
        token: 'account',
        listingId: 'listing',
        title: 'מודעה',
        includesVideo: true,
        uploads: [
          upload('/uploads/photo.png'),
          upload('/uploads/video.mp4', video: true),
        ]);
    final job = manager.forToken('account').single;
    await job.completion;
    expect(job.canRetry, isTrue);
    expect(job.error, contains('שמירת המדיה'));
    expect(job.hasVideoResult, isFalse);
    await manager.retry(job);
    expect(uploads, 2);
    expect(requests.length, 2);
    expect(requests[0].body, requests[1].body);
    expect(job.attached, 2);
    expect(job.videoUrl, '/uploads/video.mp4');
    expect(job.hasVideoResult, isTrue);
    expect(job.attachedRevision, 1);
  });

  for (final receipt in <Map<String, dynamic>>[
    {},
    {'video_url': null}
  ]) {
    test(
        'video result distinguishes missing receipt from explicit null $receipt',
        () async {
      final manager = ListingBackgroundImages(
          client:
              MockClient((_) async => http.Response(jsonEncode(receipt), 200)));
      addTearDown(manager.dispose);
      manager.start(
          api: 'https://test/api',
          token: 'account',
          listingId: 'listing',
          title: 'מודעה',
          uploads: [
            Future.value(const ListingImageAttachment(
                url: '/uploads/video.mp4', video: true))
          ]);
      final job = manager.forToken('account').single;
      await job.completion;
      expect(job.includesVideo, isTrue);
      expect(job.hasVideoResult, receipt.containsKey('video_url'));
      expect(job.videoUrl, isNull);
    });
  }

  testWidgets('mixed status labels pending and completed media',
      (tester) async {
    final photo = Completer<ListingImageAttachment?>();
    final video = Completer<ListingImageAttachment?>();
    final manager = ListingBackgroundImages(
        client: MockClient((_) async =>
            http.Response('{"video_url":"/uploads/video.mp4"}', 200)));
    addTearDown(manager.dispose);
    manager.start(
        api: 'https://test/api',
        token: 'account',
        listingId: 'listing',
        title: 'מודעה',
        includesVideo: true,
        uploads: [photo.future, video.future]);
    final job = manager.forToken('account').single;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListingBackgroundImageStatus(
                token: 'account', manager: manager))));
    expect(find.text('המדיה נטענת ברקע: 0 מתוך 2'), findsOneWidget);
    photo.complete(const ListingImageAttachment(url: '/uploads/photo.png'));
    video.complete(
        const ListingImageAttachment(url: '/uploads/video.mp4', video: true));
    await tester.pumpAndSettle();
    await job.completion;
    expect(find.text('1 תמונות וסרטון צורפו למודעה'), findsOneWidget);
    expect(find.byTooltip('סגירת עדכון המדיה'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('listing scan waits for its image and returns approval', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.url.path, '/api/listing-image-status');
      expect(request.method, 'POST');
      expect(request.headers['authorization'], 'Bearer original-account');
      expect(jsonDecode(request.body), {
        'image_urls': ['/uploads/photo.png']
      });
      return http.Response(
          jsonEncode({
            'images': [
              {'url': '/uploads/other.png', 'status': 'approved'},
              {
                'url': '/uploads/photo.png',
                'status': requests == 1 ? 'pending' : 'approved',
              },
            ],
          }),
          200);
    });
    final result = await waitForListingImageScan(
      api: 'https://test/api',
      token: 'original-account',
      url: '/uploads/photo.png',
      client: client,
      pollInterval: Duration.zero,
    );
    expect(requests, 2);
    expect(result.status, 'approved');
    expect(result.reason, isNull);
  });

  for (final status in ['rejected', 'unavailable']) {
    test('listing scan stops on $status and preserves reason', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response(
            jsonEncode({
              'images': [
                {
                  'url': '/uploads/photo.png',
                  'status': status,
                  'reason': 'reason'
                },
              ],
            }),
            200);
      });
      final result = await waitForListingImageScan(
        api: 'https://test/api',
        token: 'account',
        url: '/uploads/photo.png',
        client: client,
        pollInterval: Duration.zero,
      );
      expect(requests, 1);
      expect(result.status, status);
      expect(result.reason, 'reason');
    });
  }

  test('listing scan recovers from network and server failures', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      if (requests == 1) throw http.ClientException('offline');
      if (requests == 2) return http.Response('{}', 503);
      return http.Response(
          jsonEncode({
            'images': [
              {
                'url': '/uploads/photo.png',
                'status': requests == 3 ? 'pending' : 'approved',
              },
            ],
          }),
          200);
    });
    final result = await waitForListingImageScan(
      api: 'https://test/api',
      token: 'account',
      url: '/uploads/photo.png',
      client: client,
      pollInterval: Duration.zero,
    );
    expect(requests, 4);
    expect(result.status, 'approved');
  });

  test('listing scan times out while requests keep returning pending',
      () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response(
          jsonEncode({
            'images': [
              {'url': '/uploads/photo.png', 'status': 'pending'},
            ],
          }),
          200);
    });
    await expectLater(
      waitForListingImageScan(
        api: 'https://test/api',
        token: 'account',
        url: '/uploads/photo.png',
        client: client,
        pollInterval: const Duration(milliseconds: 2),
        timeout: const Duration(milliseconds: 40),
      ),
      throwsA(isA<TimeoutException>().having((error) => error.message,
          'message', contains('בדיקת התמונה לא הסתיימה בזמן'))),
    );
    expect(requests, greaterThan(1));
  });

  test('listing scan deadline also limits a stalled network request', () async {
    var requests = 0;
    final pending = Completer<http.Response>();
    final client = MockClient((_) async {
      requests++;
      return pending.future;
    });
    await expectLater(
      waitForListingImageScan(
        api: 'https://test/api',
        token: 'account',
        url: '/uploads/photo.png',
        client: client,
        pollInterval: Duration.zero,
        timeout: const Duration(milliseconds: 40),
      ),
      throwsA(isA<TimeoutException>().having((error) => error.message,
          'message', contains('בדיקת התמונה לא הסתיימה בזמן'))),
    );
    expect(requests, 1);
    pending.complete(http.Response('{}', 503));
  });

  test('attachments continue after form and listener disposal', () async {
    final first = Completer<ListingImageAttachment?>();
    final last = Completer<ListingImageAttachment?>();
    final requests = <http.Request>[];
    final manager = ListingBackgroundImages(client: MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    }));
    manager.start(
      api: 'https://test/api',
      token: 'original-account',
      listingId: 'original-listing',
      title: 'מודעה מקורית',
      uploads: [first.future, last.future],
    );
    final job = manager.forToken('original-account').single;
    var updates = 0;
    manager.addListener(() => updates++);
    manager.dispose();
    first.complete(const ListingImageAttachment(url: '/uploads/first.png'));
    await Future<void>.delayed(Duration.zero);
    expect(job.completed, 1);
    expect(requests, isEmpty);
    last.complete(const ListingImageAttachment(url: '/uploads/last.png'));
    await job.completion;
    expect(updates, 0);
    expect(job.isFinished, isTrue);
    expect(job.attached, 2);
    expect(job.attachedRevision, 1);
    expect(manager.revision, 1);
    expect(requests.single.url.path, '/api/listings/original-listing/images');
    expect(requests.single.headers['authorization'], 'Bearer original-account');
    expect(jsonDecode(requests.single.body), {
      'image_urls': ['/uploads/first.png', '/uploads/last.png'],
      'replacements': [],
    });
  });

  test('only accepted images attach and replacement keeps original identity',
      () async {
    final requests = <http.Request>[];
    final manager = ListingBackgroundImages(client: MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    }));
    addTearDown(manager.dispose);
    manager.start(
      api: 'https://test/api',
      token: 'account',
      listingId: 'listing',
      title: 'מודעה',
      uploads: [
        Future.value(const ListingImageAttachment(url: '/uploads/new.png')),
        Future.value(null),
        Future.error(StateError('upload failed')),
        Future.value(const ListingImageAttachment(
            url: '/uploads/replacement.png',
            expectedOldUrl: '/uploads/old.png')),
        Future.value(const ListingImageAttachment(url: '')),
      ],
    );
    final job = manager.forToken('account').single;
    await job.completion;
    expect(job.completed, 5);
    expect(job.approved, 2);
    expect(job.skipped, 3);
    expect(jsonDecode(requests.single.body), {
      'image_urls': ['/uploads/new.png'],
      'replacements': [
        {
          'expected_old_url': '/uploads/old.png',
          'url': '/uploads/replacement.png',
        },
      ],
    });
  });

  test('failed attachment retries cached URLs without another upload',
      () async {
    final requests = <http.Request>[];
    var uploads = 0;
    final retryResponse = Completer<http.Response>();
    final manager = ListingBackgroundImages(client: MockClient((request) async {
      requests.add(request);
      if (requests.length == 1) return http.Response('{}', 503);
      return retryResponse.future;
    }));
    addTearDown(manager.dispose);
    Future<ListingImageAttachment?> upload() async {
      uploads++;
      return const ListingImageAttachment(url: '/uploads/accepted.png');
    }

    manager.start(
      api: 'https://test/api',
      token: 'account',
      listingId: 'listing',
      title: 'מודעה',
      uploads: [upload()],
    );
    final job = manager.forToken('account').single;
    await job.completion;
    expect(job.canRetry, isTrue);
    expect(job.attached, 0);
    expect(job.attachedRevision, 0);
    expect(manager.revision, 0);
    final retry = manager.retry(job);
    await manager.retry(job);
    await Future<void>.delayed(Duration.zero);
    expect(requests.length, 2);
    retryResponse.complete(http.Response('{}', 200));
    await retry;
    expect(uploads, 1);
    expect(requests[0].body, requests[1].body);
    expect(job.canRetry, isFalse);
    expect(job.attached, 1);
    expect(job.imageUrls, isNull);
    expect(manager.revision, 1);
    await manager.retry(job);
    expect(requests.length, 2);
    manager.dismiss(job);
    expect(manager.forToken('account'), isEmpty);
  });

  test('completed job retains the server image list as read-only', () async {
    final manager = ListingBackgroundImages(client: MockClient((_) async {
      return http.Response(
          jsonEncode({
            'images': ['/uploads/previous.png', '/uploads/new.png'],
          }),
          200);
    }));
    addTearDown(manager.dispose);
    manager.start(
      api: 'https://test/api',
      token: 'account',
      listingId: 'listing',
      title: 'מודעה',
      uploads: [
        Future.value(const ListingImageAttachment(url: '/uploads/new.png'))
      ],
    );
    final job = manager.forToken('account').single;
    await job.completion;
    expect(job.imageUrls, ['/uploads/previous.png', '/uploads/new.png']);
    expect(
        () => job.imageUrls!.add('/uploads/other.png'), throwsUnsupportedError);
    manager.dismiss(job);
    expect(job.imageUrls, ['/uploads/previous.png', '/uploads/new.png']);
  });

  test('attachment revision follows completion order instead of creation order',
      () async {
    final firstResponse = Completer<http.Response>();
    final lastResponse = Completer<http.Response>();
    final manager = ListingBackgroundImages(client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      return (body['image_urls'] as List).single == '/uploads/first.png'
          ? firstResponse.future
          : lastResponse.future;
    }));
    addTearDown(manager.dispose);
    for (final name in ['first', 'last']) {
      manager.start(
        api: 'https://test/api',
        token: 'account',
        listingId: 'listing',
        title: 'מודעה',
        uploads: [
          Future.value(ListingImageAttachment(url: '/uploads/$name.png'))
        ],
      );
    }
    final jobs = manager.forToken('account');
    lastResponse.complete(http.Response(
        jsonEncode({
          'images': ['/uploads/last.png']
        }),
        200));
    await jobs.last.completion;
    expect(jobs.last.attachedRevision, 1);
    expect(jobs.first.attachedRevision, 0);
    firstResponse.complete(http.Response(
        jsonEncode({
          'images': ['/uploads/last.png', '/uploads/first.png']
        }),
        200));
    await jobs.first.completion;
    expect(jobs.first.attachedRevision, 2);
    expect(manager.revision, 2);
  });

  test('unapproved batch finishes without an attachment request', () async {
    var requests = 0;
    final manager = ListingBackgroundImages(client: MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    }));
    addTearDown(manager.dispose);
    manager.start(
      api: 'https://test/api',
      token: 'account',
      listingId: 'listing',
      title: 'מודעה',
      uploads: [Future.value(null)],
    );
    final job = manager.forToken('account').single;
    await job.completion;
    expect(job.isFinished, isTrue);
    expect(job.skipped, 1);
    expect(requests, 0);
    expect(manager.revision, 0);
  });

  for (final status in [400, 409]) {
    test('attachment error preserves server explanation for status $status',
        () async {
      const reason = 'התמונות במודעה השתנו. יש לפתוח את המודעה מחדש';
      final manager = ListingBackgroundImages(client: MockClient((_) async {
        return http.Response(jsonEncode({'error': reason}), status,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }));
      addTearDown(manager.dispose);
      manager.start(
        api: 'https://test/api',
        token: 'account',
        listingId: 'listing',
        title: 'מודעה',
        uploads: [
          Future.value(const ListingImageAttachment(url: '/uploads/photo.png'))
        ],
      );
      final job = manager.forToken('account').single;
      await job.completion;
      expect(job.error, contains(reason));
      expect(job.canRetry, isTrue);
      expect(job.attached, 0);
      expect(manager.revision, 0);
    });
  }

  testWidgets('unapproved or pending images show a warning instead of success',
      (tester) async {
    final manager = ListingBackgroundImages();
    addTearDown(manager.dispose);
    manager.start(
      api: 'https://test/api',
      token: 'account',
      listingId: 'listing',
      title: 'מודעה',
      uploads: [Future.value(null)],
    );
    await manager.forToken('account').single.completion;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListingBackgroundImageStatus(token: 'account', manager: manager),
      ),
    ));
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);
    expect(
        find.text('1 תמונות לא צורפו — '
            'לא אושרו, עדיין ממתינות לסריקה או נכשלו בהעלאה'),
        findsOneWidget);
    expect(find.text('נסה לצרף שוב'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed attachment can be dismissed after the request finishes',
      (tester) async {
    final response = Completer<http.Response>();
    final manager = ListingBackgroundImages(client: MockClient((_) async {
      return response.future;
    }));
    addTearDown(manager.dispose);
    manager.start(
      api: 'https://test/api',
      token: 'account',
      listingId: 'listing',
      title: 'מודעה',
      uploads: [
        Future.value(const ListingImageAttachment(url: '/uploads/photo.png'))
      ],
    );
    final job = manager.forToken('account').single;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListingBackgroundImageStatus(token: 'account', manager: manager),
      ),
    ));
    manager.dismiss(job);
    expect(manager.forToken('account'), [job]);
    expect(find.byTooltip('סגירת עדכון התמונות'), findsNothing);
    response.complete(http.Response('{}', 409));
    await tester.pumpAndSettle();
    await job.completion;
    expect(find.text('נסה לצרף שוב'), findsOneWidget);
    await tester.tap(find.byTooltip('סגירת עדכון התמונות'));
    await tester.pumpAndSettle();
    expect(manager.forToken('account'), isEmpty);
    expect(find.text('מודעה'), findsNothing);
    await manager.retry(job);
    expect(manager.forToken('account'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('status follows current account and survives widget navigation',
      (tester) async {
    final upload = Completer<ListingImageAttachment?>();
    final manager = ListingBackgroundImages(client: MockClient((_) async {
      return http.Response('{}', 200);
    }));
    addTearDown(manager.dispose);
    manager.start(
      api: 'https://test/api',
      token: 'first-account',
      listingId: 'listing',
      title: 'מודעה פרטית',
      uploads: [upload.future],
    );
    final job = manager.forToken('first-account').single;
    Widget page(String token) => MaterialApp(
          home: Scaffold(
            body: ListingBackgroundImageStatus(token: token, manager: manager),
          ),
        );
    await tester.pumpWidget(page('first-account'));
    expect(find.text('מודעה פרטית'), findsOneWidget);
    expect(find.text('התמונות נטענות ברקע: 0 מתוך 1'), findsOneWidget);
    await tester.pumpWidget(page('second-account'));
    expect(find.text('מודעה פרטית'), findsNothing);
    upload.complete(const ListingImageAttachment(url: '/uploads/accepted.png'));
    await tester.pumpAndSettle();
    await job.completion;
    expect(find.text('מודעה פרטית'), findsNothing);
    await tester.pumpWidget(page('first-account'));
    expect(find.text('1 תמונות צורפו למודעה'), findsOneWidget);
    await tester.tap(find.byTooltip('סגירת עדכון התמונות'));
    await tester.pumpAndSettle();
    expect(find.text('מודעה פרטית'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
