import 'dart:async';
import 'package:flutter/material.dart';
import 'package:betshuva/chat_upload_batch.dart';
import 'package:betshuva/chat_upload_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('batch summary follows outcomes and ignores unrelated same-name files', () {
    final notice = <String, dynamic>{'id': 'end', 'isUploadBatchNotice': true,
      'text': 'סוף העלאת 3 קבצים', 'uploadIds': ['a', 'b', 'c']};
    final rows = <Map<String, dynamic>>[
      {'id': 'sent-a', 'clientUploadId': 'a', 'status': 'sent'},
      {'id': 'scan-b', 'clientUploadId': 'b', 'status': 'pending_scan'},
      {'id': 'scan-c', 'clientUploadId': 'c', 'status': 'stopped_scan'},
      {'id': 'other', 'status': 'sent', 'fileName': 'same.mp4'},
    ];
    expect(chatUploadBatchSummary(notice, rows), isNull);
    rows[1]['status'] = 'rejected_scan';
    expect(chatUploadBatchSummary(notice, rows), 'סיכום: נשלחו 1 · נחסמו 2');
    expect(chatUploadBatchSummary(notice, [rows.first]), isNull);
    expect(chatUploadBatchSummary({...notice, 'text': 'מעלה 3 קבצים'}, rows), isNull);
  });

  test('batch summary counts each upload once and includes known failures', () {
    final notice = <String, dynamic>{'text': 'סוף העלאת 2 קבצים',
      'uploadIds': ['a', 'b'], 'messageIds': ['sent-a']};
    final sent = <String, dynamic>{'id': 'sent-a', 'clientUploadId': 'a', 'status': 'sent'};
    expect(chatUploadBatchSummary(notice, [sent, sent,
      {'id': 'b', 'clientUploadId': 'b', 'status': 'failed'}]),
        'סיכום: נשלחו 1 · נחסמו 0 · נכשלו בהעלאה 1');
  });

  test('persisted upload failures count without rows but outstanding scans still hide the summary', () {
    final notice = <String,dynamic>{'text':'סוף תור ההעלאה: 1 מתוך 2 הושלמו, 1 נכשלו',
      'uploadIds':['a','b']};
    for (final status in ['uploading','pending_scan','sending','awaiting_contact_approval']) {
      expect(chatUploadBatchSummary(notice,[{'clientUploadId':'a','status':status}]),isNull);
    }
    expect(chatUploadBatchSummary(notice,[{'clientUploadId':'a','status':'sent'}]),
      'סיכום: נשלחו 1 · נחסמו 0 · נכשלו בהעלאה 1');
    expect(chatUploadBatchSummary(notice,[{'clientUploadId':'a','status':'stopped_scan'},
      {'clientUploadId':'b','status':'failed'}]),
      'סיכום: נשלחו 0 · נחסמו 1 · נכשלו בהעלאה 1');
    expect(chatUploadBatchSummary({...notice,'text':'סוף תור ההעלאה: 0 מתוך 2 הושלמו, 2 נכשלו'},[]),
      'סיכום: נשלחו 0 · נחסמו 0 · נכשלו בהעלאה 2');
  });

  testWidgets('only the final orange summary appears after processing completes', (tester) async {
    const text='סוף העלאת 2 קבצים';
    await tester.pumpWidget(const MaterialApp(home:ChatUploadBatchNotice(text:text)));
    expect(find.text(text),findsNothing);
    expect(find.byType(Text),findsNothing);
    const summary='סיכום: נשלחו 1 · נחסמו 1';
    await tester.pumpWidget(const MaterialApp(home:ChatUploadBatchNotice(text:text,summary:summary)));
    expect(find.text(text),findsNothing);
    expect(find.text(summary),findsOneWidget);
    expect(tester.widget<Text>(find.text(summary)).style?.color,const Color(0xFFFFB74D));
  });

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

  test('completion follows the last batch member despite late server timestamps', () {
    final end = <String, dynamic>{'id':'end','isUploadBatchNotice':true,
      'text':'סוף העלאת 2 קבצים','createdAt':'2026-10-01T12:00:02Z',
      'uploadIds':['a','b'],'messageIds':['sent-a']};
    final first = <String, dynamic>{'id':'sent-a','createdAt':'2026-10-01T12:00:01Z'};
    final last = <String, dynamic>{'id':'scan-b','clientUploadId':'b',
      'status':'pending_scan','createdAt':'2026-10-01T12:01:00Z'};
    final other = <String, dynamic>{'id':'unrelated','createdAt':'2026-10-01T12:02:00Z'};
    expect(mergeChatUploadHistory([first,last,other],[end]),[first,last,end,other]);
    expect(mergeChatUploadHistory([first,end,last,other],[]),[first,last,end,other]);
    final delivered = {...last,'id':'sent-b','status':'sent'};
    expect(mergeChatUploadHistory([first,delivered,other],[end]),[first,delivered,end,other]);
    final rejected = {...last,'fileName':null,'fileUrl':null,'status':'rejected_scan'};
    expect(mergeChatUploadHistory([first,rejected],[end]),[first,rejected,end]);
  });

  test('legacy completion uses request timestamps only for an entire identifiable batch', () {
    final start=<String,dynamic>{'id':'start','isUploadBatchNotice':true,
      'text':'מעלה 2 קבצים','createdAt':'2026-10-01T12:00:00Z'};
    final end=<String,dynamic>{'id':'end','isUploadBatchNotice':true,
      'text':'סוף העלאת 2 קבצים','createdAt':'2026-10-01T12:00:05Z'};
    Map<String,dynamic> file(int second)=>{'id':'file-$second',
      'clientUploadId':'uploading_group_${DateTime.utc(2026,10,1,12,0,second).microsecondsSinceEpoch}_1',
      'createdAt':'2026-10-01T12:01:00Z'};
    final a=file(1),b=file(2),unrelated=file(10);
    expect(mergeChatUploadHistory([a,b,unrelated],[start,end]),[start,a,b,end,unrelated]);
    expect(mergeChatUploadHistory([b,unrelated],[start,end]),[start,end,b,unrelated]);
  });
}
