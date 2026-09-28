import 'dart:convert';
import 'package:betshuva/main.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

const reason =
    'לא ניתן להעביר 1 מתוך 2 פריטים: תוכן הכולל ילדים חסום — לפי הגדרות הנמען.';
const blockedKey = ValueKey('forward-target-user:blocked');
const openKey = ValueKey('forward-target-user:open');

Future<BuildContext> mount(WidgetTester tester) async {
  late BuildContext context;
  await tester
      .pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) {
    context = c;
    return const SizedBox();
  }))));
  return context;
}

void main() {
  for (final mouse in [true, false]) {
    testWidgets(
        'blocked destination is disabled and explains filtering via ${mouse ? 'hover' : 'tap'}',
        (tester) async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/forward/filter-preview')) {
          return jsonResponse({
            'targets': [
              {
                'kind': 'user',
                'id': 'blocked',
                'status': 'blocked',
                'reason': reason
              },
              {'kind': 'user', 'id': 'open', 'status': 'allowed'},
            ]
          });
        }
        if (request.url.path.endsWith('/users')) {
          return jsonResponse([
            {'id': 'blocked', 'name': 'Restricted'},
            {'id': 'open', 'name': 'Available'},
          ]);
        }
        return jsonResponse([]);
      });
      addTearDown(client.close);
      final context = await mount(tester);
      final result = forwardChatMessages(
          context,
          'token',
          null,
          [
            {
              'fileUrl': '/approved-image',
              'fileType': 'image',
              'status': 'rejected_scan',
              'forwardAllowed': true
            },
            {'text': 'hello'},
          ],
          client: client,
          initialRecipientId: null);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(find.byKey(blockedKey)).onChanged,
          isNull);
      await tester.tap(find.byKey(blockedKey));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(find.byKey(blockedKey)).value,
          isFalse);
      final marker = find.byKey(const ValueKey('forward-filter-user:blocked'));
      if (mouse) {
        final gesture =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        await gesture.moveTo(tester.getCenter(marker));
        await tester.pump(const Duration(seconds: 1));
      } else {
        await tester.tap(marker);
        await tester.pumpAndSettle();
      }
      expect(find.text(reason), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(find.byKey(blockedKey)).value,
          isFalse);
      expect(tester.widget<CheckboxListTile>(find.byKey(openKey)).onChanged,
          isNotNull);
      await tester.tap(find.byKey(openKey));
      await tester.pumpAndSettle();
      expect(
          tester.widget<CheckboxListTile>(find.byKey(openKey)).value, isTrue);
      expect(
          requests
              .where((r) => r.method == 'POST')
              .every((r) => r.url.path.endsWith('/filter-preview')),
          isTrue);
      await tester.tap(find.byTooltip('ביטול העברה'));
      await tester.pumpAndSettle();
      expect((await result).cancelled, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'failed preview remains unknown; retry clears a selection that becomes blocked',
      (tester) async {
    var failed = true;
    var sends = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/forward/filter-preview')) {
        if (failed) return jsonResponse({}, 503);
        return jsonResponse({
          'targets': [
            {
              'kind': 'user',
              'id': 'open',
              'status': 'blocked',
              'reason': reason
            },
          ]
        });
      }
      if (request.method != 'GET') sends++;
      if (request.url.path.endsWith('/users')) {
        return jsonResponse([
          {'id': 'open', 'name': 'Available'}
        ]);
      }
      return jsonResponse([]);
    });
    addTearDown(client.close);
    final context = await mount(tester);
    final result = forwardChatMessages(
        context,
        'token',
        null,
        [
          {'fileUrl': '/image', 'fileType': 'image'}
        ],
        client: client);
    await tester.pumpAndSettle();
    expect(find.text('הסינון טרם נבדק'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byKey(openKey)).onChanged,
        isNotNull);
    await tester.tap(find.byKey(openKey));
    await tester.pumpAndSettle();
    failed = false;
    await tester.tap(find.byKey(const ValueKey('forward-target-retry')));
    await tester.pumpAndSettle();
    final tile = tester.widget<CheckboxListTile>(find.byKey(openKey));
    expect(tile.value, isFalse);
    expect(tile.onChanged, isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    expect(sends, 0);
    await tester.tap(find.byTooltip('ביטול העברה'));
    await tester.pumpAndSettle();
    expect((await result).cancelled, isTrue);
  });

  testWidgets('direct recipient blocked by filter is never preselected',
      (tester) async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/forward/filter-preview')) {
        return jsonResponse({
          'targets': [
            {
              'kind': 'user',
              'id': 'blocked',
              'status': 'blocked',
              'reason': reason
            },
          ]
        });
      }
      if (request.url.path.endsWith('/users')) {
        return jsonResponse([
          {'id': 'blocked', 'name': 'Restricted'}
        ]);
      }
      return jsonResponse([]);
    });
    addTearDown(client.close);
    final context = await mount(tester);
    final result = forwardChatMessages(
        context,
        'token',
        null,
        [
          {'fileUrl': '/image', 'fileType': 'image'}
        ],
        client: client,
        initialRecipientId: 'blocked');
    await tester.pumpAndSettle();
    expect(
        tester.widget<CheckboxListTile>(find.byKey(blockedKey)).value, isFalse);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await tester.tap(find.byTooltip('ביטול העברה'));
    await tester.pumpAndSettle();
    expect((await result).cancelled, isTrue);
  });
}
