import 'dart:convert';
import 'package:betshuva/system_audit_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});
void main() {
  for (final all in [false, true]) {
    testWidgets(
        all
            ? 'all-audit confirmation uses one snapshot through every batch'
            : 'selected audit rows require confirmation and show first-step numbering',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(4400, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requests = <Map<String, dynamic>>[];
      final root = <String, dynamic>{
        'id': '00000000-0000-4000-8000-000000000001',
        'action': 'upload_file',
        'root_event_id': '1',
        'created_at': '2026-09-24T09:00:00Z',
        'event_count': '3',
        'sub_event_count': '2'
      };
      final event = <String, dynamic>{
        'id': '2',
        'operation_id': root['id'],
        'kind': 'media_stored',
        'created_at': root['created_at'],
        'sub_event_index': '1',
        'sub_event_total': '2'
      };
      root['first_sub_event'] = event;
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(
            home: SystemAuditScreen(
                api: 'https://audit.test/api', token: 'mock')));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 מתוך 2'), findsOneWidget);
        expect(find.text('פעולת משנה'), findsOneWidget);
        if (!all) {
          await tester
              .tap(find.byKey(const ValueKey('system-audit-select-events:2')));
          await tester.pumpAndSettle();
        }
        final button = find.byKey(ValueKey(
            all ? 'system-audit-delete-all' : 'system-audit-delete-selected'));
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('system-audit-bulk-dialog')),
            findsOneWidget);
        await tester.tap(find.text('ביטול'));
        await tester.pumpAndSettle();
        expect(requests, isEmpty);
        await tester.tap(button);
        await tester.pumpAndSettle();
        await tester
            .tap(find.byKey(const ValueKey('system-audit-bulk-confirm')));
        await tester.pumpAndSettle();
        expect(requests, hasLength(all ? 2 : 1));
        if (all) {
          expect(requests[0]['through'], '3');
          expect(requests[1], requests[0]);
          expect(requests[0]['confirm'], 'DELETE_ALL_AUDIT');
        } else {
          expect(requests.single['events'], ['2']);
          expect(requests.single['operations'], isEmpty);
          expect(requests.single['confirm'], 'DELETE_SELECTED_AUDIT');
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
          () => MockClient((request) async {
                if (request.url.path.endsWith('/catalog')) {
                  return json({
                    'canDelete': true,
                    'actions': [],
                    'statuses': [],
                    'categories': []
                  });
                }
                if (request.url.path.endsWith('/deletion-preview')) {
                  return json(
                      {'through': '3', 'operations': '1', 'events': '3'});
                }
                if (request.method == 'DELETE') {
                  requests.add(Map<String, dynamic>.from(
                      jsonDecode(request.body) as Map));
                  return json({
                    'deleted': true,
                    'deletedEvents': 1,
                    'deletedOperations': all ? 1 : 0,
                    'remaining': all && requests.length == 1 ? '1' : '0'
                  });
                }
                if (request.url.path.endsWith('/events')) {
                  return json({
                    'events': [event]
                  });
                }
                return json({
                  'operations': requests.isEmpty ? [root] : []
                });
              }));
    });
  }
}
