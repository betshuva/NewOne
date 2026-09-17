import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart' as app;
import 'package:betshuva/phone_sharing.dart';
import 'package:betshuva/phone_sharing_privacy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _api = 'https://example.test/api';
const _contact = '22222222-2222-4222-8222-222222222222';
const _contactName = 'דנה לוי';
const _phone = '0500000502';
const _shareLabel = 'אני מסכים לשתף את מספר הטלפון שלי עם $_contactName';
const _requestLabel = 'בקש מ$_contactName לשתף את מספר הטלפון';

Map<String, dynamic> _status([Map<String, dynamic> overrides = const {}]) => {
      'phone': null,
      'phone_visibility': 'hidden',
      'contact_source': 'in_app',
      'request_state': 'none',
      'incoming_request': false,
      'share_my_phone': false,
      'can_share_my_phone': true,
      'can_request_phone': true,
      ...overrides,
    };

class _Server {
  String api = _api;
  Map<String, dynamic> status;
  final requests = <http.Request>[];
  Completer<void>? loading;
  bool failGet = false;
  bool failPut = false;
  bool wrapped = false;
  bool emptyUpdateResponse = false;

  _Server([Map<String, dynamic> overrides = const {}])
      : status = _status(overrides);

  List<http.Request> get writes =>
      requests.where((request) => request.method != 'GET').toList();

  List<Map<String, dynamic>> get choices => writes
      .map((request) => jsonDecode(request.body) as Map<String, dynamic>)
      .toList();

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    expect(request.url.toString(), '$api/contacts/$_contact/phone-sharing');
    expect(request.headers['Authorization'], 'Bearer test-token');
    expect(request.headers['Cache-Control'], 'no-store');
    if (request.method == 'GET') {
      await loading?.future;
      if (failGet) return http.Response('{"error":"offline"}', 503);
    } else {
      expect(request.method, 'PUT');
      if (failPut) {
        return http.Response('{"error":"העדכון נכשל"}', 503,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      final choice = jsonDecode(request.body) as Map<String, dynamic>;
      if (choice['request_phone'] == true) status['request_state'] = 'pending';
      if (choice.containsKey('share_my_phone')) {
        status['share_my_phone'] = choice['share_my_phone'] == true;
      }
      if (choice['phone_response'] == 'approve') {
        status['share_my_phone'] = true;
        status['incoming_request'] = false;
      } else if (choice['phone_response'] == 'decline') {
        status['share_my_phone'] = false;
        status['incoming_request'] = false;
      }
      if (emptyUpdateResponse) return http.Response('{"ok":true}', 200);
    }
    return http.Response(
        jsonEncode(wrapped ? {'phoneSharing': status} : status), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }
}

Future<void> _withPanel(
  WidgetTester tester,
  _Server server,
  Future<void> Function(PhoneSharingController controller) check, {
  bool initialChoice = false,
  bool settle = true,
  bool compact = false,
  double width = 900,
  String contactName = _contactName,
}) async {
  final controller = PhoneSharingController();
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: Scaffold(
          body: Directionality(
            textDirection: TextDirection.rtl,
            child: SingleChildScrollView(
              child: PhoneSharingPanel(
                api: _api,
                token: 'test-token',
                contactId: _contact,
                contactName: contactName,
                controller: controller,
                initialChoice: initialChoice,
                compact: compact,
              ),
            ),
          ),
        ),
      ));
      if (settle) await tester.pumpAndSettle();
      await check(controller);
      expect(tester.takeException(), isNull);
    } finally {
      if (server.loading case final pending? when !pending.isCompleted) {
        pending.complete();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      controller.dispose();
    }
  }, () => MockClient(server.respond));
}

CheckboxListTile _checkbox(WidgetTester tester, String label) => tester
    .widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, label));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  test('only permitted phone metadata permits displaying a raw number', () {
    for (final visibility in [null, 'hidden', 'unavailable', 'unknown']) {
      expect(
          visibleContactPhone(
              {'phone': _phone, 'phone_visibility': visibility}),
          isEmpty);
      expect(
          sanitizedPhoneContact(
              {'phone': _phone, 'phone_visibility': visibility})['phone'],
          isNull);
    }
    for (final visibility in ['self', 'known', 'shared']) {
      expect(
          visibleContactPhone(
              {'phone': ' $_phone ', 'phone_visibility': visibility}),
          _phone);
    }
  });

  testWidgets(
      'initial confirmation shares only the viewer phone and never requests a contact phone',
      (tester) async {
    final server = _Server()..loading = Completer<void>();
    await _withPanel(tester, server, (controller) async {
      expect(controller.loaded, isFalse);
      expect(controller.confirmationPayload, isEmpty);
      expect(server.writes, isEmpty);
      server.loading!.complete();
      await tester.pumpAndSettle();
      expect(_checkbox(tester, _shareLabel).value, isTrue);
      expect(find.text(_requestLabel), findsNothing);
      expect(find.text('בקש מספר טלפון'), findsNothing);
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(controller.confirmationPayload, {'share_my_phone': true});
      expect(controller.confirmationLabel(), 'אשר סינון ושתף טלפון');
      expect(server.writes, isEmpty);
      final result = await updatePhoneSharing(
          _api, 'test-token', _contact, controller.confirmationPayload);
      controller.apply(result);
      await tester.pumpAndSettle();
      expect(server.choices, [
        {'share_my_phone': true}
      ]);
      expect(server.status['request_state'], 'none');
    }, initialChoice: true, settle: false);
  });

  testWidgets(
      'clearing initial sharing only changes the eventual confirmation payload',
      (tester) async {
    final server = _Server();
    await _withPanel(tester, server, (controller) async {
      await tester.tap(find.text(_shareLabel));
      await tester.pump();
      expect(_checkbox(tester, _shareLabel).value, isFalse);
      expect(find.text(_requestLabel), findsNothing);
      expect(controller.confirmationPayload, {'share_my_phone': false});
      expect(controller.confirmationLabel(), 'אשר סינון ללא שיתוף טלפון');
      expect(server.writes, isEmpty);
    }, initialChoice: true);
  });

  testWidgets(
      'reopening an existing contact respects a previously declined sharing choice',
      (tester) async {
    final server = _Server({'request_state': 'revoked'});
    await _withPanel(tester, server, (controller) async {
      expect(controller.selectedShare, isFalse);
      expect(_checkbox(tester, _shareLabel).value, isFalse);
      expect(find.text(_requestLabel), findsNothing);
      expect(find.text('בקש מספר טלפון'), findsOneWidget);
      expect(server.writes, isEmpty);
    });
  });

  testWidgets('hidden and legacy raw numbers never appear in the panel',
      (tester) async {
    final server = _Server({'phone': _phone, 'phone_visibility': 'hidden'});
    await _withPanel(tester, server, (controller) async {
      expect(find.text(_phone), findsNothing);
      expect(find.text('הטלפון לא שותף'), findsOneWidget);
      expect(controller.data!['phone'], isNull);
      expect(find.text('חבר בתשובה'), findsOneWidget);
      expect(server.writes, isEmpty);
    });
  });

  testWidgets(
      'compact filter panel shows only the viewer sharing choice',
      (tester) async {
    final server = _Server({'phone': _phone, 'phone_visibility': 'hidden'});
    await _withPanel(tester, server, (controller) async {
      expect(find.text('חבר בתשובה'), findsNothing);
      expect(find.text('הטלפון לא שותף'), findsNothing);
      expect(find.text(_phone), findsNothing);
      expect(find.text(_shareLabel), findsOneWidget);
      expect(find.text(_requestLabel), findsNothing);
      expect(find.text('בקש מספר טלפון'), findsNothing);
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(
          find.text(
              'הבקשה תישלח רק בלחיצה על האישור; השיתוף תלוי באישור של $_contactName'),
          findsNothing);
      expect(find.text('השיתוף יבוצע רק לאחר לחיצה על כפתור האישור'),
          findsOneWidget);
      expect(controller.confirmationPayload, {'share_my_phone': true});
      expect(server.writes, isEmpty);
      await tester.tap(find.text(_shareLabel));
      await tester.pump();
      expect(controller.confirmationPayload, {'share_my_phone': false});
      expect(server.writes, isEmpty);
    }, initialChoice: true, compact: true);
  });

  testWidgets(
      'compact panel fits a narrow screen with a long name and is shorter than the full panel',
      (tester) async {
    const name = 'דנה לוי כהן מהקבוצה השכונתית';
    final heights = <bool, double>{};
    for (final compact in [false, true]) {
      final server = _Server();
      await _withPanel(tester, server, (controller) async {
        expect(find.text('אני מסכים לשתף את מספר הטלפון שלי עם $name'),
            findsOneWidget);
        expect(find.text('בקש מ$name לשתף את מספר הטלפון'), findsNothing);
        final size = tester.getSize(find.byType(PhoneSharingPanel));
        expect(size.width, lessThanOrEqualTo(360));
        heights[compact] = size.height;
        expect(tester.takeException(), isNull,
            reason: 'Long names must wrap without a layout overflow.');
        expect(server.writes, isEmpty);
      }, initialChoice: true, compact: compact, width: 360, contactName: name);
    }
    expect(heights[true], lessThan(heights[false]!));
  });

  for (final visibility in ['known', 'shared']) {
    testWidgets(
        '$visibility phone is visible while merely opening does not share the viewer phone',
        (tester) async {
      final server = _Server({
        'phone': _phone,
        'phone_visibility': visibility,
        'can_request_phone': false,
        'contact_source': visibility == 'known' ? 'phone_import' : 'in_app'
      });
      await _withPanel(tester, server, (controller) async {
        expect(find.text(_phone), findsOneWidget);
        expect(find.text(visibility == 'known' ? 'מהטלפון שלי' : 'חבר בתשובה'),
            findsOneWidget);
        expect(find.text('בקש מספר טלפון'), findsNothing);
        expect(controller.selectedShare, isFalse);
        expect(server.writes, isEmpty);
      });
    });
  }

  testWidgets(
      'explicit request sends one request and renders the pending state',
      (tester) async {
    final server = _Server()..wrapped = true;
    await _withPanel(tester, server, (controller) async {
      expect(server.writes, isEmpty);
      await tester.tap(find.text('בקש מספר טלפון'));
      await tester.pumpAndSettle();
      expect(server.choices, [
        {'request_phone': true}
      ]);
      expect(controller.data!['request_state'], 'pending');
      final pending = find.widgetWithText(
          OutlinedButton, 'הבקשה למספר טלפון ממתינה לאישור');
      expect(tester.widget<OutlinedButton>(pending).onPressed, isNull);
      expect(find.text(_phone), findsNothing);
    });
  });

  for (final approve in [true, false]) {
    testWidgets(
        'incoming request changes only after explicit ${approve ? 'approval' : 'decline'}',
        (tester) async {
      final server = _Server({'incoming_request': true});
      await _withPanel(tester, server, (controller) async {
        expect(find.text('בקשה לקבלת מספר הטלפון שלך מאת $_contactName'),
            findsOneWidget);
        expect(controller.selectedShare, isFalse);
        expect(server.writes, isEmpty);
        await tester.tap(
            find.text(approve ? 'אשר ושתף את הטלפון שלי' : 'דחה בקשת טלפון'));
        await tester.pumpAndSettle();
        expect(server.choices, [
          {'phone_response': approve ? 'approve' : 'decline'}
        ]);
        expect(controller.data!['share_my_phone'], approve);
        expect(controller.selectedShare, approve);
        expect(find.text('בקשה לקבלת מספר הטלפון שלך מאת $_contactName'),
            findsNothing);
      });
    });
  }

  testWidgets(
      'explicit revocation clears the grant and reloads when the API returns only an acknowledgement',
      (tester) async {
    final server = _Server({'share_my_phone': true})
      ..emptyUpdateResponse = true;
    await _withPanel(tester, server, (controller) async {
      expect(controller.selectedShare, isTrue);
      await tester.tap(find.text('בטל שיתוף של הטלפון שלי'));
      await tester.pumpAndSettle();
      expect(server.choices, [
        {'share_my_phone': false}
      ]);
      expect(controller.selectedShare, isFalse);
      expect(controller.data!['share_my_phone'], isFalse);
      expect(find.text('בטל שיתוף של הטלפון שלי'), findsNothing);
      expect(server.requests.where((request) => request.method == 'GET').length,
          greaterThanOrEqualTo(2));
    });
  });

  testWidgets(
      'a revoked target phone disappears after the contact metadata refresh event',
      (tester) async {
    final server = _Server({
      'phone': _phone,
      'phone_visibility': 'shared',
      'request_state': 'approved',
      'can_request_phone': false
    });
    await _withPanel(tester, server, (controller) async {
      expect(find.text(_phone), findsOneWidget);
      server.status = _status({'phone': _phone, 'request_state': 'revoked'});
      phoneSharingChanges.add(_contact);
      await tester.pumpAndSettle();
      expect(find.text(_phone), findsNothing);
      expect(find.text('הטלפון לא שותף'), findsOneWidget);
      expect(controller.data!['phone'], isNull);
      expect(server.writes, isEmpty);
    });
  });

  testWidgets(
      'missing viewer phone explains the limitation and creates no false sharing payload',
      (tester) async {
    final server = _Server({
      'can_share_my_phone': false,
      'share_unavailable_reason': 'missing_phone',
      'can_request_phone': false
    });
    await _withPanel(tester, server, (controller) async {
      expect(find.textContaining('להוספת מספר טלפון יש לעדכן את הפרופיל'),
          findsOneWidget);
      expect(find.text(_shareLabel), findsNothing);
      expect(controller.confirmationPayload, isEmpty);
      expect(controller.confirmationLabel(), 'שמור סינון');
      expect(server.writes, isEmpty);
    }, initialChoice: true);
  });

  testWidgets(
      'minor metadata exposes neither consent checkbox nor request action',
      (tester) async {
    final server =
        _Server({'can_share_my_phone': false, 'can_request_phone': false});
    await _withPanel(tester, server, (controller) async {
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('בקש מספר טלפון'), findsNothing);
      expect(find.text(_requestLabel), findsNothing);
      expect(controller.confirmationPayload, isEmpty);
      expect(server.writes, isEmpty);
    }, initialChoice: true);
  });

  testWidgets(
      'load failure offers a retry without sending or preselecting a grant',
      (tester) async {
    final server = _Server()..failGet = true;
    await _withPanel(tester, server, (controller) async {
      expect(find.textContaining('נסה שוב'), findsOneWidget);
      expect(controller.loaded, isFalse);
      expect(controller.confirmationPayload, isEmpty);
      expect(server.writes, isEmpty);
      server.failGet = false;
      await tester.tap(find.textContaining('נסה שוב'));
      await tester.pumpAndSettle();
      expect(controller.loaded, isTrue);
      expect(server.writes, isEmpty);
    }, initialChoice: true);
  });

  testWidgets('a failed explicit update never marks a request as pending',
      (tester) async {
    final server = _Server()..failPut = true;
    await _withPanel(tester, server, (controller) async {
      await tester.tap(find.text('בקש מספר טלפון'));
      await tester.pumpAndSettle();
      expect(server.choices, [
        {'request_phone': true}
      ]);
      expect(controller.data!['request_state'], 'none');
      expect(find.text('העדכון נכשל'), findsOneWidget);
      expect(find.text('הבקשה למספר טלפון ממתינה לאישור'), findsNothing);
    });
  });

  testWidgets('a refresh failure hides a previously granted phone immediately',
      (tester) async {
    final server = _Server({'phone': _phone, 'phone_visibility': 'shared'});
    await _withPanel(tester, server, (controller) async {
      expect(find.text(_phone), findsOneWidget);
      server.failGet = true;
      phoneSharingChanges.add(_contact);
      await tester.pumpAndSettle();
      expect(find.text(_phone), findsNothing);
      expect(controller.data!['phone'], isNull);
      expect(find.text('הטלפון לא שותף'), findsOneWidget);
      expect(server.writes, isEmpty);
    });
  });

  testWidgets(
      'clearing consent for an incoming request queues only a decline for later confirmation',
      (tester) async {
    final server = _Server({'incoming_request': true});
    await _withPanel(tester, server, (controller) async {
      await tester.tap(find.text(_shareLabel));
      await tester.pump();
      expect(controller.confirmationPayload,
          {'share_my_phone': false, 'phone_response': 'decline'});
      expect(server.writes, isEmpty);
    }, initialChoice: true);
  });

  for (final consent in [true, false]) {
    testWidgets(
        'contact filter screen persists ${consent ? 'selected' : 'cleared'} choices only on its explicit save button',
        (tester) async {
      final server = _Server()..api = app.kApi;
      final savedBodies = <Map<String, dynamic>>[];
      const filter = {
        'text': true,
        'video': true,
        'nonHumanImages': true,
        'men': true,
        'women': true,
        'children': true,
      };
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await http.runWithClient(() async {
        try {
          await tester.pumpWidget(MaterialApp(
            theme: ThemeData(fontFamily: 'NotoSansHebrew'),
            home: Builder(
                builder: (context) => Scaffold(
                      body: FilledButton(
                        onPressed: () =>
                            Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => const app.ContentFilterSettingsScreen(
                            token: 'test-token',
                            contactId: _contact,
                            contactName: _contactName,
                            currentUserId: 'current-user',
                          ),
                        )),
                        child: const Text('פתח הגדרות חבר'),
                      ),
                    )),
          ));
          await tester.tap(find.text('פתח הגדרות חבר'));
          await tester.pumpAndSettle();
          expect(find.byType(PhoneSharingPanel), findsOneWidget);
          expect(
              tester
                  .widget<PhoneSharingPanel>(find.byType(PhoneSharingPanel))
                  .compact,
              isTrue);
          expect(find.text('חבר בתשובה'), findsNothing);
          expect(find.text('הטלפון לא שותף'), findsNothing);
          expect(find.text('טקסט'), findsNothing);
          expect(find.text('תמונות נוף או חפצים'), findsNothing);
          expect(find.text('גברים'), findsOneWidget);
          expect(find.text('נשים'), findsOneWidget);
          expect(find.text('וידאו'), findsOneWidget);
          expect(_checkbox(tester, _shareLabel).value, isTrue);
          expect(find.text(_requestLabel), findsNothing);
          expect(find.text('בקש מספר טלפון'), findsNothing);
          expect(server.writes, isEmpty);
          expect(savedBodies, isEmpty);
          if (!consent) {
            await tester.ensureVisible(find.text(_shareLabel));
            await tester.pumpAndSettle();
            await tester.tap(find.text(_shareLabel));
            await tester.pump();
          }
          final save = find.text(consent
              ? 'אשר סינון ושתף טלפון'
              : 'אשר סינון ללא שיתוף טלפון');
          await tester.ensureVisible(save);
          await tester.pumpAndSettle();
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(savedBodies, [
            {
              'filter': filter,
              'share_my_phone': consent,
            }
          ]);
          expect(server.writes, isEmpty,
              reason:
                  'The existing filter save carries all consent choices atomically.');
          expect(find.text('פתח הגדרות חבר'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
        }
      },
          () => MockClient((request) async {
                if (request.url.path.endsWith('/phone-sharing')) {
                  return server.respond(request);
                }
                expect(
                    request.url.path
                        .endsWith('/contacts/$_contact/filter-settings'),
                    isTrue);
                if (request.method == 'PUT') {
                  savedBodies
                      .add(jsonDecode(request.body) as Map<String, dynamic>);
                  return http.Response('{"ok":true}', 200);
                }
                expect(request.method, 'GET');
                return http.Response(
                    jsonEncode({
                      'filter': filter,
                      'requiresChoice': true,
                      'inherited': false,
                      'generalFilter': filter
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8'
                    });
              }));
    });
  }

  testWidgets(
      'privacy settings revoke a listed grant only after clicking its action',
      (tester) async {
    final server = _Server({'share_my_phone': true});
    var granted = true;
    await http.runWithClient(() async {
      try {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSansHebrew'),
          home: const PhoneSharingPrivacyScreen(api: _api, token: 'test-token'),
        ));
        await tester.pumpAndSettle();
        expect(find.text('חבר בעל הרשאה'), findsOneWidget);
        expect(server.writes, isEmpty);
        await tester.tap(find.text('בטל הרשאה'));
        await tester.pumpAndSettle();
        expect(server.choices, [
          {'share_my_phone': false}
        ]);
        expect(find.text('חבר בעל הרשאה'), findsNothing);
        expect(find.text('אין כרגע הרשאות שיתוף פעילות'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/phone-sharing/grants')) {
                return http.Response(
                    jsonEncode({
                      'grants': granted
                          ? [
                              {'user_id': _contact, 'name': 'חבר בעל הרשאה'}
                            ]
                          : []
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8'
                    });
              }
              if (request.url.path.endsWith('/phone-sharing/requests')) {
                return http.Response('{"requests":[]}', 200);
              }
              final response = await server.respond(request);
              if (request.method == 'PUT') granted = false;
              return response;
            }));
  });
}
