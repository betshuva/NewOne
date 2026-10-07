// Render the current Android widgets with fictional, local-only demo data.
// Run with flutter test tool/generate_play_screenshots.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const allowed = {'text': true, 'video': true, 'nonHumanImages': true,
  'men': true, 'women': false, 'children': true};

void main() {
  testWidgets('render current Android screens for Play', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    // Widget tests replace default fonts with Ahem; restore Hebrew glyphs for
    // RichText spans that do not inherit the application's theme.
    final fallback = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await fallback.load();
    final previousShadows = debugDisableShadows;
    debugDisableShadows = false;
    final boundaryKey = GlobalKey();
    final output = Directory(Platform.environment['PLAY_SCREENSHOT_DIR'] ??
        '/tmp/newone-play-screenshots')..createSync(recursive: true);

    Widget app(Widget screen) => RepaintBoundary(key: boundaryKey, child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('he', 'IL'),
      supportedLocales: const [Locale('he', 'IL')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(fontFamily: 'NotoSansHebrew', platform: TargetPlatform.android,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.light(primary: kPrimary, secondary: kAccent, surface: kCard),
        appBarTheme: const AppBarTheme(backgroundColor: kHeader,
            foregroundColor: Colors.white, elevation: 0, centerTitle: false)),
      home: screen));
    Future<void> save(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    http.Response json(Object data) => http.Response(jsonEncode(data), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    try {
    await http.runWithClient(() async {
      await tester.pumpWidget(app(ChatScreen(token: 'local-demo',
        me: const {'id': 'demo-me', 'name': 'דניאל'},
        recipient: const {'id': 'demo-friend', 'name': 'איתי לוי'},
        socket: null)));
      await save('01-private-chat');
      await tester.tap(find.byIcon(Icons.attach_file));
      await save('02-attachments');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(const ContentFilterSettingsScreen(
          token: 'local-demo', contactId: 'demo-friend', contactName: 'איתי לוי')));
      await save('03-content-filter');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/messages/demo-friend')) {
        final messages = [
          ('demo-friend', 'שלום דניאל! מה שלומך?'),
          ('demo-me', 'ברוך השם, טוב! מתארגנים ללימוד השבועי?'),
          ('demo-friend', 'כן, ביום חמישי בשעה 20:00. נשמח שתצטרף.'),
          ('demo-me', 'בשמחה. אביא גם את דפי הלימוד.'),
          ('demo-friend', 'תודה רבה! אשלח בהמשך את הפרטים בקבוצה.'),
          ('demo-me', 'מצוין, נתראה!'),
        ];
        return json([for (var i = 0; i < messages.length; i++) {
          'id': 'demo-message-$i', 'sender_id': messages[i].$1,
          'sender_name': messages[i].$1 == 'demo-me' ? 'דניאל' : 'איתי לוי',
          'type': 'text', 'body': messages[i].$2, 'text': messages[i].$2, 'status': 'read',
          'created_at': '2026-10-04T15:${(30+i).toString()}:00Z',
        }]);
      }
      if (path.endsWith('/filter-settings')) return json({
        'filter': allowed, 'personalFilter': allowed, 'requiresChoice': false});
      if (path.endsWith('/receiving-filter')) return json({'filter': allowed});
      return json({});
    }));
    } finally {
      debugDisableShadows = previousShadows;
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
