import 'dart:async';
import 'dart:convert';
import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _me = {'id': 'avatar-owner', 'name': 'משתמש'};
const _womanPhoto = 'https://example.test/woman.png';
const _manPhoto = 'https://example.test/man.png';
const _friend = {'id': 'friend', 'name': 'חברה', 'saved': true};
const _filter = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true
};
String get _token =>
    'header.${base64Url.encode(utf8.encode(jsonEncode(_me)))}.signature';
http.Response _json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _Backend {
  bool womenAllowed = true;
  int userLoads = 0;
  Completer<void>? usersGate;
  Future<http.Response> respond(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/registration-status')) {
      return _json({'birthDateMissing': false});
    }
    if (path.endsWith('/profile')) {
      return _json({..._me, 'profile_pic_url': _womanPhoto});
    }
    if (path.endsWith('/users')) {
      userLoads++;
      final rows = [
        {..._friend, 'profile_pic_url': womenAllowed ? _womanPhoto : null}
      ];
      await usersGate?.future;
      return _json(rows);
    }
    if (path.endsWith('/users/directory') || path.endsWith('/users/search')) {
      return _json([
        {
          'id': 'new-woman',
          'name': 'חברה חדשה',
          'profile_pic_url': womenAllowed ? _womanPhoto : null
        },
        {'id': 'new-man', 'name': 'חבר חדש', 'profile_pic_url': _manPhoto},
      ]);
    }
    if (path.endsWith('/filter-settings')) {
      if (request.method == 'PUT') {
        womenAllowed = (jsonDecode(request.body) as Map)['women'] == true;
      }
      return _json({..._filter, 'women': womenAllowed});
    }
    if (path.endsWith('/groups') ||
        path.endsWith('/message-requests') ||
        path.endsWith('/phone-requests') ||
        path.contains('/messages/')) {
      return _json([]);
    }
    return _json({});
  }
}

Finder _inConversations(Finder finder) =>
    find.descendant(of: find.byType(ConversationsScreen), matching: finder);
Finder _avatar(String name) => find
    .byWidgetPredicate((widget) => widget is UserAvatar && widget.name == name);
CircleAvatar _circle(WidgetTester tester, String name) =>
    tester.widget<CircleAvatar>(find
        .descendant(of: _avatar(name), matching: find.byType(CircleAvatar))
        .first);
Future<void> _withShell(
    WidgetTester tester, _Backend backend, Future<void> Function() check,
    {bool cached = false}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('github.com/QuisApp/flutter_contacts'),
          (call) async => false);
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  SharedPreferences.setMockInitialValues({
    if (cached)
      'cache_users_avatar-owner': jsonEncode([
        {..._friend, 'profile_pic_url': _womanPhoto},
        {'id': 'emoji', 'name': 'פרח', 'profile_pic_url': 'emoji:🌸'},
      ]),
  });
  for (final url in [_womanPhoto, _manPhoto]) {
    final image = await tester.runAsync(() => createTestImage());
    PaintingBinding.instance.imageCache.putIfAbsent(
        NetworkImage(url),
        () => OneFrameImageStreamCompleter(
            SynchronousFuture(ImageInfo(image: image!))));
  }
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSansHebrew'),
          home: Directionality(
              textDirection: TextDirection.rtl,
              child: Stack(children: [
                MainShell(token: _token),
                const Positioned(
                    top: 0,
                    left: 0,
                    child: UserAvatar(name: 'ישן', picUrl: _womanPhoto)),
              ]))));
      await tester.pumpAndSettle();
      tester
          .widget<ConversationsScreen>(find.byType(ConversationsScreen))
          .socket
          ?.disconnect();
      await check();
    } finally {
      if (backend.usersGate != null && !backend.usersGate!.isCompleted) {
        backend.usersGate!.complete();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  }, () => MockClient(backend.respond));
}

Future<void> _saveWomenBlocked(WidgetTester tester) async {
  await tester.tap(_inConversations(find.byTooltip('תפריט')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('הגדרות').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('סוגי תוכן מותרים'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('נשים'));
  await tester.tap(find.text('נשים'));
  await tester.ensureVisible(find.text('שמור הגדרות'));
  await tester.tap(find.text('שמור הגדרות'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });
  testWidgets('cached photos wait for viewer filtering while emoji remains',
      (tester) async {
    final backend = _Backend()..usersGate = Completer<void>();
    await _withShell(tester, backend, () async {
      expect(_circle(tester, 'חברה').backgroundImage, isNull);
      expect(find.text('🌸'), findsOneWidget);
      backend.usersGate!.complete();
      await tester.pumpAndSettle();
      expect(_circle(tester, 'חברה').backgroundImage,
          const NetworkImage(_womanPhoto));
      expect(tester.takeException(), isNull);
    }, cached: true);
  });
  testWidgets(
      'saving general filter hides photos immediately and filters add friend',
      (tester) async {
    final backend = _Backend();
    await _withShell(tester, backend, () async {
      expect(_circle(tester, 'חברה').backgroundImage,
          const NetworkImage(_womanPhoto));
      final previousLoads = backend.userLoads;
      backend.usersGate = Completer<void>();
      await _saveWomenBlocked(tester);
      expect(backend.womenAllowed, isFalse);
      expect(_circle(tester, 'ישן').backgroundImage, isNull,
          reason:
              'Even a still-mounted widget with the old URL cannot display it');
      expect(backend.userLoads, greaterThan(previousLoads));
      expect(_circle(tester, 'חברה').backgroundImage, isNull,
          reason:
              'Blocked photos disappear before the refresh response arrives');
      backend.usersGate!.complete();
      await tester.pumpAndSettle();
      expect(_circle(tester, 'חברה').backgroundImage, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('cache_users_avatar-owner')!) as List,
          everyElement(isNot(containsPair('profile_pic_url', _womanPhoto))));
      await tester.tap(_inConversations(find.byTooltip('חיפוש ושמירת חבר')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(_circle(tester, 'חברה חדשה').backgroundImage, isNull);
      expect(_circle(tester, 'חבר חדש').backgroundImage,
          const NetworkImage(_manPhoto));
      expect(tester.takeException(), isNull);
    });
  });
}
