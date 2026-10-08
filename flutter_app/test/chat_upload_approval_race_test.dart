import 'dart:async';
import 'dart:convert';

import 'package:betshuva/filter_history.dart';
import 'package:betshuva/chat_upload_history.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as video;

import 'helpers/attachment_picker.dart';
import 'helpers/chat_upload_picker_browser.dart';
import 'helpers/listing_upload_browser.dart';
import 'own_media_filter_test.dart' as fixtures;

class _VideoProbe extends video.VideoPlayerPlatform {
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(video.VideoCreationOptions options) async => 1;
  @override
  Stream<video.VideoEvent> videoEventsFor(int id) =>
      Stream.error(PlatformException(
          code: 'diagnostic-decoder-unavailable',
          message: 'No real video decoder needed'));
  @override
  Future<void> dispose(int id) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FilePicker.platform = AttachmentPicker([]);
  test('resolved history replaces uploading progress and cannot be downgraded',
      () {
    final upload = {
      'id': 'uploading_a',
      'clientUploadId': 'a',
      'status': 'uploading',
      'fileName': 'same.mp4'
    };
    for (final status in [
      'sent',
      'received',
      'delivered',
      'read',
      'scan_approved',
      'rejected_scan',
      'stopped_scan',
      'awaiting_contact_approval',
      'rejected_request'
    ]) {
      final saved = {
        'id': 'server_a',
        'clientUploadId': 'a',
        'status': status,
        'filterHidden': true,
        'fileUrl': null
      };
      expect(mergeChatUploadHistory([saved], [upload]), [saved]);
      expect(
          hasResolvedChatUpload(
              [saved], {...upload, 'fileUrl': '/uploads/a.mp4'}),
          isTrue);
      expect(saved['fileUrl'], isNull);
    }
  });
  test(
      'unchanged history reconciles stale pending state even on a real message ID',
      () {
    final saved = {
      'id': 'real-message',
      'clientUploadId': 'a',
      'status': 'read',
      'fileUrl': '/uploads/a.mp4',
      'filterHidden': false
    };
    final stale = {...saved, 'status': 'pending_scan'};
    expect(chatUploadHistoryNeedsReconciliation([saved], [stale]), isTrue);
    expect(mergeChatUploadHistory([saved], [stale]), [saved]);
    expect(chatUploadHistoryNeedsReconciliation([saved], [saved]), isFalse);
  });
  test(
      'true pending scans retain upload progress and reconcile late temporary rows',
      () {
    final uploading = {
      'id': 'uploading_a',
      'clientUploadId': 'a',
      'status': 'uploading'
    };
    final scan = {
      'id': 'scan_a',
      'clientUploadId': 'a',
      'status': 'pending_scan',
      'moderationStatus': 'pending',
      'filterHidden': true,
      'fileUrl': null
    };
    expect(hasResolvedChatUpload([scan], uploading), isFalse);
    expect(mergeChatUploadHistory([scan], [uploading]), [uploading]);
    expect(chatUploadHistoryNeedsReconciliation([scan], [uploading]), isFalse);
    final pending = {
      ...uploading,
      'id': 'temp_a',
      'status': 'pending_scan',
      'fileUrl': '/uploads/a.mp4'
    };
    expect(chatUploadHistoryNeedsReconciliation([scan], [pending]), isTrue);
    expect(mergeChatUploadHistory([scan], [pending]), [scan]);
    expect(chatUploadHistoryNeedsReconciliation([scan], [scan]), isFalse);
  });
  test(
      'request identity wins over legacy URLs and never merges conflicting IDs or names',
      () {
    final history = [
      {'id': 'legacy', 'status': 'read', 'fileUrl': '/uploads/same.mp4'},
      {
        'id': 'scan_a',
        'clientUploadId': 'a',
        'status': 'pending_scan',
        'fileUrl': null
      },
      {
        'id': 'sent_b',
        'clientUploadId': 'b',
        'status': 'read',
        'fileUrl': '/uploads/same.mp4'
      },
    ];
    final upload = {'clientUploadId': 'a', 'fileUrl': '/uploads/same.mp4'};
    expect(chatUploadIndex(history, upload), 1);
    expect(hasResolvedChatUpload(history, upload), isFalse);
    expect(chatUploadIndex([history.last], upload), -1);
    expect(
        chatUploadIndex([history.last], {'fileUrl': '/uploads/same.mp4'}), 0);
    expect(
        chatUploadIndex(history,
            {'clientUploadId': '', 'fileUrl': null, 'fileName': 'same.mp4'}),
        -1);
    final other = {
      'id': 'temp_a',
      'clientUploadId': 'a',
      'status': 'pending_scan',
      'fileUrl': '/uploads/same.mp4'
    };
    expect(
        mergeChatUploadHistory([history.last], [other]), [history.last, other]);
  });
  for (final group in [false, true]) {
    for (final hidden in [false, true]) {
      testWidgets(
          'late pending video response preserves approval through unchanged polls group=$group hidden=$hidden',
          (tester) async {
        fixtures.size(tester);
        SharedPreferences.setMockInitialValues({});
        final previousVideo = video.VideoPlayerPlatform.instance;
        video.VideoPlayerPlatform.instance = _VideoProbe();
        addTearDown(() => video.VideoPlayerPlatform.instance = previousVideo);
        final previousPicker = FilePicker.platform;
        FilePicker.platform = AttachmentPicker(
            [MemoryPickedFile('race-video.mp4', fixtures.png)]);
        addTearDown(() => FilePicker.platform = previousPicker);
        final socket = io.io('http://localhost:1',
            io.OptionBuilder().disableAutoConnect().enableForceNew().build());
        addTearDown(() {
          socket.connected = false;
          socket.dispose();
        });
        final uploadResponse = Completer<http.Response>();
        final browser = ListingUploadBrowser();
        final pickerBrowser = ChatUploadPickerBrowser();
        const pendingResponse = {
          'status': 'pending',
          'fileType': 'video',
          'url': '/uploads/diagnostic-race-video.mp4',
          'fileName': 'race-video.mp4'
        };
        if (kIsWeb) {
          browser.install();
          browser.failOnce('race-video.mp4', 200, pendingResponse);
          pickerBrowser.install('race-video.mp4', fixtures.png);
          addTearDown(browser.dispose);
          addTearDown(pickerBrowser.dispose);
        }
        var clientId = '';
        var historyReads = 0;
        var authoritativeApproved = false;
        var attemptedSends = 0;
        final visualRequests = <Uri>[];
        const fileUrl = '/uploads/diagnostic-race-video.mp4';
        final createdAt = DateTime.now().toUtc().toIso8601String();
        List<Map<String, dynamic>> history() => [
              {
                'id': 'diagnostic-baseline',
                'sender_id': 'friend',
                'sender_name': 'חבר',
                'type': 'text',
                'body': 'היסטוריה קודמת לבדיקה',
                'is_read': true,
                'created_at': createdAt
              },
              if (authoritativeApproved)
                {
                  'id': 'diagnostic-approved',
                  'sender_id': 'viewer',
                  'sender_name': 'אני',
                  'type': 'video',
                  'client_upload_id': clientId,
                  'file_url': hidden ? null : fileUrl,
                  'file_name': hidden ? null : 'race-video.mp4',
                  'body': hidden ? null : 'race-video.mp4',
                  'filter_hidden': hidden,
                  if (hidden) 'hidden_reason': 'content_filter',
                  'moderation_status': 'approved',
                  'message_status': 'read',
                  'image_classification': {
                    'category': 'video',
                    'uncertain': false
                  },
                  'created_at': createdAt
                },
            ];
        Future<void> tick() async {
          for (var i = 0; i < 12; i++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)));
            await tester.pump(const Duration(milliseconds: 100));
          }
        }

        await http.runWithClient(() async {
          await tester.pumpWidget(fixtures.chat(group, socket: socket));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          await tester.tap(find.text('העלאת קבצים'));
          await tick();
          if (kIsWeb) {
            for (var attempt = 0;
                attempt < 30 && browser.records.isEmpty;
                attempt++) {
              await tick();
            }
            expect(pickerBrowser.selections, 1);
            expect(browser.records, hasLength(1));
            clientId = browser.records.single['meta']['fields']
                ['clientUploadId'] as String;
          }
          expect(clientId, isNotEmpty);
          expect(uploadResponse.isCompleted, isFalse);
          expect(find.byType(LinearProgressIndicator), findsOneWidget);

          // The queue has delivered the file and history confirms approval while
          // the earlier upload response is still travelling to this client.
          authoritativeApproved = true;
          if (!hidden) {
            socket.connected = true;
            socket.onevent({
              'data': [
                group ? 'group:message' : 'chat:message',
                {
                  'id': 'diagnostic-approved',
                  'fromUserId': 'viewer',
                  'toUserId': group ? null : 'friend',
                  'groupId': group ? 'group' : null,
                  'fileType': 'video',
                  'fileUrl': fileUrl,
                  'fileName': 'race-video.mp4',
                }
              ]
            });
            socket.connected = false;
          } else {
            // A missing sender socket event must be repaired by history polling.
            await tester.pump(const Duration(seconds: 4));
          }
          await tick();
          expect(historyReads, greaterThan(1));
          expect(find.byType(LinearProgressIndicator), findsNothing,
              reason:
                  'Authoritative history finishes the local upload progress');
          if (hidden) expect(find.byType(FilterHiddenImage), findsOneWidget);

          // The stale response must not be interpreted as a new server scan.
          if (kIsWeb)
            browser.complete('race-video.mp4');
          else
            uploadResponse.complete(fixtures.json(pendingResponse));
          await tick();
          expect(find.text('סורק את הווידאו'), findsNothing);
          final beforePolls = historyReads;
          for (var poll = 0; poll < 2; poll++) {
            await tester.pump(const Duration(seconds: 4));
            await tick();
            expect(historyReads, greaterThan(beforePolls + poll));
            expect(find.text('סורק את הווידאו'), findsNothing,
                reason:
                    'A stale upload response cannot undo authoritative approval');
            expect(find.byType(LinearProgressIndicator), findsNothing);
          }
          expect(attemptedSends, 0,
              reason: 'The acknowledgement never resends or rescans the video');
          // Control: an explicit policy refresh invalidates the fingerprint and
          // reconciles exactly the same approved history, removing the ghost.
          receivingFilterChanges.add('token');
          await tick();
          expect(find.text('סורק את הווידאו'), findsNothing);
          expect(attemptedSends, 0);
          if (hidden) {
            expect(find.byType(FilterHiddenImage), findsOneWidget);
            expect(visualRequests, isEmpty,
                reason:
                    'The stale upload URL cannot bypass authoritative hiding');
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull);
        },
            () => MockClient((request) async {
                  if (fixtures.isHistory(request, group)) {
                    historyReads++;
                    return fixtures.json(history());
                  }
                  if (request.url.path.contains('diagnostic-race-video')) {
                    visualRequests.add(request.url);
                  }
                  if (request.url.path.endsWith('/upload')) {
                    clientId = RegExp(r'name="clientUploadId"\r\n\r\n([^\r]+)')
                            .firstMatch(latin1.decode(request.bodyBytes))
                            ?.group(1) ??
                        '';
                    return uploadResponse.future;
                  }
                  if (request.method == 'POST' &&
                      request.url.path.endsWith('/messages')) attemptedSends++;
                  return fixtures.defaultResponse(request);
                }));
      });
    }
  }
}
