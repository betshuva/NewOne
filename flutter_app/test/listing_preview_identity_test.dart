import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// The platform seam belongs to the app's existing path_provider dependency.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _me = {'id': 'preview-identity-user', 'name': 'משתמש בדיקה'};
const _recipient = {'id': kSafeInformationAiId, 'name': 'מידע בטוח · AI'};
const _firstId = '11111111-1000-4000-8000-000000000001';
const _secondId = '11111111-1000-4000-8000-000000000002';
const _thirdId = '11111111-1000-4000-8000-000000000003';
const _filter = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true,
};

late Uint8List _redImage;
late Uint8List _blueImage;

class _NoMediaCachePath extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      throw UnsupportedError('Disk cache is disabled for this widget test');
}

http.Response _json(Object data) => http.Response(jsonEncode(data), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _message({String? listingId, String? imageUrl}) => {
      'id': 'preview-identity-message',
      'sender_id': kSafeInformationAiId,
      'recipient_id': _me['id'],
      'body': listingId == null ? '' : 'betshuva://listing/$listingId',
      'type': imageUrl == null ? 'text' : 'image',
      if (imageUrl != null) 'file_url': imageUrl,
      'created_at': '2026-09-09T12:00:00Z',
      'message_status': 'read',
      'is_read': true,
    };

Finder _imageWithBytes(Uint8List bytes) => find.byWidgetPredicate((widget) {
      if (widget is! Image) return false;
      final provider = widget.image;
      final image = provider is ResizeImage ? provider.imageProvider : provider;
      return image is MemoryImage && listEquals(image.bytes, bytes);
    });

Future<Uint8List> _coloredImage(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(2, 2);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Future<void> _pumpMedia(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  await tester.pump();
}

Future<void> _withChat(
  WidgetTester tester, {
  required String token,
  required Future<http.Response> Function(http.Request request) respond,
  required Future<void> Function(io.Socket socket) check,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final socket = io.io('http://localhost:1',
      io.OptionBuilder().disableAutoConnect().enableForceNew().build());
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: ChatScreen(
            token: token,
            me: _me,
            recipient: _recipient,
            socket: socket,
            embedded: true,
          ),
        ),
      ));
      await _pumpMedia(tester);
      await check(socket);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      socket.connected = false;
      socket.dispose();
    }
  },
      () => MockClient((request) async {
            if (request.url.path.endsWith('/filter-settings')) {
              return _json({'filter': _filter, 'requiresChoice': false});
            }
            if (request.url.path.endsWith('/receiving-filter')) {
              return _json({'filter': _filter});
            }
            return respond(request);
          }));
  expect(tester.takeException(), isNull);
}

void _replaceListing(io.Socket socket, String listingId) {
  socket.connected = true;
  socket.onevent({
    'data': [
      'message:edited',
      {
        'id': 'preview-identity-message',
        'body': 'betshuva://listing/$listingId',
      },
    ],
  });
  socket.connected = false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _NoMediaCachePath();
    addTearDown(() => PathProviderPlatform.instance = originalPathProvider);
  });
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
    _redImage = await _coloredImage(Colors.red);
    _blueImage = await _coloredImage(Colors.blue);
  });

  testWidgets('changed listing clears previous title and image while loading',
      (tester) async {
    final pendingPreview = Completer<http.Response>();
    var secondRequested = false;
    await _withChat(tester, token: 'changed-preview-token',
        respond: (request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path.contains('/messages/')) {
        return _json([_message(listingId: _firstId)]);
      }
      if (path.endsWith('/listings/$_firstId/preview')) {
        return _json({
          'title': 'רכב אדום',
          'image_url': 'https://preview.test/changed-first.png',
        });
      }
      if (path.endsWith('/listings/$_secondId/preview')) {
        secondRequested = true;
        return pendingPreview.future;
      }
      if (path.endsWith('/changed-first.png')) {
        return http.Response.bytes(_redImage, 200);
      }
      if (path.endsWith('/changed-second.png')) {
        return http.Response.bytes(_blueImage, 200);
      }
      return _json({});
    }, check: (socket) async {
      expect(find.text('רכב אדום'), findsOneWidget);
      expect(_imageWithBytes(_redImage), findsOneWidget);

      _replaceListing(socket, _secondId);
      await tester.pump();
      await tester.pump();
      expect(secondRequested, isTrue);
      expect(find.text('רכב אדום'), findsNothing);
      expect(_imageWithBytes(_redImage), findsNothing);
      expect(find.text('צפה במודעה'), findsOneWidget);

      pendingPreview.complete(_json({
        'title': 'מקרר כחול',
        'image_url': 'https://preview.test/changed-second.png',
      }));
      await _pumpMedia(tester);
      expect(find.text('מקרר כחול'), findsOneWidget);
      expect(_imageWithBytes(_blueImage), findsOneWidget);
      expect(find.text('רכב אדום'), findsNothing);
      expect(_imageWithBytes(_redImage), findsNothing);
    });
  });

  testWidgets('late preview cannot replace a newer listing in the same message',
      (tester) async {
    final pendingPreview = Completer<http.Response>();
    var delayedRequested = false;
    await _withChat(tester, token: 'out-of-order-preview-token',
        respond: (request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path.contains('/messages/')) {
        return _json([_message(listingId: _firstId)]);
      }
      if (path.endsWith('/listings/$_firstId/preview')) {
        return _json({'title': 'המודעה הראשונה'});
      }
      if (path.endsWith('/listings/$_secondId/preview')) {
        delayedRequested = true;
        return pendingPreview.future;
      }
      if (path.endsWith('/listings/$_thirdId/preview')) {
        return _json({'title': 'המודעה הנוכחית'});
      }
      return _json({});
    }, check: (socket) async {
      expect(find.text('המודעה הראשונה'), findsOneWidget);
      _replaceListing(socket, _secondId);
      await tester.pump();
      await tester.pump();
      expect(delayedRequested, isTrue);
      _replaceListing(socket, _thirdId);
      await _pumpMedia(tester);
      expect(find.text('המודעה הנוכחית'), findsOneWidget);

      pendingPreview.complete(_json({'title': 'תשובה ישנה שהתעכבה'}));
      await _pumpMedia(tester);
      expect(find.text('המודעה הנוכחית'), findsOneWidget);
      expect(find.text('תשובה ישנה שהתעכבה'), findsNothing);
      expect(find.text('המודעה הראשונה'), findsNothing);
    });
  });

  testWidgets('history refresh never paints previous bytes for a new image URL',
      (tester) async {
    final pendingImage = Completer<http.Response>();
    var imageUrl = 'https://preview.test/history-first.png';
    var secondRequested = false;
    await _withChat(tester, token: 'image-history-token',
        respond: (request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path.contains('/messages/')) {
        return _json([_message(imageUrl: imageUrl)]);
      }
      if (path.endsWith('/history-first.png')) {
        return http.Response.bytes(_redImage, 200);
      }
      if (path.endsWith('/history-second.png')) {
        secondRequested = true;
        return pendingImage.future;
      }
      return _json({});
    }, check: (_) async {
      expect(_imageWithBytes(_redImage), findsOneWidget);
      imageUrl = 'https://preview.test/history-second.png';
      await tester.pump(const Duration(seconds: 4));
      await _pumpMedia(tester);
      expect(secondRequested, isTrue);
      expect(_imageWithBytes(_redImage), findsNothing);
      expect(_imageWithBytes(_blueImage), findsNothing);

      pendingImage.complete(http.Response.bytes(_blueImage, 200));
      await _pumpMedia(tester);
      expect(_imageWithBytes(_blueImage), findsOneWidget);
      expect(_imageWithBytes(_redImage), findsNothing);
    });
  });

  testWidgets('a different account cannot reuse an authorized listing preview',
      (tester) async {
    final previewTokens = <String>[];
    Future<http.Response> respond(http.Request request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path.contains('/messages/')) {
        return _json([_message(listingId: _firstId)]);
      }
      if (path.endsWith('/listings/$_firstId/preview')) {
        final authorization = request.headers['Authorization']!;
        previewTokens.add(authorization);
        if (authorization == 'Bearer authorized-preview-token') {
          return _json({
            'title': 'מודעה המותרת לחשבון הראשון',
            'image_url': 'https://preview.test/account-first.png',
          });
        }
        return http.Response('{}', 403);
      }
      if (path.endsWith('/account-first.png')) {
        return http.Response.bytes(_redImage, 200);
      }
      return _json({});
    }

    await _withChat(tester, token: 'authorized-preview-token', respond: respond,
        check: (_) async {
      expect(find.text('מודעה המותרת לחשבון הראשון'), findsOneWidget);
      expect(_imageWithBytes(_redImage), findsOneWidget);
    });
    await _withChat(tester, token: 'other-preview-token', respond: respond,
        check: (_) async {
      expect(find.text('מודעה המותרת לחשבון הראשון'), findsNothing);
      expect(_imageWithBytes(_redImage), findsNothing);
      expect(find.text('צפה במודעה'), findsOneWidget);
    });
    expect(previewTokens,
        ['Bearer authorized-preview-token', 'Bearer other-preview-token']);
  });
}
