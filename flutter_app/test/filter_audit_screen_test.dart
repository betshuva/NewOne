import 'dart:async';
import 'dart:convert';

import 'package:betshuva/filter_audit_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object value) => http.Response(
      jsonEncode(value),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> _event(String id) => {
      'id': id,
      'created_at': '2026-09-17T00:31:54.796Z',
      'kind': 'filter_changed',
      'user_name': 'אביב אליהו',
      'scope_type': 'general',
      'details': {
        'before': {'men': true},
        'after': {'men': false},
      },
    };

Future<void> _mount(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const MaterialApp(
    home: FilterAuditScreen(
      api: 'https://example.test/api',
      token: 'test-admin-token',
    ),
  ));
}

void main() {
  testWidgets('user search, before/after and paging preserve applied filters',
      (tester) async {
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      expect(find.text('גברים: מותר ← חסום'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('filter-audit-select-user')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('filter-audit-user-search')), 'AVIV@');
      await tester.pumpAndSettle();
      expect(find.text('יניב אליהו'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('filter-audit-user-aviv')));
      await tester.pumpAndSettle();
      expect(requests.last.url.queryParameters['userId'], 'aviv');

      await tester.enterText(
          find.byKey(const ValueKey('filter-audit-message-id')), 'message-id');
      await tester.tap(find.text('הצג היסטוריה'));
      await tester.pumpAndSettle();
      expect(requests.last.url.queryParameters['messageId'], 'message-id');
      await tester.enterText(
          find.byKey(const ValueKey('filter-audit-message-id')), 'unsaved-id');
      final more = find.byKey(const ValueKey('filter-audit-more'));
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(requests.last.url.queryParameters['messageId'], 'message-id');
      expect(requests.last.url.queryParameters['before'], '20');
      expect(
          find.byKey(const ValueKey('filter-audit-event-20')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('filter-audit-event-19')), findsOneWidget);
      expect(find.byKey(const ValueKey('filter-audit-more')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async {
              expect(
                  request.headers['Authorization'], 'Bearer test-admin-token');
              if (request.url.path.endsWith('/admin/users')) {
                return _json([
                  {
                    'id': 'aviv',
                    'name': 'אביב אליהו',
                    'email': 'aviv@example.test'
                  },
                  {
                    'id': 'yaniv',
                    'name': 'יניב אליהו',
                    'email': 'yaniv@example.test'
                  },
                ]);
              }
              requests.add(request);
              final more = request.url.queryParameters.containsKey('before');
              return _json({
                'events': [_event(more ? '19' : '20')],
                'nextCursor': more ? null : '20',
                'recordingStartedAt': '2026-09-17T00:00:00Z',
              });
            }));
  });

  testWidgets('late timeline results do not overwrite a refreshed selection',
      (tester) async {
    final firstResponse = Completer<http.Response>();
    var timelineRequests = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pump();
      await tester.tap(find.byTooltip('רענן היסטוריה'));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('filter-audit-event-200')), findsOneWidget);
      firstResponse.complete(_json({
        'events': [_event('100')],
        'nextCursor': null,
      }));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('filter-audit-event-200')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('filter-audit-event-100')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/admin/users')) return _json([]);
              timelineRequests++;
              if (timelineRequests == 1) return firstResponse.future;
              return _json({
                'events': [_event('200')],
                'nextCursor': null,
              });
            }));
  });

  testWidgets('browser report details stay text and distinguish reporting',
      (tester) async {
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      expect(find.text('דיווח מהדפדפן: תמונה הוצגה'), findsOneWidget);
      expect(find.textContaining('זמן המכשיר אינו מאומת'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await tester.tap(find.text('פרטי האירוע, גרסאות הסינון וזמן UTC'));
      await tester.pumpAndSettle();
      expect(find.textContaining('<img src=x onerror=bad()>'), findsOneWidget);
      expect(find.textContaining('2026-09-17T00:31:54.796Z'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/admin/users')) return _json([]);
              return _json({
                'events': [
                  {
                    ..._event('1'),
                    'kind': 'client_displayed',
                    'details': {'clientTime': '<img src=x onerror=bad()>'},
                  },
                ],
                'nextCursor': null,
              });
            }));
  });
}
