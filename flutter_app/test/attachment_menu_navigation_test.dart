import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CancelledImagePicker extends ImagePickerPlatform {
  final calls = <ImageSource>[];

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    calls.add(source);
    return null;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    calls.add(ImageSource.gallery);
    return [];
  }
}

void main() {
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
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previousPicker = ImagePickerPlatform.instance;
      final picker = _CancelledImagePicker();
      ImagePickerPlatform.instance = picker;
      addTearDown(() => ImagePickerPlatform.instance = previousPicker);
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
        for (final label in ['צלם תמונה', 'גלריה (עד 10)']) {
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          expect(find.text('שיתוף קובץ עם חבר לבדיקה'), findsOneWidget);
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expect(find.text('שיתוף קובץ עם חבר לבדיקה'), findsNothing);
          expect(find.byType(ChatScreen), findsOneWidget);
          expect(tester.state(find.byType(ChatScreen)), same(chatState));
          expect(tester.takeException(), isNull);
        }
        expect(picker.calls, [ImageSource.camera, ImageSource.gallery]);
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
    });
  }
}
