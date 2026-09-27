import 'dart:convert';
import 'dart:async';
import 'package:betshuva/main.dart';
import 'package:betshuva/private_message_outbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PrivateMessageOutbox.sending.clear();
  });


  for (final status in ['awaiting_contact_approval', 'rejected_request']) {
    testWidgets('server request status $status survives opening and reopening chat', (tester) async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/messages/peer')) return http.Response(jsonEncode([{
          'id':'request_test', 'sender_id':'me', 'recipient_id':'peer', 'type':'text',
          'body':'request content', 'created_at':'2026-09-27T10:00:00Z',
          'message_status':status, 'scan_reason':'הנמען דחה את בקשת החברות',
        }]),200,headers:{'content-type':'application/json; charset=utf-8'});
        if (request.url.path.endsWith('/filter-settings')) return http.Response('{"filter":{"text":true},"requiresChoice":false}',200);
        return http.Response('{}',200);
      });
      await http.runWithClient(() async {
        for (var round=0;round<2;round++) {
          await tester.pumpWidget(MaterialApp(home:ChatScreen(token:'token',me:const {'id':'me'},recipient:const {'id':'peer','name':'חבר'},socket:null)));
          await tester.pump(const Duration(milliseconds:300));
          await tester.pumpAndSettle();
          expect(find.text('request content'),findsOneWidget);
          expect(find.textContaining(status=='awaiting_contact_approval'?'טרם נשלח':'לא נשלח — הנמען דחה'),findsOneWidget);
          expect(find.byIcon(Icons.done),findsNothing);
          expect(tester.takeException(),isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds:300));
        }
      },()=>client);
    });
  }
  test(
      'concurrent writes survive recreation and stay scoped to account and peer',
      () async {
    final store = PrivateMessageOutbox('me', 'peer');
    await Future.wait(List.generate(
        3,
        (i) => store.save({
              'outboxId': '$i',
              'text': 'text $i',
              'createdAt': '2026-01-01T00:00:0$i',
            })));
    expect(await PrivateMessageOutbox('me', 'peer').load(), hasLength(3));
    expect(await PrivateMessageOutbox('other', 'peer').load(), isEmpty);
    expect(await PrivateMessageOutbox('me', 'other').load(), isEmpty);
    await store.remove('1');
    expect((await store.load()).map((m) => m['text']), ['text 0', 'text 2']);
  });

  testWidgets(
      'offline text survives closing the chat and retries with its original identity',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <Map<String, dynamic>>[];
    var fail = true;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/messages')) {
        requests.add(jsonDecode(request.body));
        if (fail) throw http.ClientException('offline');
        return http.Response('{"id":"saved-once","status":"sent"}', 200);
      }
      if (request.url.path.endsWith('/messages/peer')) {
        return http.Response('[]', 200);
      }
      if (request.url.path.endsWith('/filter-settings')) {
        return http.Response(
            '{"filter":{"text":true},"requiresChoice":false}', 200);
      }
      if (request.url.path.endsWith('/receiving-filter')) {
        return http.Response(
            '{"filter":{"text":true,"nonHumanImages":true}}', 200);
      }
      return http.Response('{}', 200);
    });
    Widget chat() => MaterialApp(
        home: ChatScreen(
            token: 'token',
            me: const {'id': 'me'},
            recipient: const {'id': 'peer', 'name': 'חבר'},
            socket: null));
    await http.runWithClient(() async {
      await tester.pumpWidget(chat());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField).first, 'offline retained');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('offline retained'), findsOneWidget);
      expect(find.text('נסה לשלוח שוב'), findsOneWidget);
      expect(requests, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(await PrivateMessageOutbox('me', 'peer').load(), hasLength(1));
      await tester.pumpWidget(chat());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('offline retained'), findsOneWidget);
      expect(requests, hasLength(1),
          reason: 'Opening a chat must not silently resend a failed item');
      fail = false;
      await tester.tap(find.text('נסה לשלוח שוב'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(requests, hasLength(2));
      expect(requests[0]['clientMessageId'], requests[1]['clientMessageId']);
      expect(await PrivateMessageOutbox('me', 'peer').load(), isEmpty);
      expect(find.text('נסה לשלוח שוב'), findsNothing);
      expect(find.text('offline retained'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }, () => client);
  });
  testWidgets(
      'uncached outbox is visible offline and reconciles a lost acknowledgement from history',
      (tester) async {
    final store = PrivateMessageOutbox('me', 'peer');
    final draft = <String, dynamic>{
      'id': 'temp_lost_ack',
      'outboxId': 'lost_ack',
      'text': 'durable draft',
      'from': 'me',
      'time': '12:00',
      'createdAt': '2026-09-23T09:00:00Z',
      'status': 'failed'
    };
    await store.save(draft);
    final history = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.method == 'GET' &&
          request.url.path.endsWith('/messages/peer')) {
        return history.future;
      }
      return http.Response('{}', 200);
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: ChatScreen(
              token: 'token',
              me: const {'id': 'me'},
              recipient: const {'id': 'peer', 'name': 'חבר'},
              socket: null)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('durable draft'), findsOneWidget);
      expect(find.text('נסה לשלוח שוב'), findsOneWidget);
      history.complete(http.Response(
          jsonEncode([
            {
              'id': 'saved',
              'client_message_id': 'lost_ack',
              'body': 'durable draft',
              'sender_id': 'me',
              'type': 'text',
              'created_at': '2026-09-23T09:00:00Z',
              'message_status': 'sent'
            }
          ]),
          200));
      await tester.pumpAndSettle();
      expect(await store.load(), isEmpty);
      expect(find.text('durable draft'), findsOneWidget);
      expect(find.text('נסה לשלוח שוב'), findsNothing);
      // A response timeout in a disposed route can recreate a local record
      // after a newer route has already fetched its server acknowledgement.
      await store.save(draft);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(await store.load(), isEmpty);
      expect(find.text('durable draft'), findsOneWidget);
      expect(find.text('נסה לשלוח שוב'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => client);
  });
}
