import 'dart:convert';

import 'package:betshuva/guide_message_draft.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _contacts = [
  {'id': 'first', 'name': 'נאור', 'phone': '0500000001'},
  {'id': 'second', 'name': 'נאור', 'phone': '0500000002'},
  {'id': 'third', 'name': 'אורי', 'phone': '0500000003'},
];

class _DraftApi {
  final List<Map<String, String>> contacts;
  final bool sent;
  final writes = <Map<String, dynamic>>[];
  int recipientReads = 0;

  _DraftApi({this.contacts = _contacts, this.sent = false});

  late final client = MockClient((request) async {
    dynamic value;
    if (request.method == 'POST') {
      writes.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
      value = {'id': 'sent'};
    } else if (request.url.path.endsWith('/guide-message-recipients')) {
      recipientReads++;
      value = contacts;
    } else {
      value = {'sent': sent};
    }
    return http.Response(jsonEncode(value), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });

  Widget app({
    String id = 'draft',
    String query = 'נאור',
    String text = 'שלום',
    double? cardWidth,
  }) {
    return MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: cardWidth,
              child: GuideMessageDraftCard(
                key: ValueKey(id),
                api: 'https://example.test/api',
                token: 'token',
                messageId: id,
                client: client,
                draft: {'recipientQuery': query, 'text': text},
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Finder get _confirm => find.widgetWithText(FilledButton, 'אישור ושליחה');
Finder get _search => find.widgetWithText(TextField, 'חיפוש איש קשר שמור');
Finder get _message => find.widgetWithText(TextField, 'תוכן ההודעה שתישלח');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a unique recipient can be sent with one inline confirmation',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _DraftApi();
    addTearDown(api.client.close);
    await tester.pumpWidget(api.app(query: 'אורי', cardWidth: 240));
    await tester.pumpAndSettle();

    expect(api.recipientReads, 1);
    expect(api.writes, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('בחירת נמען ועריכת הטיוטה'), findsNothing);
    expect(_search, findsOneWidget);
    expect(_message, findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, '0500000003'))
            .selected,
        isTrue);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);

    await tester.ensureVisible(_confirm);
    await tester.tap(_confirm);
    await tester.pumpAndSettle();

    expect(api.writes, [
      {'toUserId': 'third', 'text': 'שלום', 'confirmed': true}
    ]);
    expect(find.text('ההודעה נשלחה'), findsOneWidget);
    expect(_confirm, findsNothing);
  });

  testWidgets(
      'ambiguous names require selection and edits stay in the same card',
      (tester) async {
    final api = _DraftApi();
    addTearDown(api.client.close);
    await tester.pumpWidget(api.app());
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
    await tester.tap(find.widgetWithText(ListTile, '0500000002'));
    await tester.pumpAndSettle();
    await tester.enterText(_message, 'ניפגש מחר');
    await tester.pumpAndSettle();

    expect(api.writes, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);
    await tester.ensureVisible(_confirm);
    await tester.tap(_confirm);
    await tester.pumpAndSettle();

    expect(api.writes, [
      {'toUserId': 'second', 'text': 'ניפגש מחר', 'confirmed': true}
    ]);
    expect(find.text('ההודעה נשלחה'), findsOneWidget);
  });

  testWidgets('changing search clears stale recipients before resolving again',
      (tester) async {
    final api = _DraftApi();
    addTearDown(api.client.close);
    await tester.pumpWidget(api.app(query: 'אורי'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);

    await tester.enterText(_search, 'נאור');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
    expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .any((t) => t.selected),
        isFalse);

    await tester.tap(find.widgetWithText(ListTile, '0500000002'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);

    await tester.enterText(_search, 'אין התאמה');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
    expect(find.byType(ListTile), findsNothing);

    await tester.enterText(_search, '0500000001');
    await tester.pumpAndSettle();
    expect(api.writes, isEmpty);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);
    await tester.ensureVisible(_confirm);
    await tester.tap(_confirm);
    await tester.pumpAndSettle();

    expect(api.writes, [
      {'toUserId': 'first', 'text': 'שלום', 'confirmed': true}
    ]);
  });

  testWidgets('an empty recipient query does not select even a single contact',
      (tester) async {
    final api = _DraftApi(contacts: [_contacts.first]);
    addTearDown(api.client.close);
    await tester.pumpWidget(api.app(query: ''));
    await tester.pumpAndSettle();

    expect(tester.widget<ListTile>(find.byType(ListTile)).selected, isFalse);
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
    expect(api.writes, isEmpty);

    await tester.tap(find.widgetWithText(ListTile, '0500000001'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);

    await tester.enterText(_search, '   ');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
    expect(api.writes, isEmpty);
  });

  testWidgets('empty edited text cannot be sent even with a unique recipient',
      (tester) async {
    final api = _DraftApi();
    addTearDown(api.client.close);
    await tester.pumpWidget(api.app(query: 'אורי'));
    await tester.pumpAndSettle();

    await tester.enterText(_message, '   ');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
    expect(api.writes, isEmpty);
  });

  testWidgets(
      'cancel never sends and remains cancelled after restoring the card',
      (tester) async {
    final api = _DraftApi();
    addTearDown(api.client.close);
    await tester.pumpWidget(api.app(query: 'אורי'));
    await tester.pumpAndSettle();

    final cancel = find.widgetWithText(TextButton, 'ביטול');
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(api.writes, isEmpty);
    expect(find.text('הטיוטה בוטלה'), findsOneWidget);
    expect(_confirm, findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(api.app(query: 'אורי'));
    await tester.pumpAndSettle();
    expect(find.text('הטיוטה בוטלה'), findsOneWidget);
    expect(_confirm, findsNothing);
    expect(api.writes, isEmpty);
  });

  testWidgets('sent restoration needs no recipient list or send action',
      (tester) async {
    final api = _DraftApi(sent: true);
    addTearDown(api.client.close);
    await tester.pumpWidget(api.app());
    await tester.pumpAndSettle();

    expect(find.text('ההודעה נשלחה'), findsOneWidget);
    expect(_confirm, findsNothing);
    expect(_search, findsNothing);
    expect(api.recipientReads, 0);
    expect(api.writes, isEmpty);
  });
}
