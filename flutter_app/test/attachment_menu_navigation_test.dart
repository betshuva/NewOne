import 'package:file_picker/file_picker.dart';
import 'helpers/attachment_picker.dart';
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
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
}
