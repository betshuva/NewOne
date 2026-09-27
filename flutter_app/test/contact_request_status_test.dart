import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/contact_request_status.dart';

void main() {
  test('history preserves pending and rejected contact request states', () {
    expect(contactRequestStatus('awaiting_contact_approval'), 'awaiting_contact_approval');
    expect(contactRequestStatus('rejected_request'), 'rejected_request');
    expect(contactRequestStatus('sent'), isNull);
  });
  testWidgets('waiting is conditional on recipient choice; rejection states exact reason', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ContactRequestStatusBanner(status: 'awaiting_contact_approval'))));
    expect(find.textContaining('טרם נשלח'), findsOneWidget);
    expect(find.textContaining('רק אם הנמען יתיר'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ContactRequestStatusBanner(status: 'rejected_request', reason: 'סרטונים חסומים בהגדרות הנמען'))));
    expect(find.text('לא נשלח — סרטונים חסומים בהגדרות הנמען'), findsOneWidget);
    expect(find.textContaining('ממתין'), findsNothing);
  });
}
