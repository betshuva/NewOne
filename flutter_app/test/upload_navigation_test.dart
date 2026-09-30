import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:betshuva/main.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/attachment_picker.dart';
import 'own_media_filter_test.dart' as fixtures;

Widget conversation(bool group, String target) => MaterialApp(
      home: group
          ? GroupChatScreen(
              key: ValueKey(target),
              token: 'original-token',
              socket: null,
              me: {'id': 'viewer', 'name': 'אני'},
              group: {...fixtures.groupData, 'id': target},
              embedded: true,
            )
          : ChatScreen(
              key: ValueKey(target),
              token: 'original-token',
              socket: null,
              me: {'id': 'viewer', 'name': 'אני'},
              recipient: {'id': target, 'name': target},
              embedded: true,
            ),
    );

Future<void> until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue,
      reason: 'Background queue did not reach the next step');
}

void main() {
  FilePicker.platform = AttachmentPicker([]);
  for (final group in [false, true]) {
    testWidgets('oversized selection stops before confirmation or uploads group=$group',
        (tester) async {
      fixtures.size(tester);
      SharedPreferences.setMockInitialValues({});
      final originalPicker = FilePicker.platform;
      addTearDown(() => FilePicker.platform = originalPicker);
      final files = [for (var i = 0; i < 101; i++)
        MemoryPickedFile('file-$i.docx', Uint8List.fromList([80, 75]))];
      FilePicker.platform = AttachmentPicker(files);
      final writes = <String>[];
      await http.runWithClient(() async {
        await tester.pumpWidget(conversation(group, group ? 'group' : 'friend'));
        await tester.pumpAndSettle();
        writes.clear();
        await tester.tap(find.byIcon(Icons.attach_file));
        await tester.pumpAndSettle();
        await tester.tap(find.text('העלאת קבצים'));
        await tester.pumpAndSettle();
        expect(find.text('נבחרו 101 קבצים. ניתן להעלות עד 100 קבצים בכל פעם. הפעולה בוטלה.'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('מעלה 100 קבצים'), findsNothing);
        expect(writes, isEmpty);
        // The rejected selection must not lock the picker for the next attempt.
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        FilePicker.platform = AttachmentPicker(files.take(100).toList());
        await tester.tap(find.byIcon(Icons.attach_file));
        await tester.pumpAndSettle();
        await tester.tap(find.text('העלאת קבצים'));
        await tester.pumpAndSettle();
        expect(find.text('אתה עומד להעלות 100 קבצים. האם אתה בטוח?'), findsOneWidget);
        await tester.tap(find.text('ביטול'));
        await tester.pumpAndSettle();
        expect(writes, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }, () => MockClient((request) async {
        if (request.method != 'GET') writes.add(request.url.path);
        return fixtures.defaultResponse(request);
      }));
    });
    for (final scenario in [
      'images',
      'mixed',
      'non-approved',
      'all-failed',
      'before-first-upload'
    ]) {
      testWidgets('queue survives navigation group=$group scenario=$scenario',
          (tester) async {
        fixtures.size(tester);
        SharedPreferences.setMockInitialValues({});
        final images = scenario == 'images';
        final count = images ? 100 : 5;
        final completion = scenario == 'all-failed'
            ? 'סוף תור ההעלאה: 0 מתוך 5 הושלמו, 5 נכשלו'
            : scenario == 'non-approved'
                ? 'סוף תור ההעלאה: 4 מתוך 5 הושלמו, 1 נכשלו'
                : 'סוף העלאת $count קבצים';
        final target = group ? 'group' : 'friend';
        final other = group ? 'other-group' : 'other-friend';
        final originalPicker = FilePicker.platform;
        FilePicker.platform = AttachmentPicker([
          for (var i = 0; i < count; i++)
            MemoryPickedFile(
                'file-$i.${images || i.isEven ? 'png' : 'docx'}',
                images || i.isEven
                    ? fixtures.png
                    : Uint8List.fromList([80, 75])),
        ]);
        addTearDown(() => FilePicker.platform = originalPicker);
        final firstGate = Completer<void>();
        final lastGate = Completer<void>();
        final notices = <Map<String, dynamic>>[];
        final uploads = <String>[];
        final sends = <Map<String, dynamic>>[];
        final initialWait = scenario == 'before-first-upload';
        await http.runWithClient(() async {
          await tester.pumpWidget(conversation(group, target));
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          await tester.tap(find.text('העלאת קבצים'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('כן, העלה'));
          await until(tester,
              () => initialWait ? notices.isNotEmpty : uploads.isNotEmpty);
          expect(notices.map((n) => n['text']), ['מעלה $count קבצים']);
          // Changing the desktop selection disposes the original chat State.
          await tester.pumpWidget(conversation(group, other));
          await tester.pump(const Duration(milliseconds: 100));
          firstGate.complete();
          await until(tester, () => uploads.length == count);
          expect(notices.map((n) => n['text']), ['מעלה $count קבצים']);
          expect(find.text(completion), findsNothing);
          // Reopen before completion: this is a new State, and it must receive
          // the final persisted notice from the queue owned by the old State.
          await tester.pumpWidget(conversation(group, target));
          await tester.pumpAndSettle();
          expect(find.text('מעלה $count קבצים'), findsOneWidget);
          expect(find.text(completion), findsNothing);
          lastGate.complete();
          await until(tester, () => notices.length == 2);
          await tester.pumpAndSettle();
          expect(find.text(completion), findsOneWidget);
          expect(
              notices.map((n) => n['text']), ['מעלה $count קבצים', completion]);
          expect(
              notices.every((n) =>
                  n['target'] == target &&
                  n['kind'] == (group ? 'group' : 'personal')),
              isTrue);
          expect(uploads.toSet().length, count);
          expect(
              sends.length,
              scenario == 'all-failed'
                  ? 0
                  : scenario == 'non-approved'
                      ? count - 3
                      : count);
          expect(sends.map((m) => m['fileName']).toSet().length, sends.length);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
            () => MockClient((request) async {
                  final path = request.url.path;
                  if (path.endsWith('/upload-batch-notices')) {
                    if (request.method == 'GET') {
                      return fixtures.json(notices
                          .where((n) =>
                              n['target'] ==
                              request.url.queryParameters['target'])
                          .toList());
                    }
                    notices.add(Map<String, dynamic>.from(
                        jsonDecode(request.body) as Map));
                    if (initialWait && notices.length == 1) {
                      await firstGate.future;
                    }
                    return fixtures.json({'saved': true}, 201);
                  }
                  if (request.method == 'GET' &&
                      (path.endsWith('/messages') ||
                          path.contains('/messages/'))) {
                    return fixtures.json([]);
                  }
                  if (path.endsWith('/upload')) {
                    expect(request.headers['authorization'],
                        'Bearer original-token');
                    final body = latin1.decode(request.bodyBytes);
                    final name = RegExp(r'filename="([^"]+)"')
                        .firstMatch(body)!
                        .group(1)!;
                    final destination = RegExp(
                            'name="${group ? 'groupId' : 'toUserId'}"\r\n\r\n([^\r]+)')
                        .firstMatch(body)!
                        .group(1);
                    expect(destination, target);
                    final index = uploads.length;
                    uploads.add(name);
                    if (!initialWait && index < (images ? 2 : 1)) {
                      await firstGate.future;
                    }
                    if (index == count - 1) await lastGate.future;
                    if (scenario == 'all-failed') {
                      return fixtures.json({'error': 'test failure'}, 503);
                    }
                    if (scenario == 'non-approved' && index < 3) {
                      return fixtures.json({
                        'status': ['pending', 'rejected', 'failed'][index],
                        'url': '/uploads/$name',
                        'error': 'test failure'
                      }, index == 2 ? 503 : 200);
                    }
                    return fixtures.json({
                      'status': 'approved',
                      'url': '/uploads/$name',
                      'fileName': name
                    });
                  }
                  if (request.method == 'POST' && path.endsWith('/messages')) {
                    expect(request.headers['authorization'],
                        'Bearer original-token');
                    final body = Map<String, dynamic>.from(
                        jsonDecode(request.body) as Map);
                    if (group) {
                      expect(path, endsWith('/groups/$target/messages'));
                    } else {
                      expect(body['toUserId'], target);
                    }
                    sends.add(body);
                    return fixtures
                        .json({'id': 'sent-${sends.length}', 'status': 'sent'});
                  }
                  return fixtures.defaultResponse(request);
                }));
      });
    }
  }
}
