import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:betshuva/filter_history.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const allowed = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true
};
const url = 'https://example.test/own-image.png';
const senderBlocked = 'סוג התמונה חסום בהגדרות הסינון שלך';
const groupData = {
  'id': 'group',
  'name': 'קבוצה',
  'status': 'member',
  'role': 'member',
  'send_permission': 'all'
};
final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');
http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

class TestImageFile extends XFile {
  TestImageFile()
      : super('own-image.png', name: 'own-image.png', mimeType: 'image/png');

  // XFile.fromData on web still uses browser FileReader events. Keep file I/O
  // inside the test clock while exercising the real multipart upload path.
  @override
  Future<Uint8List> readAsBytes() async => png;

  @override
  Future<int> length() async => png.length;
}

class TestImagePicker extends ImagePickerPlatform {
  final requestedSources = <ImageSource>[];

  @override
  Future<XFile?> getImageFromSource(
      {required ImageSource source,
      ImagePickerOptions options = const ImagePickerOptions()}) async {
    requestedSources.add(source);
    return TestImageFile();
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    requestedSources.add(ImageSource.gallery);
    return [TestImageFile()];
  }
}

Widget chat(bool group, {io.Socket? socket}) => MaterialApp(
    home: group
        ? GroupChatScreen(
            token: 'token',
            me: {'id': 'viewer', 'name': 'אני'},
            group: groupData,
            socket: socket,
            embedded: true)
        : ChatScreen(
            token: 'token',
            me: {'id': 'viewer', 'name': 'אני'},
            recipient: {'id': 'friend', 'name': 'חבר'},
            socket: socket,
            embedded: true));
bool isHistory(http.Request request, bool group) =>
    request.method == 'GET' &&
    request.url.path
        .endsWith(group ? '/groups/group/messages' : '/messages/friend');
http.Response defaultResponse(http.Request request) {
  final path = request.url.path;
  if (path.endsWith('.png')) {
    return http.Response.bytes(png, 200,
        headers: {'content-type': 'image/png'});
  }
  if (path.endsWith('/groups')) return json([groupData]);
  if (path.endsWith('/groups/group')) {
    return json({
      'members': [
        {'id': 'viewer', 'name': 'אני', 'role': 'member'}
      ]
    });
  }
  if (path.endsWith('/filter-settings')) {
    return json({
      'filter': allowed,
      'personalFilter': allowed,
      'requiresChoice': false
    });
  }
  if (path.endsWith('/receiving-filter')) return json({'filter': allowed});
  return json({});
}

Map<String, dynamic> ownImage(bool hidden) => {
      'id': 'own-image',
      'sender_id': 'viewer',
      'sender_name': 'אני',
      'type': 'image',
      'file_url': hidden ? null : url,
      'filter_hidden': hidden,
      'file_name': 'own-image.png',
      'created_at': '2026-09-17T00:01:00Z',
    };
void size(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder image(bool group) => find.byKey(
    ValueKey(group ? 'group-image-own-image' : 'chat-image-own-image-$url'));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final group in [false, true]) {
    final scope = group ? 'group' : 'private';
    testWidgets('$scope own cached image waits for fresh visibility',
        (tester) async {
      size(tester);
      SharedPreferences.setMockInitialValues({
        group ? 'cache_group_msgs_viewer_group' : 'cache_msgs_viewer_friend':
            jsonEncode([
          {
            'id': 'own-image',
            'from': 'viewer',
            'isMe': true,
            'isFile': true,
            'fileType': 'image',
            'fileUrl': url,
            'fileName': 'own-image.png',
            'text': '',
            'status': 'sent'
          }
        ]),
      });
      final gate = Completer<void>();
      await http.runWithClient(() async {
        await tester.pumpWidget(chat(group));
        await tester.pump(const Duration(milliseconds: 100));
        expect(image(group), findsNothing);
        gate.complete();
        await tester.pumpAndSettle();
        expect(image(group), findsNothing);
        expect(find.byType(FilterHiddenImage), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      },
          () => MockClient((request) async {
                if (isHistory(request, group)) {
                  await gate.future;
                  return json([ownImage(true)]);
                }
                return defaultResponse(request);
              }));
    });
    testWidgets(
        '$scope filter change immediately removes own image before reload',
        (tester) async {
      size(tester);
      SharedPreferences.setMockInitialValues({});
      var changed = false;
      final gate = Completer<void>();
      await http.runWithClient(() async {
        await tester.pumpWidget(chat(group));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(image(group), findsOneWidget);
        changed = true;
        receivingFilterChanges.add('token');
        await tester.pump(const Duration(milliseconds: 100));
        expect(image(group), findsNothing);
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.byType(FilterHiddenImage), findsOneWidget);
        expect(image(group), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      },
          () => MockClient((request) async {
                if (isHistory(request, group)) {
                  if (changed) await gate.future;
                  return json([ownImage(changed)]);
                }
                return defaultResponse(request);
              }));
    });
    for (final event in ['scan:rejected', 'message:rejected']) {
      testWidgets('$scope delayed $event removes own pending image preview',
          (tester) async {
        size(tester);
        SharedPreferences.setMockInitialValues({});
        final socket = io.io('http://localhost:1',
            io.OptionBuilder().disableAutoConnect().enableForceNew().build());
        addTearDown(() {
          socket.connected = false;
          socket.dispose();
        });
        var rejected = false;
        await http.runWithClient(() async {
          await tester.pumpWidget(chat(group, socket: socket));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.text('own-image.png'), findsOneWidget);
          rejected = true;
          socket.connected = true;
          socket.onevent({
            'data': [
              event,
              {
                'fileUrl': url,
                'toUserId': 'friend',
                'groupId': group ? 'group' : null,
                'code': 'SENDER_CONTENT_FILTERED',
                'blockedBy': 'sender_filter',
                'reason': senderBlocked,
                'blockedPreviewUrl': url,
              }
            ]
          });
          socket.connected = false;
          await tester.pumpAndSettle();
          expect(find.text(senderBlocked), findsOneWidget);
          expect(find.text('own-image.png'), findsNothing);
          expect(image(group), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull);
        },
            () => MockClient((request) async {
                  if (isHistory(request, group)) {
                    return json(rejected
                        ? []
                        : [
                            {
                              ...ownImage(false),
                              'message_status': 'pending_scan'
                            }
                          ]);
                  }
                  return defaultResponse(request);
                }));
      });
    }
    for (final rejection in ['upload-403', 'upload-200', 'send-403']) {
      testWidgets(
          '$scope $rejection reports sender filtering without image bubble',
          (tester) async {
        size(tester);
        SharedPreferences.setMockInitialValues({});
        final oldPicker = ImagePickerPlatform.instance;
        final picker = TestImagePicker();
        ImagePickerPlatform.instance = picker;
        addTearDown(() => ImagePickerPlatform.instance = oldPicker);
        var uploads = 0;
        var sends = 0;
        final response = {
          'code': 'SENDER_CONTENT_FILTERED',
          'blockedBy': 'sender_filter',
          'status': 'rejected',
          'url': url,
          'blockedPreviewUrl': url,
          'error': senderBlocked,
          'reason': senderBlocked
        };
        await http.runWithClient(() async {
          await tester.pumpWidget(chat(group));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          // Web camera capture uses the browser directly, outside the mocked
          // image picker. Select the same single PNG through gallery on web.
          await tester.tap(find.text(kIsWeb
              ? 'גלריה (עד 10)'
              : group
                  ? 'מצלמה'
                  : 'צלם תמונה'));
          await tester.pumpAndSettle();
          expect(picker.requestedSources,
              [kIsWeb ? ImageSource.gallery : ImageSource.camera]);
          expect(uploads, 1);
          expect(sends, rejection == 'send-403' ? 1 : 0);
          expect(find.text(senderBlocked), findsOneWidget);
          expect(find.text('own-image.png'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull);
        },
            () => MockClient((request) async {
                  if (isHistory(request, group)) return json([]);
                  if (request.method == 'POST' &&
                      request.url.path.endsWith('/upload')) {
                    uploads++;
                    if (rejection == 'send-403') {
                      return json({'url': url, 'status': 'approved'});
                    }
                    return json(
                        response, rejection == 'upload-403' ? 403 : 200);
                  }
                  if (request.method == 'POST' &&
                      request.url.path.endsWith('/messages')) {
                    sends++;
                    return json(response, 403);
                  }
                  return defaultResponse(request);
                }));
      });
    }
  }
}
