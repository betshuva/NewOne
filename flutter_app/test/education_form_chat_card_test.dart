import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:betshuva/education_form_message_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _group = <String, dynamic>{
  'id': 'card-group',
  'name': 'קבוצת בדיקה',
  'role': 'member',
  'status': 'member',
  'send_permission': 'all',
};

http.Response _json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _message(String type, String title, int day,
        {bool own = false}) =>
    {
      'id': 'message-$type',
      'sender_id': own ? 'viewer' : 'sender',
      'sender_name': 'שם שולח',
      'type': 'text',
      'body': '📋 סקר חדש: שם ישן',
      'created_at': '2026-10-${day.toString().padLeft(2, '0')}T12:30:00Z',
      'is_read': true,
      'education_form_id': 'form-$type',
      'education_form_type': type,
      'education_form_title': title,
      'education_form_status': 'open',
      'education_is_recipient': true,
      'education_response_status': own ? 'completed' : null,
    };

class _Server {
  List<Map<String, dynamic>> history = [];
  final requests = <http.Request>[];
  int histories = 0;

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/card-group/messages')) {
      histories++;
      return _json(history);
    }
    if (path.endsWith('/groups')) return _json([_group]);
    if (path.endsWith('/card-group')) return _json({..._group, 'members': []});
    if (path.endsWith('/filter-settings')) {
      return _json({
        'filter': {'text': true, 'video': true, 'nonHumanImages': true},
        'personalFilter': {'text': true},
        'requiresChoice': false,
      });
    }
    if (path.contains('/education-forms/form-')) {
      return _json({
        'form': {
          'id': path.split('/').last,
          'group_id': 'card-group',
          'group_name': 'קבוצת בדיקה',
          'title': 'הטופס שנבחר',
          'form_type': 'approval',
          'status': 'open',
          'my_role': 'member',
          'canManage': false,
          'isRecipient': true,
          'canRespond': true,
          'updated_at': '2026-10-12T12:30:00Z',
          'questions': [],
        },
        'participants': null,
        'results': null,
      });
    }
    if (path.endsWith('/upload-batch-notices') || path.endsWith('/members')) {
      return _json([]);
    }
    return _json({});
  }
}

Future<void> _mount(WidgetTester tester, {io.Socket? socket}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'NotoSansHebrew'),
    builder: (context, child) =>
        Directionality(textDirection: TextDirection.rtl, child: child!),
    home: GroupChatScreen(
      token: 'card-token',
      me: const {'id': 'viewer', 'name': 'השולח'},
      group: Map<String, dynamic>.from(_group),
      socket: socket,
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('NotoSansHebrew')
          ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf')))
        .load();
  });

  testWidgets('chat history renders form metadata, send dates and own response',
      (tester) async {
    final server = _Server()
      ..history = [
        _message('survey', 'בחירת יעד לטיול', 12, own: true),
        _message('approval', 'אישור יציאה לטיול', 13),
        _message('signature', 'חתימה על מסמך', 14),
      ];
    await http.runWithClient(() async {
      await _mount(tester);
      expect(find.byType(EducationFormMessageCard), findsNWidgets(3));
      for (final title in [
        'בחירת יעד לטיול',
        'אישור יציאה לטיול',
        'חתימה על מסמך'
      ]) {
        expect(find.text(title), findsOneWidget);
      }
      for (final action in ['פתח סקר', 'פתח אישור', 'פתח מסמך']) {
        expect(find.text(action), findsOneWidget);
      }
      expect(find.text('נשלח ב־12/10/2026'), findsOneWidget);
      expect(find.text('נשלח ב־14/10/2026'), findsOneWidget);
      expect(find.text('הושלם'), findsOneWidget);
      expect(find.text('לניהול'), findsNothing);
      expect(find.textContaining('שם ישן'), findsNothing);
      await _close(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets(
      'legacy card opens the exact saved form instead of matching title',
      (tester) async {
    final server = _Server()
      ..history = [
        {
          'id': 'legacy-message',
          'sender_id': 'sender',
          'sender_name': 'שולח',
          'type': 'text',
          'body': '📋 סקר חדש: סקר ראשון',
          'created_at': '2026-10-12T12:30:00Z',
          'education_form_id': 'form-legacy',
        },
      ];
    await http.runWithClient(() async {
      await _mount(tester);
      expect(find.text('סקר ראשון'), findsOneWidget);
      expect(find.text('נשלח ב־12/10/2026'), findsOneWidget);
      await tester.tap(find.text('פתח סקר'));
      await tester.pumpAndSettle();
      expect(find.byType(EducationFormDetailsScreen), findsOneWidget);
      expect(
          server.requests.where(
              (r) => r.url.path.endsWith('/education-forms/form-legacy')),
          hasLength(1));
      expect(
          server.requests
              .where((r) => r.url.path.endsWith('/card-group/education-forms')),
          isEmpty);
      await _close(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets('live form announcement refreshes private participation metadata',
      (tester) async {
    final server = _Server();
    final socket = io.io('http://localhost:1',
        io.OptionBuilder().disableAutoConnect().enableForceNew().build());
    addTearDown(() {
      socket.connected = false;
      socket.dispose();
    });
    await http.runWithClient(() async {
      await _mount(tester, socket: socket);
      expect(find.byType(EducationFormMessageCard), findsNothing);
      final histories = server.histories;
      server.history = [_message('survey', 'סקר שנשלח עכשיו', 12, own: true)];
      socket.connected = true;
      socket.onevent({
        'data': [
          'group:message',
          {
            'id': 'message-survey',
            'groupId': 'card-group',
            'fromUserId': 'viewer',
            'fromName': 'השולח',
            'text': '📋 סקר: סקר שנשלח עכשיו',
            'fileType': 'text',
            'createdAt': '2026-10-12T12:30:00Z',
            'formId': 'form-survey',
            'educationFormTitle': 'סקר שנשלח עכשיו',
            'educationFormType': 'survey',
            'educationFormStatus': 'open',
          },
        ],
      });
      socket.connected = false;
      await tester.pumpAndSettle();
      expect(server.histories, greaterThan(histories));
      expect(find.byType(EducationFormMessageCard), findsOneWidget);
      expect(find.text('סקר שנשלח עכשיו'), findsOneWidget);
      expect(find.text('הושלם'), findsOneWidget);
      expect(find.text('לניהול'), findsNothing);
      final card = tester.widget<EducationFormMessageCard>(
          find.byType(EducationFormMessageCard));
      expect(card.message['educationIsRecipient'], isTrue);
      expect(card.message['educationResponseStatus'], 'completed');
      await _close(tester);
    }, () => MockClient(server.respond));
  });

  for (final creator in [false, true]) {
    testWidgets(
        creator
            ? 'original creator can manage a form republished by another admin'
            : 'an unselected member cannot open the form through the message wrapper',
        (tester) async {
      final server = _Server()
        ..history = [
          {
            ..._message('survey', 'טופס לקבוצה נבחרת', 12),
            'education_is_recipient': false,
            'education_form_creator_id': creator ? 'viewer' : 'other-owner',
          },
        ];
      await http.runWithClient(() async {
        await _mount(tester);
        expect(find.text(creator ? 'לניהול' : 'לידיעה'), findsOneWidget);
        final card = tester.widget<EducationFormMessageCard>(
            find.byType(EducationFormMessageCard));
        expect(card.canManage, creator);
        await tester.tap(find.byType(EducationFormMessageCard));
        await tester.pumpAndSettle();
        final reads = server.requests.where((request) =>
            request.url.path.endsWith('/education-forms/form-survey'));
        expect(reads, creator ? hasLength(1) : isEmpty);
        expect(find.byType(EducationFormDetailsScreen),
            creator ? findsOneWidget : findsNothing);
        await _close(tester);
      }, () => MockClient(server.respond));
    });
  }
}
