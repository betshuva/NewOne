import 'dart:convert';

import 'package:betshuva/message_hover.dart';
import 'package:betshuva/message_image_bounds.dart';
import 'package:betshuva/message_reactions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/reaction_image_fixtures.dart';

const _api = 'https://example.test/api';
const _token = 'image-bounds-token';
const _messageId = 'decoded-photo';

class _ReactionArtwork extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8
          .encode('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36">'
              '<path fill="#ffcc4d" d="M3 3h30v30H3z"/></svg>')));
}

class _Harness {
  _Harness(this.bytes, this.maxSize, {this.availableWidth = 300});
  final Uint8List bytes;
  final Size maxSize;
  final double availableWidth;
  final cache = MessageReactionsCache();
  final requests = <http.Request>[];
  var imageTaps = 0;
  late final client = MockClient((request) async {
    requests.add(request);
    final reactions = [
      {'emoji': '👍', 'count': 1, 'mine': false},
    ];
    return http.Response(
        jsonEncode(request.url.path.endsWith('/reactions/details')
            ? {'reactions': reactions, 'users': <dynamic>[]}
            : reactions),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    // Decode real PNG bytes outside fake async. Image.memory below reuses the
    // exact provider, so both native and Chrome test actual decoded dimensions.
    await tester.runAsync(() => precacheImage(
        MemoryImage(bytes), tester.element(find.byType(Scaffold))));
    await tester.pumpWidget(DefaultAssetBundle(
      bundle: _ReactionArtwork(),
      child: MaterialApp(
          home: Scaffold(
              body: Align(
        alignment: Alignment.topRight,
        child: SizedBox(
          width: availableWidth,
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  MessageHover(
                    key: const ValueKey('photo-hover'),
                    reactionsOnChild: true,
                    actions: const SizedBox(width: 30, height: 30),
                    sideReactions: MessageReactions(
                        api: _api,
                        token: _token,
                        messageId: _messageId,
                        client: client,
                        cache: cache,
                        compact: true,
                        showAddButton: false),
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          GestureDetector(
                            onTap: () => imageTaps++,
                            child: MessageObjectReactions(
                              key: const ValueKey('photo-object'),
                              child: MessageImageBounds(
                                key: const ValueKey('photo-bounds'),
                                maxWidth: maxSize.width,
                                maxHeight: maxSize.height,
                                child: Image.memory(bytes,
                                    fit: BoxFit.contain,
                                    alignment: Alignment.center),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text('כיתוב מתחת לתמונה',
                              key: ValueKey('caption')),
                        ]),
                  ),
                  const SizedBox(
                      key: ValueKey('next-message'), width: 220, height: 40),
                ]),
          ),
        ),
      ))),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    client.close();
    cache.dispose();
  }
}

Finder get _rawImage => find.descendant(
    of: find.byKey(const ValueKey('photo-bounds')),
    matching: find.byType(RawImage));

Rect _actualPhotoRect(WidgetTester tester) {
  final render = tester.renderObject<RenderImage>(_rawImage);
  expect(render.image, isNotNull);
  final intrinsic = Size(
      render.image!.width / render.scale, render.image!.height / render.scale);
  final fitted =
      applyBoxFit(render.fit ?? BoxFit.scaleDown, intrinsic, render.size);
  // The full image remains visible; neither cropping nor transparent letterbox
  // is allowed to masquerade as the actual corner for reaction placement.
  expect(fitted.source, intrinsic);
  final destination = render.alignment
      .resolve(TextDirection.rtl)
      .inscribe(fitted.destination, Offset.zero & render.size);
  expect(destination.size.width, closeTo(render.size.width, 0.001));
  expect(destination.size.height, closeTo(render.size.height, 0.001));
  return Rect.fromPoints(render.localToGlobal(destination.topLeft),
      render.localToGlobal(destination.bottomRight));
}

Future<void> _expectCornerAndMenu(WidgetTester tester, _Harness harness,
    Size expected, Size intrinsic) async {
  final image = tester.widget<RawImage>(_rawImage);
  expect(Size(image.image!.width.toDouble(), image.image!.height.toDouble()),
      intrinsic);
  final photo = _actualPhotoRect(tester);
  final imageLayout = tester.getRect(_rawImage);
  expect(photo.left, closeTo(imageLayout.left, 0.001));
  expect(photo.right, closeTo(imageLayout.right, 0.001));
  expect(photo.top, closeTo(imageLayout.top, 0.001));
  expect(photo.bottom, closeTo(imageLayout.bottom, 0.001));
  expect(photo.width, closeTo(expected.width, 0.001));
  expect(photo.height, closeTo(expected.height, 0.001));
  final button = find.byKey(const ValueKey('compact-reaction-👍'));
  final hit = tester.getRect(button);
  final glyph = tester
      .getRect(find.descendant(of: button, matching: find.byType(SvgPicture)));
  final wrapper = tester.getRect(find.byKey(const ValueKey('photo-object')));
  expect(hit.right, closeTo(photo.right, 0.001));
  expect(glyph.right, closeTo(photo.right - 6, 0.001));
  expect(glyph.size, const Size(20, 20));
  expect(glyph.top, closeTo(photo.bottom - 8, 0.001));
  expect(hit.bottom, closeTo(photo.bottom + 18, 0.001));
  expect(wrapper.contains(hit.bottomRight - const Offset(1, 1)), isTrue);
  expect(tester.getRect(find.byKey(const ValueKey('caption'))).top,
      greaterThan(hit.bottom));
  final next = tester.getRect(find.byKey(const ValueKey('next-message')));
  await tester.tapAt(Offset(hit.center.dx, photo.bottom + 15));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('reaction-details-dialog')), findsOneWidget);
  expect(find.byKey(const ValueKey('change-reaction-❤️')), findsNothing);
  expect(harness.imageTaps, 0);
  expect(harness.requests.map((request) => request.method), ['GET', 'GET']);
  expect(harness.requests.map((request) => request.url.path), [
    '/api/messages/$_messageId/reactions',
    '/api/messages/$_messageId/reactions/details',
  ]);
  await tester.tap(find.byKey(const ValueKey('reaction-details-add-own')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('change-reaction-❤️')), findsOneWidget);
  expect(harness.imageTaps, 0);
  expect(harness.requests.map((request) => request.method), ['GET', 'GET']);
  expect(_actualPhotoRect(tester), photo);
  expect(tester.getRect(find.byKey(const ValueKey('next-message'))), next);
  Navigator.of(tester.element(find.byKey(const ValueKey('change-reaction-❤️'))))
      .pop();
  await tester.pumpAndSettle();
  final details = find.byKey(const ValueKey('reaction-details-dialog'));
  expect(details, findsOneWidget);
  Navigator.of(tester.element(details)).pop();
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  for (final cap in [
    (name: 'private', size: chatImageMaxSize()),
    (name: 'group', size: chatImageMaxSize(group: true)),
  ]) {
    for (final shape in [
      (
        name: 'landscape',
        intrinsic: const Size(400, 200),
        expected: Size(cap.size.width, cap.size.width / 2)
      ),
      (
        name: 'portrait',
        intrinsic: const Size(200, 400),
        expected: Size(cap.size.height / 2, cap.size.height)
      ),
      (
        name: 'square',
        intrinsic: const Size(200, 200),
        expected: const Size(200, 200)
      ),
      (
        name: 'phonePortrait',
        intrinsic: const Size(360, 640),
        expected: cap.name == 'private'
            ? const Size(213.75, 380)
            : const Size(200, 200 * 640 / 360)
      ),
    ]) {
      testWidgets(
          '${cap.name} decoded ${shape.name} corner follows painted photo',
          (tester) async {
        final harness = _Harness(reactionImageFixtures[shape.name]!, cap.size);
        await harness.show(tester);
        await _expectCornerAndMenu(
            tester, harness, shape.expected, shape.intrinsic);
        await harness.dispose(tester);
      });
    }
  }

  testWidgets(
      'narrow parent constrains photo naturally and keeps lower hit usable',
      (tester) async {
    final harness = _Harness(
        reactionImageFixtures['landscape']!, chatImageMaxSize(),
        availableWidth: 150);
    await harness.show(tester);
    await _expectCornerAndMenu(
        tester, harness, const Size(120, 60), const Size(400, 200));
    await harness.dispose(tester);
  });

  testWidgets(
      'small decoded image remains intrinsic instead of acquiring letterbox',
      (tester) async {
    final harness =
        _Harness(reactionImageFixtures['small']!, chatImageMaxSize());
    await harness.show(tester);
    await _expectCornerAndMenu(
        tester, harness, const Size(80, 40), const Size(80, 40));
    await harness.dispose(tester);
  });

  testWidgets('phone portrait fits a narrow chat without crop or empty frame',
      (tester) async {
    final harness = _Harness(
        reactionImageFixtures['phonePortrait']!, chatImageMaxSize(),
        availableWidth: 150);
    await harness.show(tester);
    await _expectCornerAndMenu(tester, harness,
        const Size(120, 120 * 640 / 360), const Size(360, 640));
    await harness.dispose(tester);
  });

  for (final group in [false, true]) {
    testWidgets(
        'uploaded sticker remains compact in ${group ? 'group' : 'private'} chat',
        (tester) async {
      final cap =
          chatImageMaxSize(group: group, fileName: 'betshuva-sticker-01.png');
      final harness = _Harness(reactionImageFixtures['square']!, cap);
      await harness.show(tester);
      final side = group ? 160.0 : 180.0;
      await _expectCornerAndMenu(
          tester, harness, Size(side, side), const Size(200, 200));
      await harness.dispose(tester);
    });
  }
}
