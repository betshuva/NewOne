import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:betshuva/blocked_image_notice.dart';
import 'package:betshuva/keyboard_inserted_image.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart' show kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _draft = 'טיוטה שלום 🙂 123\nשורה שנייה';
const _token = 'ime-test-token';
const _fileUrl = '/api/uploads/ime-keyboard-image.png';
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');
final _gif = base64Decode('R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==');
final _android = TargetPlatformVariant.only(TargetPlatform.android);

http.Response _json(Object data) => http.Response(jsonEncode(data), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _ImeChat {
  _ImeChat({required this.group});

  final bool group;
  bool imagesAllowed = true;
  String groupStatus = 'member';
  String groupSendPermission = 'all';
  Completer<http.Response>? uploadGate;
  String outcome = 'approved';
  final requests = <http.Request>[];
  final uploads = <http.Request>[];
  final sends = <http.Request>[];

  String get target => group ? 'ime-group' : 'ime-friend';

  Map<String, dynamic> groupData(String id) => {
        'id': id,
        'name': id,
        'role': 'member',
        'status': groupStatus,
        'send_permission': groupSendPermission,
        'member_count': 1,
      };

  Map<String, bool> get filter => {
        'text': true,
        'video': true,
        'nonHumanImages': imagesAllowed,
        'men': imagesAllowed,
        'women': imagesAllowed,
        'children': imagesAllowed,
      };

  Object uploadResult([String? status]) => {
        'status': status ?? outcome,
        'url': _fileUrl,
        'fileType': 'image',
        'reason': 'התמונה לא אושרה בסריקה',
      };

  late final client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' &&
        (path.contains('/messages/') || path.endsWith('/messages'))) {
      return _json([]);
    }
    if (path.endsWith('/upload')) {
      uploads.add(request);
      return uploadGate == null
          ? _json(uploadResult())
          : await uploadGate!.future;
    }
    if (request.method == 'POST' && path.endsWith('/messages')) {
      sends.add(request);
      return _json({'id': 'ime-message-${sends.length}', 'status': 'sent'});
    }
    if (path.endsWith('/groups')) return _json([groupData(target)]);
    if (path.contains('/groups/') &&
        !path.endsWith('/filter-settings') &&
        !path.endsWith('/receiving-filter') &&
        !path.endsWith('/invitation-filters')) {
      return _json({
        'members': [
          {'id': 'ime-viewer', 'name': 'אני', 'role': 'member'}
        ],
        'pending_invite_ids': [],
      });
    }
    if (path.endsWith('/filter-settings') ||
        path.endsWith('/receiving-filter')) {
      return _json({
        'filter': filter,
        'personalFilter': filter,
        'requiresChoice': false,
      });
    }
    if (path.endsWith('.png')) {
      return http.Response.bytes(_png, 200,
          headers: {'content-type': 'image/png'});
    }
    return _json({});
  });

  Widget app([String? destination]) {
    final id = destination ?? target;
    return MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSansHebrew'),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: group
            ? GroupChatScreen(
                key: ValueKey('ime-$id'),
                token: _token,
                socket: null,
                me: const {'id': 'ime-viewer', 'name': 'אני'},
                group: groupData(id),
                embedded: true,
              )
            : ChatScreen(
                key: ValueKey('ime-$id'),
                token: _token,
                socket: null,
                me: const {'id': 'ime-viewer', 'name': 'אני'},
                recipient: {'id': id, 'name': id},
                embedded: true,
              ),
      ),
    );
  }
}

Future<void> _withChat(
    WidgetTester tester, _ImeChat chat, Future<void> Function() check) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(chat.app());
      await tester.pumpAndSettle();
      await check();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (chat.uploadGate != null && !chat.uploadGate!.isCompleted) {
        chat.uploadGate!.complete(_json(chat.uploadResult('rejected')));
      }
      await tester.pump(const Duration(seconds: 1));
    }
  }, () => chat.client);
}

TextField _composer(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).last);

Future<TextEditingValue> _focusDraft(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).last, _draft);
  await tester.pumpAndSettle();
  expect(tester.testTextInput.hasAnyClients, isTrue);
  final value = _composer(tester).controller!.value;
  expect(value.text, contains('🙂'));
  return value;
}

Future<void> _pumpSteps(WidgetTester tester) async {
  // Pending scans display an indeterminate progress indicator, so they cannot
  // pumpAndSettle. Advance enough frames for transport and UI callbacks only.
  for (var step = 0; step < 20; step++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _until(WidgetTester tester, bool Function() complete) async {
  for (var step = 0; step < 200 && !complete(); step++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(complete(), isTrue,
      reason: 'IME media did not reach the expected stage');
}

Future<void> _commit(
  WidgetTester tester, {
  List<int>? bytes,
  String mimeType = 'image/png',
  String uri = 'content://keyboard.provider/untrusted-name.exe',
}) async {
  final client = tester.testTextInput.log
      .lastWhere((call) => call.method == 'TextInput.setClient');
  final clientId = (client.arguments as List).first as int;
  final completed = Completer<void>();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(MethodCall(
      'TextInputClient.performAction',
      [
        clientId,
        'TextInputAction.commitContent',
        {'mimeType': mimeType, 'uri': uri, 'data': bytes},
      ],
    )),
    (reply) {
      try {
        SystemChannels.textInput.codec.decodeEnvelope(reply!);
        completed.complete();
      } catch (error, stack) {
        completed.completeError(error, stack);
      }
    },
  );
  await completed.future;
}

void _expectUpload(_ImeChat chat,
    {String mimeType = 'image/png', String fileName = 'keyboard-image.png'}) {
  expect(chat.uploads, hasLength(1));
  final request = chat.uploads.single;
  final multipart = latin1.decode(request.bodyBytes);
  expect(request.headers['Authorization'], 'Bearer $_token');
  expect(
      multipart,
      contains(
          'name="${chat.group ? 'groupId' : 'toUserId'}"\r\n\r\n${chat.target}'));
  expect(multipart, contains('name="scanReport"\r\n\r\ntrue'));
  expect(multipart, contains('name="clientUploadId"'));
  expect(multipart, contains('filename="$fileName"'));
  expect(multipart.toLowerCase(), contains('content-type: $mimeType'));
  expect(multipart, isNot(contains('builtinExpression')));
  expect(multipart, isNot(contains('keyboard.provider')));
  expect(multipart, isNot(contains('name="text"')));
}

void _expectImageSend(_ImeChat chat, {String fileName = 'keyboard-image.png'}) {
  expect(chat.sends, hasLength(1));
  final sent = jsonDecode(chat.sends.single.body) as Map;
  expect(sent['fileType'], 'image');
  expect(sent['fileName'], fileName);
  expect(sent['fileUrl'], _fileUrl);
  expect(sent.containsKey('text'), isFalse);
  if (chat.group) {
    expect(chat.sends.single.url.path,
        endsWith('/groups/${chat.target}/messages'));
  } else {
    expect(sent['toUserId'], chat.target);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) return;
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  for (final group in [false, true]) {
    final kind = group ? 'group' : 'private';

    testWidgets(
        '$kind IME sends only after scan approval and guards duplicate content',
        (tester) async {
      final chat = _ImeChat(group: group)
        ..uploadGate = Completer<http.Response>();
      await _withChat(tester, chat, () async {
        final before = await _focusDraft(tester);
        expect(chat.uploads, isEmpty);
        expect(chat.sends, isEmpty);
        expect(tester.testTextInput.setClientArgs!['contentCommitMimeTypes'],
            ['image/png', 'image/jpeg', 'image/webp', 'image/gif']);
        await _commit(tester, bytes: _png);
        await _until(tester, () => chat.uploads.isNotEmpty);
        _expectUpload(chat);
        expect(chat.sends, isEmpty);
        expect(_composer(tester).controller!.value, before);
        expect(_composer(tester).focusNode!.hasFocus, isFalse);
        // A second keyboard insertion requires reopening the closed keyboard.
        await tester.showKeyboard(find.byType(TextField).last);
        await tester.pump();
        await _commit(tester, bytes: _png);
        await _pumpSteps(tester);
        expect(chat.uploads, hasLength(1));
        expect(chat.sends, isEmpty);
        expect(find.textContaining('התמונה הנוספת לא נשלחה'), findsOneWidget);
        chat.uploadGate!.complete(_json(chat.uploadResult()));
        await _until(tester, () => chat.sends.isNotEmpty);
        await _pumpSteps(tester);
        _expectImageSend(chat);
        expect(_composer(tester).controller!.value, before);
      });
    }, variant: _android);

    testWidgets(
        '$kind IME keeps GIF MIME and canonical filename through the scan upload',
        (tester) async {
      final chat = _ImeChat(group: group);
      await _withChat(tester, chat, () async {
        final before = await _focusDraft(tester);
        await _commit(tester, bytes: _gif, mimeType: 'image/gif');
        await _until(tester, () => chat.sends.isNotEmpty);
        await _pumpSteps(tester);
        _expectUpload(chat,
            mimeType: 'image/gif', fileName: 'keyboard-image.gif');
        _expectImageSend(chat, fileName: 'keyboard-image.gif');
        expect(_composer(tester).controller!.value, before);
      });
    }, variant: _android);

    for (final outcome in ['pending', 'rejected']) {
      testWidgets(
          '$kind IME $outcome result does not send or consume the draft',
          (tester) async {
        final chat = _ImeChat(group: group)..outcome = outcome;
        await _withChat(tester, chat, () async {
          final before = await _focusDraft(tester);
          await _commit(tester, bytes: _png);
          await _until(tester, () => chat.uploads.isNotEmpty);
          await _pumpSteps(tester);
          _expectUpload(chat);
          expect(chat.sends, isEmpty);
          expect(_composer(tester).controller!.value, before);
          if (outcome == 'rejected') {
            final notice = find.byType(BlockedImageNotice);
            expect(notice, findsOneWidget);
            expect(tester.widget<BlockedImageNotice>(notice).reason,
                'התמונה לא אושרה בסריקה');
          } else {
            expect(find.textContaining('keyboard-image.png'), findsWidgets);
          }
        });
      }, variant: _android);
    }

    for (final invalid in [
      'missing',
      'empty',
      'signature',
      'mismatch',
      'oversize'
    ]) {
      testWidgets(
          '$kind IME $invalid image is refused without fetching its URI',
          (tester) async {
        final chat = _ImeChat(group: group);
        await _withChat(tester, chat, () async {
          final before = await _focusDraft(tester);
          final List<int>? bytes = switch (invalid) {
            'missing' => null,
            'empty' => const [],
            'signature' => const [1, 2, 3, 4],
            'mismatch' => _png,
            'oversize' => Uint8List(maxKeyboardInsertedImageBytes + 1)
              ..setRange(0, 8, _png.take(8)),
            _ => throw StateError('Unknown fixture'),
          };
          await _commit(tester,
              bytes: bytes,
              mimeType: invalid == 'mismatch' ? 'image/jpeg' : 'image/png',
              uri: 'https://ime-source.invalid/untrusted-name.exe');
          await _pumpSteps(tester);
          expect(chat.uploads, isEmpty);
          expect(chat.sends, isEmpty);
          expect(
              chat.requests
                  .any((request) => request.url.host == 'ime-source.invalid'),
              isFalse);
          expect(_composer(tester).controller!.value, before);
          expect(find.textContaining('מהמקלדת'), findsOneWidget);
        });
      }, variant: _android);
    }

    testWidgets('$kind image filter disables the keyboard content capability',
        (tester) async {
      final chat = _ImeChat(group: group)..imagesAllowed = false;
      await _withChat(tester, chat, () async {
        await _focusDraft(tester);
        expect(_composer(tester).contentInsertionConfiguration, isNull);
        expect(tester.testTextInput.setClientArgs!['contentCommitMimeTypes'],
            isEmpty);
        expect(chat.uploads, isEmpty);
        expect(chat.sends, isEmpty);
      });
    }, variant: _android);

    testWidgets('$kind IME rechecks a changed image filter before uploading',
        (tester) async {
      final chat = _ImeChat(group: group);
      await _withChat(tester, chat, () async {
        final before = await _focusDraft(tester);
        expect(_composer(tester).contentInsertionConfiguration, isNotNull);
        chat.imagesAllowed = false;
        await _commit(tester, bytes: _png);
        await _pumpSteps(tester);
        expect(chat.uploads, isEmpty);
        expect(chat.sends, isEmpty);
        expect(_composer(tester).controller!.value, before);
        expect(_composer(tester).contentInsertionConfiguration, isNull);
      });
    }, variant: _android);

    testWidgets(
        '$kind IME approval after navigation sends to its captured original target',
        (tester) async {
      final chat = _ImeChat(group: group)
        ..uploadGate = Completer<http.Response>();
      await _withChat(tester, chat, () async {
        await _focusDraft(tester);
        await _commit(tester, bytes: _png);
        await _until(tester, () => chat.uploads.isNotEmpty);
        _expectUpload(chat);
        await tester.pumpWidget(chat.app('ime-other'));
        await tester.pumpAndSettle();
        final currentDraft = await _focusDraft(tester);
        expect(chat.sends, isEmpty);
        chat.uploadGate!.complete(_json(chat.uploadResult()));
        await _until(tester, () => chat.sends.isNotEmpty);
        await _pumpSteps(tester);
        _expectImageSend(chat);
        expect(_composer(tester).controller!.value, currentDraft);
      });
    }, variant: _android);
  }

  for (final restriction in ['admin-only', 'pending']) {
    testWidgets('group IME rechecks $restriction membership before upload',
        (tester) async {
      final chat = _ImeChat(group: true);
      await _withChat(tester, chat, () async {
        await _focusDraft(tester);
        final priorChecks = chat.requests
            .where((request) => request.url.path.endsWith('/groups'))
            .length;
        if (restriction == 'pending') {
          chat.groupStatus = 'pending';
        } else {
          chat.groupSendPermission = 'admin';
        }
        await _commit(tester, bytes: _png);
        await _pumpSteps(tester);
        expect(
            chat.requests
                .where((request) => request.url.path.endsWith('/groups'))
                .length,
            greaterThan(priorChecks));
        expect(chat.uploads, isEmpty);
        expect(chat.sends, isEmpty);
      });
    }, variant: _android);
  }
}
