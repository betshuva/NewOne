import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _me = {'id': 'listing-ai-user', 'name': 'משתמש בדיקה'};
const _contact = {'id': 'listing-ai-contact', 'name': 'חבר לבדיקה'};
const _ai = {'id': kSafeInformationAiId, 'name': 'מידע בטוח · AI'};
const _listing = {
  'id': '11111111-1111-4111-8111-111111111111',
  'title': 'מקרר לבדיקה',
  'type': 'sale',
  'price': 100.0,
  'seller_id': 'seller',
  'seller_name': 'מפרסם',
  'status': 'active',
};
final _secondListing = {
  ..._listing,
  'id': '22222222-2222-4222-8222-222222222222',
  'title': 'שולחן לבדיקה',
};
const _aiTooltip = 'התייעצות עם עוזר AI על המודעה, המחיר והשוואה להצעות נוספות';
const _filter = {
  'text': true,
  'video': true,
  'nonHumanImages': true,
  'men': true,
  'women': true,
  'children': true,
};

http.Response _json(Object data) => http.Response(jsonEncode(data), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Widget _app({bool rebuilt = false}) => MaterialApp(
      theme: ThemeData(
        fontFamily: 'NotoSansHebrew',
        primaryColor: rebuilt ? Colors.indigo : Colors.blue,
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: MainShell(token: 'test-token'),
      ),
    );

Future<void> _withShell(
  WidgetTester tester,
  Future<void> Function(List<Map<String, dynamic>> sent) check, {
  Size size = const Size(1400, 1000),
  bool withContactListing = false,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final previousErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    final error = details.exception;
    if (error is NetworkImageLoadException &&
        error.statusCode == 400 &&
        error.uri.path
            .endsWith('/assets/assets/guide/safe-information-ai.png')) {
      return;
    }
    previousErrorHandler?.call(details);
  };
  addTearDown(() => FlutterError.onError = previousErrorHandler);
  final sent = <Map<String, dynamic>>[];
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      tester
          .widget<ConversationsScreen>(find.byType(ConversationsScreen))
          .socket
          ?.disconnect();
      await check(sent);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      debugDefaultTargetPlatformOverride = null;
    }
  },
      () => MockClient((request) async {
            final path = request.url.path;
            if (path.endsWith('/registration-status')) {
              return _json({'birthDateMissing': false});
            }
            if (path.endsWith('/profile')) return _json(_me);
            if (path.endsWith('/users')) return _json([_contact, _ai]);
            if (path.endsWith('/listings')) {
              return _json([_listing, _secondListing]);
            }
            if (path.endsWith('/listings/${_listing['id']}')) {
              return _json(_listing);
            }
            if (request.method == 'POST' && path.endsWith('/messages')) {
              sent.add(jsonDecode(request.body) as Map<String, dynamic>);
              return _json({'id': 'sent-${sent.length}', 'status': 'read'});
            }
            if (withContactListing &&
                request.method == 'GET' &&
                path.endsWith('/messages/${_contact['id']}')) {
              return _json([
                {
                  'id': 'shared-listing-message',
                  'sender_id': _contact['id'],
                  'body': 'betshuva://listing/${_listing['id']}',
                  'type': 'text',
                  'created_at': '2026-09-09T12:00:00Z',
                  'message_status': 'read',
                  'is_read': true,
                },
              ]);
            }
            if (path.endsWith('/groups') ||
                path.endsWith('/message-requests') ||
                path.endsWith('/messages') ||
                path.contains('/messages/')) {
              return _json([]);
            }
            if (path.endsWith('/filter-settings')) {
              return _json({
                'filter': _filter,
                'personalFilter': _filter,
                'generalFilter': _filter,
                'requiresChoice': false,
              });
            }
            if (path.endsWith('/receiving-filter')) {
              return _json({'filter': _filter});
            }
            return _json({});
          }));
}

Future<void> _openListings(WidgetTester tester) async {
  await tester.tap(find.text('מודעות'));
  await tester.pumpAndSettle();
  expect(find.byType(ListingsScreen), findsOneWidget);
  expect(find.text(_listing['title']! as String), findsOneWidget);
}

Future<void> _openListingAi(WidgetTester tester, {required bool detail}) async {
  if (detail) {
    await tester.tap(find.text(_listing['title']! as String));
    await tester.pumpAndSettle();
    expect(find.byType(ListingDetailScreen), findsOneWidget);
    final button = find.descendant(
      of: find.byType(ListingDetailScreen),
      matching: find.text('AI'),
    );
    await tester.ensureVisible(button);
    await tester.tap(button);
  } else {
    await tester.tap(find.byTooltip(_aiTooltip).first);
  }
  await tester.pumpAndSettle();
}

void _expectConsultation(List<Map<String, dynamic>> sent, {int count = 1}) {
  expect(sent, hasLength(count));
  for (final message in sent) {
    expect(message['toUserId'], kSafeInformationAiId);
    expect(message['text'], contains('betshuva://listing/${_listing['id']}'));
  }
}

void _expectRightListings(WidgetTester tester) {
  expect(find.byType(ListingsScreen), findsOneWidget);
  final search = find.byWidgetPredicate((widget) =>
      widget is TextField &&
      widget.decoration?.hintText == 'חיפוש במודעות... ');
  expect(search, findsOneWidget);
  expect(tester.getRect(search).left, greaterThanOrEqualTo(990));
  expect(tester.getRect(search).right, lessThanOrEqualTo(1400));
}

void _expectLeftChat(WidgetTester tester) {
  final chat = find.byType(ChatScreen);
  expect(chat, findsOneWidget);
  expect(tester.widget<ChatScreen>(chat).embedded, isTrue);
  final rect = tester.getRect(chat);
  expect(rect.left, closeTo(0, .1));
  expect(rect.right, closeTo(989, .1));
  final nav = find.byType(BottomNavigationBar);
  expect(nav, findsOneWidget);
  expect(tester.getRect(nav).left, closeTo(990, .1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  for (final detail in [false, true]) {
    testWidgets(
        'desktop listing ${detail ? 'detail' : 'card'} opens AI left and sends once across navigation',
        (tester) async {
      await _withShell(tester, (sent) async {
        await _openListings(tester);
        await _openListingAi(tester, detail: detail);
        _expectLeftChat(tester);
        _expectRightListings(tester);
        _expectConsultation(sent);

        await tester.pumpWidget(_app(rebuilt: true));
        await tester.pumpAndSettle();
        _expectLeftChat(tester);
        _expectRightListings(tester);
        _expectConsultation(sent);

        // Returning through the regular conversation list must not repeat the
        // initial question that the listing's AI button already sent.
        await tester.tap(find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('כל השיחות'),
        ));
        await tester.pumpAndSettle();
        final conversations = find.byType(ConversationsScreen);
        expect(conversations, findsOneWidget);
        await tester.tap(find.descendant(
          of: conversations,
          matching: find.text(_contact['name']!),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.descendant(
          of: conversations,
          matching: find.text(_ai['name']!),
        ));
        await tester.pumpAndSettle();
        _expectLeftChat(tester);
        expect(
            tester.widget<ChatScreen>(find.byType(ChatScreen)).recipient['id'],
            kSafeInformationAiId);
        _expectConsultation(sent);
      });
    });
  }

  testWidgets('desktop AI back restores listing; right selection closes AI',
      (tester) async {
    await _withShell(tester, (sent) async {
      await _openListings(tester);
      await _openListingAi(tester, detail: true);
      _expectLeftChat(tester);
      await tester.tap(find.descendant(
        of: find.byType(ChatScreen),
        matching: find.text('צפה במודעה'),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      final linkedListing = find.byType(ListingDetailScreen);
      expect(linkedListing, findsOneWidget);
      expect(tester.getRect(linkedListing).right, closeTo(989, .1));
      _expectRightListings(tester);
      await tester.tap(find.descendant(
        of: linkedListing,
        matching: find.byType(BackButton),
      ));
      await tester.pumpAndSettle();
      _expectLeftChat(tester);
      _expectConsultation(sent);

      await tester.tap(find.descendant(
        of: find.byType(ChatScreen),
        matching: find.byType(BackButton),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      expect(find.byType(ListingDetailScreen), findsOneWidget);
      expect(
          tester
              .widget<ListingDetailScreen>(find.byType(ListingDetailScreen))
              .item['id'],
          _listing['id']);
      _expectRightListings(tester);
      _expectConsultation(sent);

      await tester.tap(find.descendant(
        of: find.byType(ListingDetailScreen),
        matching: find.text('AI'),
      ));
      await tester.pumpAndSettle();
      _expectLeftChat(tester);
      _expectConsultation(sent, count: 2);
      await tester.tap(find.text(_secondListing['title']! as String));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      expect(
          tester
              .widget<ListingDetailScreen>(find.byType(ListingDetailScreen))
              .item['id'],
          _secondListing['id']);
      _expectRightListings(tester);
      _expectConsultation(sent, count: 2);
      await tester.tap(find.descendant(
        of: find.byType(ListingDetailScreen),
        matching: find.text('AI'),
      ));
      await tester.pumpAndSettle();
      _expectLeftChat(tester);
      // Selecting the same source row must also dismiss the AI route.
      await tester.tap(find.text(_secondListing['title']! as String));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsNothing);
      expect(
          tester
              .widget<ListingDetailScreen>(find.byType(ListingDetailScreen))
              .item['id'],
          _secondListing['id']);
      expect(sent, hasLength(3));
      expect(sent.last['text'],
          contains('betshuva://listing/${_secondListing['id']}'));
    });
  });

  testWidgets('AI from a shared listing keeps conversations on the right',
      (tester) async {
    await _withShell(tester, (sent) async {
      await tester.tap(find.descendant(
        of: find.byType(ConversationsScreen),
        matching: find.text(_contact['name']!),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('צפה במודעה'));
      await tester.pumpAndSettle();
      expect(find.byType(ListingDetailScreen), findsOneWidget);
      final aiButton = find.descendant(
        of: find.byType(ListingDetailScreen),
        matching: find.text('AI'),
      );
      await tester.ensureVisible(aiButton);
      await tester.tap(aiButton);
      await tester.pumpAndSettle();
      _expectLeftChat(tester);
      final conversations = find.byType(ConversationsScreen);
      expect(conversations, findsOneWidget);
      expect(tester.getRect(conversations).left, closeTo(990, .1));
      _expectConsultation(sent);

      await tester.tap(find.descendant(
        of: conversations,
        matching: find.text(_ai['name']!),
      ));
      await tester.pumpAndSettle();
      _expectLeftChat(tester);
      expect(find.byType(ListingDetailScreen), findsNothing);
      _expectConsultation(sent);
    }, withContactListing: true);
  });

  testWidgets('mobile listing AI stays full-screen and back returns to listing',
      (tester) async {
    await _withShell(tester, (sent) async {
      await _openListings(tester);
      await _openListingAi(tester, detail: true);
      final chat = find.byType(ChatScreen);
      expect(chat, findsOneWidget);
      expect(tester.widget<ChatScreen>(chat).embedded, isFalse);
      expect(tester.getRect(chat).width, closeTo(430, .1));
      expect(find.byType(BottomNavigationBar), findsNothing);
      _expectConsultation(sent);
      await tester.tap(find.descendant(
        of: chat,
        matching: find.byType(BackButton),
      ));
      await tester.pumpAndSettle();
      expect(chat, findsNothing);
      expect(find.byType(ListingDetailScreen), findsOneWidget);
      _expectConsultation(sent);
    }, size: const Size(430, 1000));
  });
}
