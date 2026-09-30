import 'dart:async';
import 'package:flutter/material.dart';
import 'package:betshuva/chat_upload_batch.dart';
import 'package:betshuva/chat_upload_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'more than two files require confirmation and cancel uploads nothing',
      (tester) async {
    var uploads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                  body: Column(children: [
                    for (final count in [2, 3])
                      TextButton(
                          onPressed: () async {
                            if (await confirmChatUploadBatch(context, count)) {
                              uploads += count;
                            }
                          },
                          child: Text('select-$count'))
                  ]),
                ))));
    await tester.tap(find.text('select-2'));
    await tester.pumpAndSettle();
    expect(uploads, 2);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('select-3'));
    await tester.pumpAndSettle();
    expect(find.text('אתה עומד להעלות 3 קבצים. האם אתה בטוח?'), findsOneWidget);
    expect(uploads, 2);
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(uploads, 2);
    await tester.tap(find.text('select-3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('כן, העלה'));
    await tester.pumpAndSettle();
    expect(uploads, 5);
  });
  test('completion appears only after the entire batch finishes', () async {
    final notices = <String>[];
    final gate = Completer<void>();
    final work = runChatUploadBatch(
        count: 100, onNotice: notices.add, upload: () => gate.future);
    expect(notices, ['מעלה 100 קבצים']);
    gate.complete();
    await work;
    expect(notices, ['מעלה 100 קבצים', 'סוף העלאת 100 קבצים']);
  });

  test('partial and total failures do not claim a successful batch', () async {
    for (final failed in [1, 3]) {
      final notices = <String>[];
      await runChatUploadBatch(
          count: 3,
          onNotice: notices.add,
          upload: () async {},
          failedCount: () => failed);
      expect(notices, [
        'מעלה 3 קבצים',
        'סוף תור ההעלאה: ${3 - failed} מתוך 3 הושלמו, $failed נכשלו'
      ]);
      expect(notices, isNot(contains('סוף העלאת 3 קבצים')));
    }
  });

  test('an interrupted batch does not claim completion', () async {
    final notices = <String>[];
    await expectLater(
        runChatUploadBatch(
            count: 30,
            onNotice: notices.add,
            upload: () async => throw StateError('interrupted')),
        throwsStateError);
    expect(notices, ['מעלה 30 קבצים', 'העלאת 30 קבצים הופסקה']);
  });

  test('refresh retains distinct batch boundaries in chronological order', () {
    Map<String, dynamic> notice(String id, int second) => {
          'id': id,
          'isUploadBatchNotice': true,
          'text': 'מעלה 100 קבצים',
          'createdAt':
              DateTime.utc(2026, 9, 29, 12, 0, second).toIso8601String(),
        };
    final start = notice('start', 1);
    final end = notice('end', 3);
    final file = {
      'id': 'file',
      'createdAt': DateTime.utc(2026, 9, 29, 12, 0, 2).toIso8601String()
    };
    expect(mergeChatUploadHistory([file], [start, end], matchLegacyText: true),
        [start, file, end]);
    expect(mergeChatUploadHistory([start, file, end], [start, end]),
        [start, file, end]);
  });
}
