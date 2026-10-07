import 'dart:async';
import 'dart:convert';
import 'package:betshuva/chat_upload_history.dart';
import 'package:betshuva/filter_history.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    as video;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/attachment_picker.dart';
import 'own_media_filter_test.dart' as fixtures;

class _VideoProbe extends video.VideoPlayerPlatform {
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(video.VideoCreationOptions options) async => 1;
  @override
  Stream<video.VideoEvent> videoEventsFor(int id) =>
      Stream.error(PlatformException(
          code: 'test-decoder-unavailable',
          message: 'Test decoder unavailable'));
  @override
  Future<void> dispose(int id) async {}
}

void main() {
  FilePicker.platform = AttachmentPicker([]);
  test('request identity merges redacted scans without merging same-name files',
      () {
    final first = {
      'id': 'uploading_a',
      'clientUploadId': 'a',
      'status': 'uploading',
      'fileName': 'same.mp4'
    };
    final second = {
      'id': 'uploading_b',
      'clientUploadId': 'b',
      'status': 'uploading',
      'fileName': 'same.mp4'
    };
    final scan = {
      'id': 'scan_a',
      'clientUploadId': 'a',
      'status': 'pending_scan',
      'filterHidden': true
    };
    expect(mergeChatUploadHistory([scan], [first, second]), [first, second]);
    final pending = {...first, 'id': 'temp_a', 'status': 'pending_scan'};
    expect(mergeChatUploadHistory([scan], [pending, second]), [scan, second]);
    expect(mergeChatUploadHistory([scan], []), [scan]);
    expect(mergeChatUploadHistory([scan], [second]), [scan, second]);
    final sentText = {'id': 'saved', 'text': 'same'};
    final pendingText = {'id': 'temp_text', 'text': 'same'};
    expect(mergeChatUploadHistory([sentText], [pendingText]),
        [sentText, pendingText]);
    expect(
        mergeChatUploadHistory([sentText], [pendingText],
            matchLegacyText: true),
        [sentText]);
    expect(isPendingOwnUpload(scan), isTrue);
    expect(
        isPendingOwnUpload({...scan, 'moderationStatus': 'rejected'}), isFalse);
    expect(isPendingOwnUpload({...scan, 'contentPurged': true}), isFalse);
    expect(isPendingOwnUpload({...scan, 'id': 'delivered-message'}), isFalse);
  });

  for (final group in [false, true]) {
    testWidgets('batch completion remains below all three pending videos after refresh group=$group', (tester) async {
      fixtures.size(tester);
      final previousVideo = video.VideoPlayerPlatform.instance;
      video.VideoPlayerPlatform.instance = _VideoProbe();
      addTearDown(() => video.VideoPlayerPlatform.instance = previousVideo);
      SharedPreferences.setMockInitialValues({});
      final previous = FilePicker.platform;
      FilePicker.platform = AttachmentPicker(List.generate(3,
          (i) => MemoryPickedFile('video-$i.mp4', fixtures.png)));
      addTearDown(() => FilePicker.platform = previous);
      final scans = <Map<String, dynamic>>[];
      Future<void> tick() async {
        for (var i=0;i<20;i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds:10)));
          await tester.pump(const Duration(milliseconds:100));
        }
      }
      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(group));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.attach_file));
        await tester.pumpAndSettle();
        await tester.tap(find.text('העלאת קבצים'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('כן, העלה'));
        await tick();
        expect(scans.length,3);
        receivingFilterChanges.add('token');
        await tick();
        final end=find.text('סוף העלאת 3 קבצים');
        expect(end,findsNothing);
        final cards=find.text('סורק את הווידאו');
        expect(cards,findsNWidgets(3));
        expect(find.textContaining('סיכום:'), findsNothing);
        for (final scan in scans.take(2)) {
          scan['moderation_status'] = 'stopped';
          scan['scan_stopped'] = true;
        }
        receivingFilterChanges.add('token');
        await tick();
        expect(find.textContaining('סיכום:'), findsNothing);
        scans.last['moderation_status']='stopped';
        scans.last['scan_stopped']=true;
        receivingFilterChanges.add('token');
        await tick();
        final summary=find.text('סיכום: נשלחו 0 · נחסמו 3');
        expect(summary, findsOneWidget);
        expect(end,findsNothing);
        expect(tester.widget<Text>(summary).style?.color,const Color(0xFFFFB74D));
        final blocked=find.text('הסירטון נחסם');
        expect(blocked,findsNWidgets(3));
        for(var i=0;i<3;i++) {
          expect(tester.getTopLeft(summary).dy,greaterThan(tester.getBottomLeft(blocked.at(i)).dy));
        }
        expect(find.textContaining('עדיין בטיפול'), findsNothing);
        expect(tester.takeException(),isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },()=>MockClient((request) async {
        if(fixtures.isHistory(request,group))return fixtures.json(scans);
        if(request.url.path.endsWith('/upload')) {
          final clientId=RegExp(r'name="clientUploadId"\r\n\r\n([^\r]+)').firstMatch(latin1.decode(request.bodyBytes))!.group(1)!;
          final index=scans.length;
          scans.add({'id':'scan_$index','sender_id':'viewer','sender_name':'אני',
            'type':'video','client_upload_id':clientId,'message_status':'pending_scan',
            'moderation_status':'pending','filter_hidden':true,'hidden_reason':'moderation',
            'created_at':DateTime.now().add(const Duration(minutes:5)).toUtc().toIso8601String()});
          return fixtures.json({'status':'pending','fileType':'video','url':'/uploads/$index.mp4','fileName':'video-$index.mp4'});
        }
        return fixtures.defaultResponse(request);
      }));
    });
    testWidgets(
        'video upload stays one progress card across history refresh group=$group',
        (tester) async {
      fixtures.size(tester);
      final previousVideo = video.VideoPlayerPlatform.instance;
      video.VideoPlayerPlatform.instance = _VideoProbe();
      addTearDown(() => video.VideoPlayerPlatform.instance = previousVideo);
      SharedPreferences.setMockInitialValues({});
      final previous = FilePicker.platform;
      FilePicker.platform =
          AttachmentPicker([MemoryPickedFile('same.mp4', fixtures.png)]);
      addTearDown(() => FilePicker.platform = previous);
      final upload = Completer<http.Response>();
      var clientId = '';
      var showScan = false;
      var historyCalls = 0;
      final scan = <String, dynamic>{
        'id': 'scan_11111111-1111-4111-8111-111111111111',
        'sender_id': 'viewer',
        'sender_name': 'אני',
        'type': 'video',
        'message_status': 'pending_scan',
        'moderation_status': 'pending',
        'filter_hidden': true,
        'hidden_reason': 'moderation',
        'file_url': null,
        'file_name': null,
        'body': null,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };
      Future<void> tick() async {
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)));
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(group));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.attach_file));
        await tester.pumpAndSettle();
        await tester.tap(find.text('העלאת קבצים'));
        await tick();
        expect(clientId, isNotEmpty);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        final before = historyCalls;
        showScan = true;
        receivingFilterChanges.add('token');
        await tick();
        expect(historyCalls, greaterThan(before));
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.text('הקובץ ממתין לסריקה ולאישור'), findsNothing);
        upload.complete(fixtures.json({
          'status': 'pending',
          'fileType': 'video',
          'url': '/uploads/same.mp4',
          'fileName': 'same.mp4'
        }));
        await tick();
        receivingFilterChanges.add('token');
        await tick();
        expect(find.text('סורק את הווידאו'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.byType(FilterHiddenImage), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(fixtures.chat(group));
        await tick();
        expect(find.text('סורק את הווידאו'), findsOneWidget);
        expect(find.byType(FilterHiddenImage), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
          () => MockClient((request) async {
                if (fixtures.isHistory(request, group)) {
                  historyCalls++;
                  return fixtures.json(showScan
                      ? [
                          {...scan, 'client_upload_id': clientId}
                        ]
                      : []);
                }
                if (request.url.path.endsWith('/upload')) {
                  clientId = RegExp(r'name="clientUploadId"\r\n\r\n([^\r]+)')
                          .firstMatch(latin1.decode(request.bodyBytes))
                          ?.group(1) ??
                      '';
                  return upload.future;
                }
                return fixtures.defaultResponse(request);
              }));
    });
  }
}
