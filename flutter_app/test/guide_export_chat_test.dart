import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

void main() {
  testWidgets('a saved guide Excel keeps its caption and Drive action in chat',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: ChatScreen(
            token: 'test-token',
            me: const {'id': 'test-user'},
            recipient: const {'id': kSystemGuideId, 'name': 'המדריך'},
            socket: null,
            embedded: true,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(find.text('קובץ Excel נשמר בשיחה ובנתונים שלך.'), findsOneWidget);
      expect(find.text('פתח קובץ Excel'), findsOneWidget);
      expect(find.text('חיבור וגיבוי ב־Google Drive'), findsOneWidget);
      expect(
          find.textContaining('betshuva://app/backup-settings'), findsNothing);
      expect(find.text('תצוגת Excel'), findsOneWidget);
      expect(
          requests
              .where(
                  (request) => request.url.path.endsWith('/document-preview'))
              .single
              .headers['Authorization'],
          'Bearer test-token');

      await tester.tap(find.text('פתח קובץ Excel'));
      await tester.pumpAndSettle();
      expect(find.text('חברי הקבוצה.xlsx'), findsOneWidget);
      expect(find.text('0501234567'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('חיבור וגיבוי ב־Google Drive'));
      await tester.pumpAndSettle();
      expect(find.byType(GoogleDriveBackupOfferScreen), findsOneWidget);
      await tester.tap(find.text('לא עכשיו'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(find.text('קובץ Excel נשמר בשיחה ובנתונים שלך.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.method == 'GET' &&
                  request.url.path.contains('/messages/')) {
                return http.Response(
                    jsonEncode([
                      {
                        'id': 'bdf54856-a69c-4c6b-838a-65a647b83959',
                        'sender_id': kSystemGuideId,
                        'recipient_id': 'test-user',
                        'type': 'document',
                        'body': 'קובץ Excel נשמר בשיחה ובנתונים שלך.\n'
                            'betshuva://app/guide-file/'
                            'c2a8d3d5-d7dc-457b-b80f-a95fa2117478\n'
                            'betshuva://app/backup-settings',
                        'file_url': '/betshuva-app/api/guide-files/'
                            'c2a8d3d5-d7dc-457b-b80f-a95fa2117478/download',
                        'file_name': 'חברי הקבוצה.xlsx',
                        'created_at': '2026-09-09T17:00:00Z',
                        'message_status': 'sent',
                        'is_read': true,
                      }
                    ]),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8'
                    });
              }
              if (request.url.path.endsWith('/document-preview')) {
                return http.Response(
                    jsonEncode({
                      'kind': 'excel',
                      'sheets': [
                        {
                          'name': 'חברי הקבוצה',
                          'rows': [
                            ['שם', 'טלפון'],
                            ['דנה', '0501234567']
                          ]
                        }
                      ]
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8'
                    });
              }
              if (request.url.path.contains('/guide-files/')) {
                const path = '/betshuva-app/api/guide-files/'
                    'c2a8d3d5-d7dc-457b-b80f-a95fa2117478/download';
                return http.Response(
                    jsonEncode({
                      'fileUrl': path,
                      'downloadUrl': '$path?ticket=signed-download',
                      'fileName': 'חברי הקבוצה.xlsx',
                      'fileType': 'document',
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8'
                    });
              }
              if (request.url.path.endsWith('/filter-settings')) {
                return http.Response(
                    '{"filter":{"text":true},"requiresChoice":false}', 200);
              }
              if (request.url.path.endsWith('/receiving-filter')) {
                return http.Response('{"filter":{"text":true}}', 200);
              }
              if (request.url.path.endsWith('/backup/google/status')) {
                return http.Response('{"connected":false}', 200);
              }
              return http.Response('{}', 200);
            }));
  });

  testWidgets(
      'HTTP guide files appear immediately and socket replay stays unique',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final socket = io.io('http://localhost:1',
        io.OptionBuilder().disableAutoConnect().enableForceNew().build());
    addTearDown(() {
      socket.connected = false;
      socket.dispose();
    });
    const reply = {
      'id': 'e701b973-077d-45c7-8cda-a2f45cba5399',
      'fromUserId': kSystemGuideId,
      'text': 'קובץ מהתשובה הישירה נשמר.',
      'fileUrl': '/betshuva-app/api/guide-files/'
          'c2a8d3d5-d7dc-457b-b80f-a95fa2117478/download',
      'fileName': 'טבלה.xlsx',
      'fileType': 'document',
      'createdAt': '2026-09-09T17:00:00Z',
    };
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: ChatScreen(
          token: 'test-token',
          me: const {'id': 'test-user'},
          recipient: const {'id': kSystemGuideId, 'name': 'המדריך'},
          socket: socket,
          embedded: true,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'תכין לי קובץ Excel');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(find.text('קובץ מהתשובה הישירה נשמר.'), findsOneWidget);
      expect(find.text('תצוגת Excel'), findsOneWidget);

      socket.connected = true;
      socket.onevent({
        'data': ['chat:message', reply]
      });
      socket.connected = false;
      await tester.pumpAndSettle();
      expect(find.text('קובץ מהתשובה הישירה נשמר.'), findsOneWidget);
      expect(find.text('תצוגת Excel'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              if (request.method == 'POST' &&
                  request.url.path.endsWith('/messages')) {
                return http.Response(
                    jsonEncode({
                      'id': 'new-user-message',
                      'status': 'sent',
                      'systemReply': reply,
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8'
                    });
              }
              if (request.method == 'GET' &&
                  request.url.path.contains('/messages/')) {
                return http.Response('[]', 200);
              }
              if (request.url.path.endsWith('/filter-settings')) {
                return http.Response(
                    '{"filter":{"text":true},"requiresChoice":false}', 200);
              }
              if (request.url.path.endsWith('/receiving-filter')) {
                return http.Response('{"filter":{"text":true}}', 200);
              }
              if (request.url.path.endsWith('/document-preview')) {
                return http.Response(
                    '{"kind":"excel","sheets":[{"name":"Sheet1","rows":[["name"]]}]}',
                    200);
              }
              return http.Response('{}', 200);
            }));
  });
}
