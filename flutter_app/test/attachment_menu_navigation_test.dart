import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'helpers/attachment_picker.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
// ignore: depend_on_referenced_packages
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show CameraPlatform;
import 'helpers/photo_camera.dart';
import 'own_media_filter_test.dart' show TestImageFile;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  FilePicker.platform = AttachmentPicker([]);
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });
  for (final nested in [false, true]) {
    testWidgets(
        'attachment actions close the menu and preserve chat '
        '(nested navigator: $nested)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final previousCamera = CameraPlatform.instance;
      CameraPlatform.instance = PhotoCamera(TestImageFile());
      addTearDown(() => CameraPlatform.instance = previousCamera);
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previousPicker = FilePicker.platform;
      final picker = AttachmentPicker([]);
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = previousPicker);
      final chat = ChatScreen(
        token: 'test-token',
        me: const {'id': 'test-user'},
        recipient: const {'id': 'test-recipient', 'name': 'חבר לבדיקה'},
        socket: null,
        embedded: nested,
      );
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(useMaterial3: false, fontFamily: 'NotoSansHebrew'),
          home: nested
              ? Navigator(
                  pages: [MaterialPage<void>(child: chat)],
                  onDidRemovePage: (_) {},
                )
              : chat,
        ));
        await tester.pumpAndSettle();
        final chatState = tester.state(find.byType(ChatScreen));
        for (final label in ['צילום', 'העלאת קבצים']) {
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          expect(find.text('העלאת קבצים'), findsOneWidget);
          expect(find.text('הקבצים עוברים סינון לפני השליחה'), findsNothing);
          expect(find.text('אישור, חתימה או סקר'), findsNothing);
          expect(find.text('צילום מסך'), findsNothing);
          expect(find.text('מדבקות ואימוג׳י'), findsNothing);
          final anchor = tester.getRect(find.byIcon(Icons.attach_file));
          final menu = tester
              .getRect(find.byKey(const ValueKey('chat-attachment-menu')));
          expect(menu.width, lessThanOrEqualTo(244));
          expect(menu.bottom, lessThan(anchor.top));
          expect((menu.right - anchor.right).abs(), lessThan(20));
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(
              find.byKey(const ValueKey('chat-attachment-menu')), findsNothing);
          if (label == 'צילום') {
            expect(find.text('צילום'), findsOneWidget);
            await tester.tap(find.byIcon(Icons.close));
            await tester.pumpAndSettle();
          }
          expect(find.byType(ChatScreen), findsOneWidget);
          expect(tester.state(find.byType(ChatScreen)), same(chatState));
          expect(tester.takeException(), isNull);
        }
        expect(picker.calls, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
          () => MockClient((request) async {
                if (request.url.path.contains('/messages/')) {
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
              }));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
  for (final scale in [1.3, 2.0]) {
    testWidgets('mobile attachment menu fits enlarged text at $scale',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(720, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(useMaterial3: false, fontFamily: 'NotoSansHebrew'),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: ChatScreen(
              token: 'token',
              me: const {'id': 'font-test'},
              recipient: const {'id': 'peer', 'name': 'חבר לבדיקה'},
              socket: null),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.attach_file));
        await tester.pumpAndSettle();
        expect(find.text('מדבקות ואימוג׳י'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('שיתוף איש קשר'));
        await tester.tap(find.text('שיתוף איש קשר'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('שתף את הפרטים שלי'));
        await tester.pumpAndSettle();
        expect(find.text('שתף את הפרטים שלי').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
          () => MockClient((request) async => http.Response(
              request.url.path.contains('/messages/') && request.method == 'GET'
                  ? '[]'
                  : '{}',
              200)));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  for (final isAdmin in [false, true]) {
    testWidgets(
        'sending group members can open each separate form action (admin: $isAdmin)',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final group = <String, dynamic>{
        'id': 'forms-group',
        'name': 'קבוצה לבדיקה',
        'role': isAdmin ? 'admin' : 'member',
        'status': 'member',
        'send_permission': 'all',
        'member_count': 1,
      };
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(useMaterial3: true, fontFamily: 'NotoSansHebrew'),
          home: GroupChatScreen(
              token: 'token',
              me: const {'id': 'current-user', 'name': 'משתמש'},
              group: group,
              socket: null),
        ));
        await tester.pumpAndSettle();
        final state = tester.state(find.byType(GroupChatScreen));
        await tester.tap(find.byIcon(Icons.attach_file));
        await tester.pumpAndSettle();
        expect(find.text('הקבצים עוברים סינון לפני השליחה'), findsNothing);
        expect(
            tester
                .getSize(find.byKey(const ValueKey('chat-attachment-menu')))
                .height,
            // Chrome tests use a wider fallback font instead of NotoSansHebrew.
            lessThanOrEqualTo(kIsWeb ? 340 : 300));
        final entry = find.text('אישור, חתימה או סקר');
        expect(entry, findsOneWidget);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(find.byType(CreateEducationFormScreen), findsNothing);
        for (final label in ['אישור', 'חתימה', 'סקר']) {
          expect(find.text(label), findsOneWidget);
        }
        // Returning from the submenu must preserve the root attachment menu.
        await tester.tap(find.text('אישור, חתימה או סקר'));
        await tester.pumpAndSettle();
        expect(find.text('העלאת קבצים'), findsOneWidget);
        for (final choice in [
          ('אישור', 'approval', 'יצירת אישור'),
          ('חתימה', 'signature', 'יצירת בקשת חתימה'),
          ('סקר', 'survey', 'יצירת סקר'),
        ]) {
          await tester.tap(find.text('אישור, חתימה או סקר'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(choice.$1));
          await tester.pumpAndSettle();
          expect(
              find.byKey(const ValueKey('chat-attachment-menu')), findsNothing);
          final creator = find.byType(CreateEducationFormScreen);
          expect(creator, findsOneWidget);
          final screen = tester.widget<CreateEducationFormScreen>(creator);
          expect(screen.initialType, choice.$2);
          expect(screen.lockType, isTrue);
          expect(find.text(choice.$3), findsOneWidget);
          expect(find.byType(SegmentedButton<String>), findsNothing);
          expect(find.text('צירוף מסמך לחתימה *'),
              choice.$2 == 'signature' ? findsOneWidget : findsNothing);
          if (choice.$2 == 'survey') {
            await tester.scrollUntilVisible(find.text('סקר אנונימי'), 150,
                scrollable: find
                    .descendant(
                        of: find.descendant(
                            of: creator, matching: find.byType(ListView)),
                        matching: find.byType(Scrollable))
                    .first);
            await tester.pumpAndSettle();
          }
          expect(find.text('סקר אנונימי'),
              choice.$2 == 'survey' ? findsOneWidget : findsNothing);
          Navigator.of(tester.element(creator)).pop();
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(GroupChatScreen)), same(state));
          if (choice.$2 != 'survey') {
            await tester.tap(find.byIcon(Icons.attach_file));
            await tester.pumpAndSettle();
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
          () => MockClient((request) async {
                final path = request.url.path;
                Object data = {};
                if (path.endsWith('/groups')) {
                  data = [group];
                } else if (path.endsWith('/messages') ||
                    path.contains('/messages/') ||
                    path.endsWith('/members') ||
                    path.endsWith('/upload-batch-notices')) {
                  data = [];
                } else if (path.endsWith('/filter-settings')) {
                  data = {
                    'filter': {
                      'text': true,
                      'video': true,
                      'nonHumanImages': true,
                      'men': true,
                      'women': true,
                      'children': true
                    },
                    'requiresChoice': false
                  };
                } else if (path.endsWith('/forms-group')) {
                  data = {...group, 'members': []};
                }
                return http.Response(jsonEncode(data), 200, headers: {
                  'content-type': 'application/json; charset=utf-8'
                });
              }));
    });
  }
}
