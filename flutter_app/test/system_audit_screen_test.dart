import 'dart:async';
import 'dart:convert';

import 'package:betshuva/system_audit_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _catalog = {
  'actions': [
    {'action': 'message.send', 'label': 'שליחת הודעה', 'category': 'messages'}
  ],
  'statuses': [
    {'code': 'stored', 'label': 'נשמר בשרת'},
    {'code': 'failed', 'label': 'נכשל'}
  ],
  'categories': [
    {'code': 'messages', 'label': 'הודעות'}
  ],
  'recordingStartedAt': '2026-09-24T08:00:00Z',
  'coverage': [
    {'code': 'explicit', 'label': 'תיעוד מפורש', 'status': 'active'}
  ],
};
const _safeSearchResult = 'הבדיקה הושלמה · תוכן למבוגרים: סבירות נמוכה מאוד · '
    'חשיפה: סבירות נמוכה מאוד · אלימות: סבירות נמוכה · תוכן רפואי: לא ידוע · '
    'זיוף או שינוי חזותי: אפשרי';
http.Response _json(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
Map<String, dynamic> _operation(String id) => {
      'id': id,
      'created_at': '2026-09-24T09:00:00Z',
      'action': 'message.send',
      'initiator_id': 'user-a',
      'initiator_name': 'Test User',
      'initiator_short_id': 7,
      'target_type': 'user',
      'target_id': 'user-b',
      'source': 'http',
      'status': 'stored',
      'event_count': 2,
      'duration_ms': 12,
    };
Map<String, dynamic> _event(String id) => {
      'id': id,
      'operation_id': 'operation-1',
      'parent_event_id': 'event-parent',
      'created_at': '2026-09-24T09:00:01.042Z',
      'kind': 'message_persisted',
      'executor_type': 'service',
      'executor_id': 'storage',
      'source': 'worker',
      'status': 'stored',
      'attempt': 1,
      'details': {
        'affectedCount': 1,
        'token': 'must-not-display',
        'before': false,
        'after': true
      },
    };
Finder _key(String id) => find.byKey(ValueKey('system-audit-$id'));

Future<void> _mount(WidgetTester tester,
    {Size size = const Size(1500, 1100), String token = 'admin-test'}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      home: SystemAuditScreen(api: 'https://example.test/api', token: token)));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  expect(tester.takeException(), isNull);
}

Map<String, dynamic> _timedOperation(int value,
        {String status = 'stored', int count = 2}) =>
    {
      ..._operation('operation-${value.toString().padLeft(3, '0')}'),
      'created_at': DateTime.utc(2026, 9, 24, 9, 0, value).toIso8601String(),
      'status': status,
      'event_count': count,
    };

Future<void> _poll(WidgetTester tester, [int seconds = 5]) async {
  await tester.pump(Duration(seconds: seconds));
  await tester.pumpAndSettle();
}

void main() {
  for (final eventsMode in [false, true]) {
    testWidgets(
        '${eventsMode ? 'all events' : 'expanded children'} show semantic checks without inventing old outcomes',
        (tester) async {
      await http.runWithClient(() async {
        await _mount(tester, size: const Size(2500, 1200));
        await tester.pumpAndSettle();
        expect(find.text('מה נבדק'), findsOneWidget);
        expect(find.text('תוצאת הבדיקה'), findsOneWidget);
        final parentResult = find.descendant(
            of: _key('check-result-operation-1'), matching: find.text('-'));
        expect(parentResult, findsOneWidget);
        await _tap(tester,
            eventsMode ? find.text('כל האירועים') : _key('expand-operation-1'));
        expect(find.text('זיהוי פנים'), findsOneWidget);
        expect(find.text('זוהו 2 פנים'), findsOneWidget);
        expect(
            find.text('Google Vision · פריים 3 · 1.250 שניות'), findsOneWidget);
        expect(find.text('בדיקת צניעות הלבוש'), findsNWidgets(2));
        expect(find.text('תוצאה לא תועדה'), findsNWidgets(2));
        expect(find.text('תוצאה לא ודאית'), findsOneWidget);
        expect(find.byTooltip(_safeSearchResult), findsOneWidget,
            reason:
                'The full five-category result stays available beyond the compact cell');
        expect(find.text('unknown_result_do_not_render'), findsNothing);
        final oldResult = find.descendant(
            of: _key('check-result-3'), matching: find.text('תוצאה לא תועדה'));
        expect(oldResult, findsOneWidget,
            reason: 'A completed provider call does not imply a passed check');
        final tables = tester.widgetList<Table>(find.byType(Table)).toList();
        for (final table in tables) {
          expect(
              table.children.single.children, hasLength(eventsMode ? 13 : 15));
        }
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      },
          () => MockClient((request) async {
                if (request.url.path.endsWith('/catalog')) {
                  return _json(_catalog);
                }
                if (request.url.path.endsWith('/operations')) {
                  return _json({
                    'operations': [_operation('operation-1')]
                  });
                }
                return _json({
                  'events': [
                    {
                      ..._event('2'),
                      'kind': 'provider_call_finished',
                      'checkLabel': 'זיהוי פנים',
                      'checkResultLabel': 'זוהו 2 פנים',
                      'details': {
                        'provider': 'google_vision',
                        'frameIndex': 2,
                        'frameTimestampMs': 1250,
                        'checkType': 'face_detection',
                        'checkOutcome': 'passed',
                      },
                    },
                    {
                      ..._event('3'),
                      'kind': 'provider_call_finished',
                      'status': 'completed',
                      'details': {'provider': 'openai', 'operation': 'modesty'},
                    },
                    {
                      ..._event('4'),
                      'kind': 'provider_call_finished',
                      'details': {
                        'checkType': 'modesty',
                        'checkOutcome': 'uncertain'
                      },
                    },
                    {
                      ..._event('5'),
                      'kind': 'scan_cache_used',
                      'status': 'observed',
                      'details': {
                        'checkType': 'safe_search',
                        'checkOutcome': 'unknown_result_do_not_render'
                      },
                    },
                    {
                      ..._event('6'),
                      'kind': 'moderation_check_finished',
                      'checkLabel': 'תוכן למבוגרים, חשיפה, אלימות, רפואה וזיוף',
                      'checkResultLabel': _safeSearchResult,
                      'details': {
                        'checkType': 'safe_search',
                        'checkOutcome': 'passed'
                      },
                    },
                  ]
                });
              }));
    });

    testWidgets(
        '${eventsMode ? 'all events' : 'operations'} filter check type and outcome independently',
        (tester) async {
      final requests = <http.Request>[];
      await http.runWithClient(() async {
        await _mount(tester, size: const Size(2500, 1100));
        await tester.pumpAndSettle();
        if (eventsMode) await _tap(tester, find.text('כל האירועים'));
        await _tap(tester, _key('column-check_type'));
        expect(requests.last.url.queryParameters['column'], 'check_type');
        expect(requests.last.url.queryParameters['mode'],
            eventsMode ? 'events' : 'operations');
        await _tap(tester, _key('column-option-0'));
        await _tap(tester, _key('column-apply'));
        expect(find.byTooltip('סינון מה נבדק (פעיל)'), findsOneWidget);
        await _tap(tester, _key('column-check_outcome'));
        expect(requests.last.url.queryParameters['column'], 'check_outcome');
        await _tap(tester, _key('column-option-0'));
        await _tap(tester, _key('column-apply'));
        expect(find.byTooltip('סינון תוצאת הבדיקה (פעיל)'), findsOneWidget);
        expect(
            jsonDecode(requests.last.url.queryParameters['columnFilters']!), {
          'check_type': {
            'values': ['face_detection'],
            'exclude': true
          },
          'check_outcome': {
            'values': ['uncertain'],
            'exclude': true
          },
        });
        if (!eventsMode) {
          await _tap(tester, _key('expand-operation-1'));
          expect(requests.last.url.queryParameters.containsKey('columnFilters'),
              isTrue);
          expect(_key('event-2'), findsOneWidget);
        }
        await _unmount(tester);
      },
          () => MockClient((request) async {
                requests.add(request);
                if (request.url.path.endsWith('/catalog')) {
                  return _json(_catalog);
                }
                if (request.url.path.endsWith('/filter-options')) {
                  final type =
                      request.url.queryParameters['column'] == 'check_type';
                  return _json({
                    'options': [
                      {
                        'value': type ? 'face_detection' : 'uncertain',
                        'label': type ? 'זיהוי פנים' : 'תוצאה לא ודאית',
                      }
                    ]
                  });
                }
                return _json({
                  'operations': [_operation('operation-1')],
                  'events': [_event('2')],
                });
              }));
    });
  }

  testWidgets(
      'check result columns remain readable by horizontal scrolling on mobile',
      (tester) async {
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(390, 844));
      await tester.pumpAndSettle();
      await _tap(tester, _key('expand-operation-1'));
      final result = find.descendant(
          of: _key('check-result-2'), matching: find.text('זוהו 2 פנים'));
      await tester.ensureVisible(result);
      await tester.pumpAndSettle();
      final rectangle = tester.getRect(result);
      expect(rectangle.left, greaterThanOrEqualTo(0));
      expect(rectangle.right, lessThanOrEqualTo(390));
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              return _json({
                'operations': [_operation('operation-1')],
                'events': [
                  {
                    ..._event('2'),
                    'checkLabel': 'זיהוי פנים',
                    'checkResultLabel': 'זוהו 2 פנים'
                  }
                ],
              });
            }));
  });

  testWidgets('delete controls are absent without explicit edit permission',
      (tester) async {
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      await _tap(tester, _key('expand-operation-1'));
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      await _tap(tester, find.text('כל האירועים'));
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              expect(request.method, 'GET');
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              return _json({
                'operations': [_operation('operation-1')],
                'events': [_event('2')],
              });
            }));
  });

  testWidgets('delete cancellation does not mutate and pauses polling',
      (tester) async {
    var reads = 0;
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(2300, 1100));
      await tester.pumpAndSettle();
      await _tap(tester, _key('delete-operation-operation-1'));
      expect(find.text('מחיקת פעולה מהיומן'), findsOneWidget);
      expect(
          find.descendant(
              of: _key('delete-dialog'), matching: find.text('ID operation-1')),
          findsOneWidget);
      expect(find.textContaining('הודעות וקבצים לא יימחקו'), findsOneWidget);
      final before = reads;
      await _poll(tester, 12);
      expect(reads, before);
      await _tap(tester, _key('delete-cancel'));
      expect(_key('operation-operation-1'), findsOneWidget);
      await _poll(tester);
      expect(reads, before + 1);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              expect(request.method, 'GET');
              if (request.url.path.endsWith('/catalog')) {
                return _json({..._catalog, 'canDelete': true});
              }
              reads++;
              return _json({
                'operations': [_operation('operation-1')]
              });
            }));
  });

  testWidgets('confirmed primary deletion deletes exactly one audit group',
      (tester) async {
    final deletes = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(2300, 1100));
      await tester.pumpAndSettle();
      await _tap(tester, _key('expand-operation-1'));
      expect(_key('event-2'), findsOneWidget);
      await _tap(tester, _key('delete-operation-operation-1'));
      expect(find.textContaining('וכל פעולות המשנה שלה'), findsOneWidget);
      await _tap(tester, _key('delete-confirm'));
      expect(deletes, hasLength(1));
      expect(
          deletes.single.url.path, '/api/admin/audit/operations/operation-1');
      expect(deletes.single.headers['Authorization'], 'Bearer admin-test');
      expect(
          deletes.single.headers['content-type'], contains('application/json'));
      expect(jsonDecode(deletes.single.body), {'confirmId': 'operation-1'});
      expect(_key('operation-operation-1'), findsNothing);
      expect(_key('event-2'), findsNothing);
      expect(_key('operation-operation-2'), findsOneWidget);
      await _poll(tester);
      expect(deletes, hasLength(1));
      expect(_key('operation-operation-1'), findsNothing);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.method == 'DELETE') {
                deletes.add(request);
                return _json({
                  'deleted': true,
                  'operationId': 'operation-1',
                  'deletedEvents': 2
                });
              }
              if (request.url.path.endsWith('/catalog')) {
                return _json({..._catalog, 'canDelete': true});
              }
              if (request.url.path.endsWith('/events')) {
                return _json({
                  'events': [_event('2')]
                });
              }
              return _json({
                'operations': [
                  if (deletes.isEmpty) _operation('operation-1'),
                  _operation('operation-2'),
                ]
              });
            }));
  });

  testWidgets(
      'single event deletion preserves descendants, expansion and filters',
      (tester) async {
    final deletes = <http.Request>[];
    final queries = <Map<String, String>>[];
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(2300, 1200));
      await tester.pumpAndSettle();
      await tester.enterText(_key('source'), 'http');
      await _tap(tester, _key('apply'));
      await _tap(tester, _key('expand-operation-1'));
      await _tap(tester, _key('delete-event-2'));
      expect(find.textContaining('רק פעולת המשנה שנבחרה'), findsOneWidget);
      await _tap(tester, _key('delete-confirm'));
      expect(deletes, hasLength(1));
      expect(deletes.single.url.path, '/api/admin/audit/events/2');
      expect(deletes.single.headers['Authorization'], 'Bearer admin-test');
      expect(jsonDecode(deletes.single.body), {'confirmId': '2'});
      expect(_key('operation-operation-1'), findsOneWidget);
      expect(_key('event-2'), findsNothing);
      expect(_key('event-3'), findsOneWidget);
      expect(find.text('1 פעולות משנה תועדו'), findsNothing);
      expect(queries.last['source'], 'http');
      await _poll(tester);
      expect(_key('event-3'), findsOneWidget);
      expect(deletes, hasLength(1));
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.method == 'DELETE') {
                deletes.add(request);
                return _json({
                  'deleted': true,
                  'operationId': 'operation-1',
                  'deletedEvents': 1
                });
              }
              if (request.url.path.endsWith('/catalog')) {
                return _json({..._catalog, 'canDelete': true});
              }
              if (request.url.path.endsWith('/events')) {
                return _json({
                  'events': [
                    if (deletes.isEmpty) {..._event('2'), 'root_event_id': '1'},
                    {
                      ..._event('3'),
                      'root_event_id': '1',
                      'parent_event_id': deletes.isEmpty ? '2' : null
                    },
                  ]
                });
              }
              queries.add(request.url.queryParameters);
              return _json({
                'operations': [
                  {
                    ..._operation('operation-1'),
                    'root_event_id': '1',
                    'event_count': deletes.isEmpty ? 3 : 2,
                    'sub_event_count': deletes.isEmpty ? 2 : 1,
                  }
                ]
              });
            }));
  });

  for (final code in [403, 409, 503]) {
    testWidgets(
        'delete HTTP $code preserves the selected row and reports error',
        (tester) async {
      var deletes = 0;
      await http.runWithClient(() async {
        await _mount(tester, size: const Size(2300, 1100));
        await tester.pumpAndSettle();
        await _tap(tester, _key('expand-operation-1'));
        await _tap(tester, _key('delete-event-2'));
        await _tap(tester, _key('delete-confirm'));
        expect(deletes, 1);
        expect(_key('event-2'), findsOneWidget);
        expect(_key('delete-refresh'), findsOneWidget);
        if (code == 403) {
          expect(find.byIcon(Icons.delete_outline), findsNothing);
        }
        if (code == 409) {
          expect(find.textContaining('אירוע ראשי בנפרד'), findsOneWidget);
        }
        await _unmount(tester);
      },
          () => MockClient((request) async {
                if (request.method == 'DELETE') {
                  deletes++;
                  return _json(
                      {'error': code == 409 ? 'AUDIT_ROOT_EVENT' : 'failed'},
                      code);
                }
                if (request.url.path.endsWith('/catalog')) {
                  return _json({..._catalog, 'canDelete': true});
                }
                return _json({
                  'operations': [_operation('operation-1')],
                  'events': [_event('2')]
                });
              }));
    });
  }

  testWidgets('missing audit row refreshes gracefully without a second delete',
      (tester) async {
    var deleted = false;
    var deletes = 0;
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(2300, 1100));
      await tester.pumpAndSettle();
      await _tap(tester, _key('delete-operation-operation-1'));
      await _tap(tester, _key('delete-confirm'));
      expect(_key('operation-operation-1'), findsNothing);
      expect(find.text('הרישום כבר אינו קיים. היומן עודכן'), findsOneWidget);
      expect(_key('delete-refresh'), findsNothing);
      expect(deletes, 1);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.method == 'DELETE') {
                deletes++;
                deleted = true;
                return _json({}, 404);
              }
              if (request.url.path.endsWith('/catalog')) {
                return _json({..._catalog, 'canDelete': true});
              }
              return _json({
                'operations': [if (!deleted) _operation('operation-1')]
              });
            }));
  });

  testWidgets('flat root delete is disabled using exact root ID, not just kind',
      (tester) async {
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(2300, 1100));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('כל האירועים'));
      expect(
          tester.widget<IconButton>(_key('delete-event-1')).onPressed, isNull);
      expect(tester.widget<IconButton>(_key('delete-event-2')).onPressed,
          isNotNull);
      expect(
          tester.widget<IconButton>(_key('delete-event-3')).onPressed, isNull);
      expect(find.byTooltip('מחיקת אירוע ראשי נעשית דרך הפעולה הראשית'),
          findsNWidgets(2));
      await _unmount(tester);
    },
        () => MockClient((request) async {
              expect(request.method, 'GET');
              if (request.url.path.endsWith('/catalog')) {
                return _json({..._catalog, 'canDelete': true});
              }
              return _json({
                'operations': [],
                'events': [
                  {
                    ..._event('1'),
                    'kind': 'operation_started',
                    'root_event_id': '1'
                  },
                  {
                    ..._event('2'),
                    'kind': 'operation_started',
                    'root_event_id': '1'
                  },
                  {..._event('3'), 'kind': 'operation_started'},
                ]
              });
            }));
  });

  testWidgets(
      'busy deletion blocks duplicates and late polling cannot restore rows',
      (tester) async {
    final stale = Completer<http.Response>();
    final deletion = Completer<http.Response>();
    var reads = 0;
    var deletes = 0;
    var deleted = false;
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(2300, 1100));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      expect(reads, 2);
      await _tap(tester, _key('delete-operation-operation-1'));
      await tester.tap(_key('delete-confirm'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(deletes, 1);
      expect(
          tester
              .widget<IconButton>(_key('delete-operation-operation-1'))
              .onPressed,
          isNull);
      await tester.pump(const Duration(seconds: 6));
      expect(reads, 2);
      deleted = true;
      deletion.complete(_json(
          {'deleted': true, 'operationId': 'operation-1', 'deletedEvents': 2}));
      await tester.pumpAndSettle();
      expect(_key('operation-operation-1'), findsNothing);
      stale.complete(_json({
        'operations': [_operation('operation-1')]
      }));
      await tester.pumpAndSettle();
      expect(_key('operation-operation-1'), findsNothing);
      expect(deletes, 1);
      await _poll(tester);
      expect(_key('operation-operation-1'), findsNothing);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.method == 'DELETE') {
                deletes++;
                return deletion.future;
              }
              if (request.url.path.endsWith('/catalog')) {
                return _json({..._catalog, 'canDelete': true});
              }
              reads++;
              if (reads == 2) return stale.future;
              return _json({
                'operations': [if (!deleted) _operation('operation-1')]
              });
            }));
  });

  testWidgets(
      'authentication change cancels deletion confirmation without mutation',
      (tester) async {
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(2300, 1100));
      await tester.pumpAndSettle();
      await _tap(tester, _key('delete-operation-operation-1'));
      await tester.pumpWidget(const MaterialApp(
          home: SystemAuditScreen(
              api: 'https://example.test/api', token: 'viewer')));
      await tester.pumpAndSettle();
      expect(_key('delete-dialog'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              expect(request.method, 'GET');
              if (request.url.path.endsWith('/catalog')) {
                return _json({
                  ..._catalog,
                  'canDelete':
                      request.headers['Authorization'] == 'Bearer admin-test'
                });
              }
              return _json({
                'operations': [_operation('operation-1')]
              });
            }));
  });

  testWidgets(
      'upload labels use explicit media and capture context, never file names',
      (tester) async {
    final uploads = [
      ('video-recorded', 'video', 'camera_video'),
      ('video-uploaded', 'video', null),
      ('photo-recorded', 'image', 'camera_image'),
      ('audio-recorded', 'audio', 'microphone'),
      ('unknown-upload', null, null),
      ('invalid-capture', 'audio', 'camera_video'),
    ];
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(2100, 1400));
      await tester.pumpAndSettle();
      for (final (id, label) in [
        ('video-recorded', 'צילום וידאו'),
        ('video-uploaded', 'העלאת וידאו'),
        ('photo-recorded', 'צילום תמונה'),
        ('audio-recorded', 'הקלטת קול'),
        ('unknown-upload', 'העלאת קובץ'),
        ('invalid-capture', 'העלאת קובץ קול'),
      ]) {
        expect(
            find.descendant(
                of: _key('operation-$id'), matching: find.text(label)),
            findsOneWidget);
      }
      expect(find.text('video-filename.mp4'), findsNothing);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) {
                return _json({
                  ..._catalog,
                  'actions': [
                    {'action': 'upload_file', 'label': 'העלאת קובץ'}
                  ]
                });
              }
              return _json({
                'operations': [
                  for (final (id, media, capture) in uploads)
                    {
                      ..._operation(id),
                      'action': 'upload_file',
                      'media_type': media,
                      'capture_kind': capture,
                      'fileName': 'video-filename.mp4',
                    }
                ]
              });
            }));
  });

  testWidgets(
      'recipient column preserves intended recipient on child rows and flat events',
      (tester) async {
    final recipient = {
      'recipient_type': 'user',
      'recipient_id': 'recipient-user',
      'recipient_name': 'Recipient User',
      'recipient_short_id': 42,
    };
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(2100, 1200));
      await tester.pumpAndSettle();
      expect(find.text('נמען / קבוצה'), findsOneWidget);
      expect(find.text('Recipient User'), findsOneWidget);
      expect(find.text('מיועד למשתמש · ID 42'), findsOneWidget);
      expect(find.text('Recipient Group'), findsOneWidget);
      expect(find.text('מיועד לקבוצה · ID recipient-group'), findsOneWidget);
      await _tap(tester, _key('expand-operation-1'));
      expect(find.text('Recipient User'), findsNWidgets(2));
      expect(find.text('מיועד למשתמש · ID 42'), findsNWidgets(2));
      expect(find.text('נמסר'), findsNothing);
      await _tap(tester, find.text('כל האירועים'));
      expect(find.text('Recipient User'), findsOneWidget);
      expect(find.text('מיועד למשתמש · ID 42'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/events')) {
                return _json({
                  'events': [
                    {..._event('1'), ...recipient}
                  ]
                });
              }
              return _json({
                'operations': [
                  {..._operation('operation-1'), ...recipient},
                  {
                    ..._operation('operation-2'),
                    'recipient_type': 'group',
                    'recipient_id': 'recipient-group',
                    'recipient_name': 'Recipient Group',
                  },
                  _operation('operation-3'),
                ]
              });
            }));
  });

  testWidgets('recipient header filters exact IDs and survives auto refresh',
      (tester) async {
    final operations = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(2100, 1200));
      await tester.pumpAndSettle();
      await _tap(tester, _key('column-recipient_id'));
      expect(find.text('Recipient User (ID 42)'), findsOneWidget);
      await _tap(tester, _key('column-option-0'));
      await _tap(tester, _key('column-apply'));
      final filters =
          jsonDecode(operations.last.url.queryParameters['columnFilters']!);
      expect(filters['recipient_id']['values'], ['recipient-user']);
      await _poll(tester);
      expect(jsonDecode(operations.last.url.queryParameters['columnFilters']!),
          filters);
      expect(find.byTooltip('סינון נמען / קבוצה (פעיל)'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/filter-options')) {
                expect(request.url.queryParameters['column'], 'recipient_id');
                return _json({
                  'options': [
                    {
                      'value': 'recipient-user',
                      'label': 'Recipient User (ID 42)',
                      'count': 1
                    }
                  ]
                });
              }
              operations.add(request);
              return _json({
                'operations': [_operation('operation-1')]
              });
            }));
  });

  testWidgets(
      'hierarchy uses one column grid, exact root exclusion and chronological child rows',
      (tester) async {
    final requests = <http.Request>[];
    final root = {
      ..._operation('operation-1'),
      'root_event_id': '9007199254740990',
      'sub_event_count': 3,
      'latest_event_kind': 'scan_attempt_started',
      'latest_event_status': 'running',
      'latest_event_at': '2026-09-24T09:00:02Z',
    };
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(1900, 1100));
      await tester.pumpAndSettle();
      expect(find.text('3 פעולות משנה תועדו'), findsNothing);
      expect(find.text('תיעוד אחרון: ניסיון סריקה החל (בעיבוד)'), findsNothing);
      expect(find.text('ID user-a'), findsOneWidget);
      await _tap(tester, _key('expand-operation-1'));
      expect(_key('event-9007199254740990'), findsNothing);
      expect(find.text('הפעולה החלה'), findsOneWidget);
      expect(find.text('ניסיון 3'), findsOneWidget);
      expect(find.text('מתחילת הפעולה: 2000 ms'), findsNWidgets(2));
      final first = _key('event-9007199254740995');
      final second = _key('event-9007199254740993');
      final third = _key('event-9007199254740994');
      expect(
          tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(second).dy));
      expect(
          tester.getTopLeft(second).dy, lessThan(tester.getTopLeft(third).dy));
      final tables = tester.widgetList<Table>(find.byType(Table)).toList();
      expect(
          tables, hasLength(5)); // One header, one parent and three children.
      for (final table in tables) {
        expect(table.children.single.children, hasLength(15));
        expect(
            table.columnWidths!.values
                .map((width) => (width as FixedColumnWidth).value),
            tables.first.columnWidths!.values
                .map((width) => (width as FixedColumnWidth).value));
      }
      expect(find.text('פעולה / אירוע קודם'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(requests.last.url.queryParameters,
          {'limit': '50', 'steps': '1', 'previews': '1'});
      await _tap(tester, _key('details-9007199254740994'));
      final detail = tester.widget<SelectableText>(_key('details-json')).data!;
      expect(detail, contains('"attempt": 3'));
      expect(detail, isNot(contains('must-not-display')));
      await _tap(tester, find.text('סגור'));
      await _unmount(tester);
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/operations')) {
                expect(request.url.queryParameters['scope'], 'user');
                expect(request.url.queryParameters['match'], 'items');
                return _json({
                  'operations': [root]
                });
              }
              return _json({
                'events': [
                  {
                    ..._event('9007199254740995'),
                    'created_at': '2026-09-24T09:00:01Z',
                    'kind': 'operation_started'
                  },
                  {
                    ..._event('9007199254740994'),
                    'created_at': '2026-09-24T09:00:02Z',
                    'attempt': 3
                  },
                  {
                    ..._event('9007199254740993'),
                    'created_at': '2026-09-24T09:00:02Z'
                  },
                  {..._event('9007199254740990'), 'kind': 'operation_started'},
                ]
              });
            }));
  });

  testWidgets(
      'operation color is stable, shared by children and independent of status',
      (tester) async {
    var changed = false;
    BoxDecoration decoration(String key) =>
        tester.widget<DecoratedBox>(_key(key)).decoration as BoxDecoration;
    Color rail(String key) => (decoration(key).border! as Border).right.color;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      final original = rail('operation-operation-002');
      expect(original, isNot(rail('operation-operation-001')));
      await _tap(tester, _key('expand-operation-002'));
      expect(rail('event-2'), original);
      expect(decoration('event-2').color!.a,
          lessThan(decoration('operation-operation-002').color!.a));
      changed = true;
      await _poll(tester);
      expect(rail('operation-operation-002'), original);
      expect(rail('event-2'), original);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/events')) {
                return _json({
                  'events': [_event('2')]
                });
              }
              return _json({
                'operations': [
                  if (changed) _timedOperation(3),
                  _timedOperation(2, status: changed ? 'failed' : 'stored'),
                  _timedOperation(1),
                ]
              });
            }));
  });

  testWidgets(
      'collapse all keeps cached children and never eagerly loads other groups',
      (tester) async {
    var childCalls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, _key('expand-operation-002'));
      await _tap(tester, _key('expand-operation-001'));
      expect(childCalls, 2);
      expect(_key('event-2'), findsOneWidget);
      expect(_key('event-1'), findsOneWidget);
      await _tap(tester, _key('collapse-all'));
      expect(_key('event-2'), findsNothing);
      expect(_key('event-1'), findsNothing);
      expect(_key('collapse-all'), findsNothing);
      await _tap(tester, _key('expand-operation-002'));
      expect(_key('event-2'), findsOneWidget);
      expect(childCalls, 2);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/events')) {
                childCalls++;
                return _json({
                  'events': [
                    _event(
                        request.url.path.contains('operation-002') ? '2' : '1')
                  ]
                });
              }
              return _json({
                'operations': [_timedOperation(2), _timedOperation(1)]
              });
            }));
  });

  testWidgets(
      'root-only child history stays empty without fabricating progress',
      (tester) async {
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(390, 844));
      await tester.pumpAndSettle();
      await _tap(tester, _key('expand-operation-1'));
      expect(_key('event-1'), findsNothing);
      expect(find.text('אין פעולות משנה מתועדות'), findsOneWidget);
      expect(find.text('טרם תועדו פעולות משנה'), findsOneWidget);
      expect(find.textContaining('מתוך'), findsNothing);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/events')) {
                return _json({
                  'events': [_event('1')]
                });
              }
              return _json({
                'operations': [
                  {
                    ..._operation('operation-1'),
                    'root_event_id': '1',
                    'sub_event_count': 0
                  }
                ]
              });
            }));
  });

  testWidgets(
      'all-events mode retains unrestricted query and standalone columns',
      (tester) async {
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('כל האירועים'));
      expect(requests.last.url.queryParameters, isNot(contains('scope')));
      expect(requests.last.url.queryParameters, isNot(contains('match')));
      expect(find.text('פעולה / אירוע קודם'), findsOneWidget);
      expect(_key('event-1'), findsOneWidget);
      expect(_key('expand-operation-1'), findsNothing);
      await _poll(tester);
      expect(requests.last.url.queryParameters, isNot(contains('scope')));
      expect(requests.last.url.queryParameters, isNot(contains('match')));
      await _unmount(tester);
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/events')) {
                return _json({
                  'events': [_event('1')]
                });
              }
              return _json({
                'operations': [_operation('operation-1')]
              });
            }));
  });

  testWidgets('older child pages preserve the visible chronological row anchor',
      (tester) async {
    final childRequests = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(1500, 850));
      await tester.pumpAndSettle();
      await _tap(tester, _key('expand-operation-1'));
      final scroll = tester
          .widget<SingleChildScrollView>(_key('vertical-scroll'))
          .controller!;
      scroll.jumpTo(900);
      await tester.pump();
      final visible = <Finder>[];
      final viewport = tester.getRect(_key('vertical-scroll'));
      for (var id = 150; id >= 101; id--) {
        final row = _key('event-$id');
        if (tester.getRect(row).overlaps(viewport)) visible.add(row);
      }
      expect(visible, isNotEmpty);
      final anchor = visible.last;
      final before = tester.getTopLeft(anchor).dy;
      tester.widget<TextButton>(_key('events-more-operation-1')).onPressed!();
      await tester.pumpAndSettle();
      expect(
          childRequests.last.url.queryParameters['before'], 'opaque-child-101');
      expect(tester.getTopLeft(anchor).dy, closeTo(before, .1));
      expect(tester.getTopLeft(_key('event-51')).dy,
          lessThan(tester.getTopLeft(_key('event-101')).dy));
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/events')) {
                childRequests.add(request);
                final more = request.url.queryParameters.containsKey('before');
                return _json({
                  'events': [
                    for (var id = more ? 100 : 150;
                        id >= (more ? 51 : 101);
                        id--)
                      _event('$id')
                  ],
                  'nextCursor': more ? null : 'opaque-child-101',
                });
              }
              return _json({
                'operations': [
                  {..._operation('operation-1'), 'event_count': 101}
                ]
              });
            }));
  });

  testWidgets(
      'flat-event boundaries compare adjacent IDs above JavaScript integer precision',
      (tester) async {
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('כל האירועים'));
      await _poll(tester);
      expect(_key('event-9007199254740994'), findsOneWidget);
      expect(_key('event-9007199254740993'), findsNothing);
      expect(_key('event-9007199254740992'), findsNothing);
      expect(_key('more'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/operations')) {
                return _json({'operations': []});
              }
              return _json(request.url.queryParameters['limit'] == '200'
                  ? {
                      'events': [
                        _event('9007199254740994'),
                        _event('9007199254740992')
                      ],
                    }
                  : {
                      'events': [_event('9007199254740993')],
                      'nextCursor': 'opaque-large-id',
                    });
            }));
  });

  testWidgets('expanded loaded prefixes retain their own pagination boundary',
      (tester) async {
    var changed = false;
    final childRequests = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, _key('expand-operation-002'));
      await _tap(tester, _key('events-more-operation-002'));
      changed = true;
      await _poll(tester);
      expect(_key('event-302'), findsOneWidget);
      expect(_key('event-299'), findsOneWidget);
      expect(_key('event-298'), findsNothing);
      await _tap(tester, _key('events-more-operation-002'));
      expect(
          childRequests.last.url.queryParameters['before'], 'child-oldest-299');
      expect(_key('event-298'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/events')) {
                childRequests.add(request);
                final before = request.url.queryParameters['before'];
                if (request.url.queryParameters['limit'] == '200') {
                  return _json({
                    'events': [
                      for (var id = 302; id >= 298; id--) _event('$id')
                    ]
                  });
                }
                return _json({
                  'events': [
                    _event(before == null
                        ? '300'
                        : changed
                            ? '298'
                            : '299')
                  ],
                  'nextCursor': before == null
                      ? 'child-oldest-300'
                      : changed
                          ? null
                          : 'child-oldest-299',
                });
              }
              return _json({
                'operations': [_timedOperation(2, count: changed ? 5 : 3)]
              });
            }));
  });

  testWidgets('polling waits for completion before scheduling another request',
      (tester) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 10));
      expect(calls, 2);
      pending.complete(_json({
        'operations': [_timedOperation(3)]
      }));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      expect(calls, 2);
      await _poll(tester, 1);
      expect(calls, 3);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              calls++;
              if (calls == 2) return pending.future;
              return _json({
                'operations': [_timedOperation(calls == 1 ? 2 : 3)]
              });
            }));
  });

  testWidgets('reopened cached events use their own event count snapshot',
      (tester) async {
    var changed = false;
    var childCalls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, _key('expand-operation-002'));
      await _tap(tester, _key('expand-operation-002'));
      changed = true;
      await _poll(tester);
      expect(childCalls, 1);
      await _tap(tester, _key('expand-operation-002'));
      await _poll(tester);
      expect(childCalls, 2);
      expect(_key('event-3'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/events')) {
                childCalls++;
                return _json({
                  'events': [if (changed) _event('3'), _event('2')]
                });
              }
              return _json({
                'operations': [_timedOperation(2, count: changed ? 3 : 2)]
              });
            }));
  });

  testWidgets('unchanged rows still update exhausted pagination',
      (tester) async {
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      expect(_key('more'), findsOneWidget);
      await _poll(tester);
      expect(_key('more'), findsNothing);
      expect(_key('operation-operation-002'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              return _json({
                'operations': [_timedOperation(2)],
                'nextCursor': request.url.queryParameters['limit'] == '200'
                    ? null
                    : 'old-cursor'
              });
            }));
  });

  testWidgets('root and expanded pages share a bounded atomic refresh budget',
      (tester) async {
    var automaticCalls = 0;
    var childCalls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, _key('expand-operation-002'));
      await _poll(tester);
      expect(automaticCalls, 20);
      expect(childCalls, 1);
      expect(_key('auto-retry'), findsOneWidget);
      expect(_key('operation-operation-099'), findsNothing);
      expect(_key('event-2'), findsOneWidget);
      expect(_key('operation-operation-002'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/events')) {
                childCalls++;
                return _json({
                  'events': [_event('2')]
                });
              }
              if (request.url.queryParameters['limit'] == '200') {
                automaticCalls++;
                return _json({
                  'operations': [
                    automaticCalls == 1
                        ? _timedOperation(2, count: 3)
                        : _timedOperation(101 - automaticCalls)
                  ],
                  'nextCursor':
                      automaticCalls < 20 ? 'page-$automaticCalls' : null,
                });
              }
              return _json({
                'operations': [_timedOperation(2)]
              });
            }));
  });

  testWidgets(
      'first-load failures recover automatically using foreground page size',
      (tester) async {
    var calls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      expect(_key('retry'), findsOneWidget);
      await _poll(tester, 10);
      expect(_key('operation-operation-002'), findsOneWidget);
      expect(calls, 2);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              calls++;
              expect(request.url.queryParameters['limit'], '50');
              return calls == 1
                  ? _json({}, 503)
                  : _json({
                      'operations': [_timedOperation(2)]
                    });
            }));
  });

  testWidgets('a covered route does not poll and resumes after it is popped',
      (tester) async {
    var calls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(navigator.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('another screen')))));
      await tester.pumpAndSettle();
      await _poll(tester, 10);
      expect(calls, 1);
      navigator.pop();
      await tester.pumpAndSettle();
      await _poll(tester);
      expect(calls, 2);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              calls++;
              return _json({
                'operations': [_timedOperation(2)]
              });
            }));
  });

  testWidgets(
      'automatic refresh replaces the loaded prefix and retains its opaque cursor',
      (tester) async {
    final requests = <http.Request>[];
    var refreshed = false;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, _key('more'));
      expect(_key('operation-operation-001'), findsOneWidget);
      refreshed = true;
      await _poll(tester);
      expect(_key('operation-operation-004'), findsOneWidget);
      expect(_key('operation-operation-001'), findsNothing);
      expect(_key('operation-operation-000'), findsNothing);
      expect(find.text('נכשל'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      final automatic = requests
          .where((r) => r.url.queryParameters['limit'] == '200')
          .toList();
      expect(automatic.length, 2);
      expect(automatic.last.url.queryParameters['before'], 'refresh-next');
      await _tap(tester, _key('more'));
      expect(requests.last.url.queryParameters['before'], 'opaque-oldest-1');
      expect(_key('operation-operation-000'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              final before = request.url.queryParameters['before'];
              if (request.url.queryParameters['limit'] == '200') {
                return _json(before == null
                    ? {
                        'operations': [_timedOperation(4), _timedOperation(3)],
                        'nextCursor': 'refresh-next',
                      }
                    : {
                        'operations': [
                          _timedOperation(2, status: 'failed'),
                          _timedOperation(0)
                        ],
                      });
              }
              return _json({
                'operations': before == null
                    ? [_timedOperation(3), _timedOperation(2)]
                    : refreshed
                        ? [_timedOperation(0)]
                        : [_timedOperation(1)],
                'nextCursor': before == null
                    ? 'opaque-oldest-2'
                    : refreshed
                        ? null
                        : 'opaque-oldest-1',
              });
            }));
  });

  testWidgets(
      'automatic refresh retains a removed boundary across repeated polls',
      (tester) async {
    var calls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _poll(tester);
      expect(_key('operation-operation-002'), findsNothing);
      expect(_key('operation-operation-001'), findsNothing);
      await _poll(tester);
      expect(_key('operation-operation-002'), findsOneWidget);
      expect(_key('operation-operation-001'), findsNothing);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              calls++;
              return _json({
                'operations': calls == 1
                    ? [_timedOperation(3), _timedOperation(2)]
                    : calls == 2
                        ? [_timedOperation(3), _timedOperation(1)]
                        : [
                            _timedOperation(3),
                            _timedOperation(2),
                            _timedOperation(1)
                          ],
                'nextCursor': calls == 1 ? 'stable-cursor' : null,
              });
            }));
  });

  testWidgets(
      'all-loaded flat events refresh to server end using exact large IDs',
      (tester) async {
    const high = '9007199254740994';
    const low = '9007199254740993';
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('כל האירועים'));
      await _poll(tester);
      expect(_key('event-$high'), findsOneWidget);
      expect(_key('event-$low'), findsOneWidget);
      expect(_key('event-9007199254740992'), findsOneWidget);
      expect(_key('more'), findsNothing);
      expect(
          requests.where((r) => r.url.queryParameters['limit'] == '200').length,
          2);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/operations')) {
                return _json({'operations': []});
              }
              if (request.url.queryParameters['limit'] != '200') {
                return _json({
                  'events': [_event(low)]
                });
              }
              return _json(request.url.queryParameters['before'] == null
                  ? {
                      'events': [_event(high), _event(low)],
                      'nextCursor': 'older-events',
                    }
                  : {
                      'events': [_event('9007199254740992')]
                    });
            }));
  });

  testWidgets(
      'expanded events refresh atomically and unchanged counts skip child requests',
      (tester) async {
    var changed = false;
    var childCalls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, _key('expand-operation-002'));
      expect(_key('event-2'), findsOneWidget);
      await _poll(tester);
      expect(childCalls, 1);
      changed = true;
      await _poll(tester);
      expect(_key('event-3'), findsOneWidget);
      expect(_key('event-2'), findsOneWidget);
      expect(childCalls, 2);
      expect(find.byTooltip('כווץ לשורה הראשונה'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/events')) {
                childCalls++;
                return _json({
                  'events': [if (changed) _event('3'), _event('2')]
                });
              }
              return _json({
                'operations': [_timedOperation(2, count: changed ? 3 : 2)]
              });
            }));
  });

  testWidgets('hidden app and open dialogs pause polling until resumed',
      (tester) async {
    var calls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await _poll(tester, 15);
      expect(calls, 1);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await _poll(tester);
      expect(calls, 2);
      await _tap(tester, _key('details-operation-002'));
      await _poll(tester, 15);
      expect(calls, 2);
      await _tap(tester, find.text('סגור'));
      await _poll(tester);
      expect(calls, 3);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              calls++;
              return _json({
                'operations': [_timedOperation(2)]
              });
            }));
  });

  testWidgets(
      'failed polling retains rows, backs off and retries without a foreground reset',
      (tester) async {
    var calls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _poll(tester);
      expect(_key('operation-operation-002'), findsOneWidget);
      expect(_key('auto-retry'), findsOneWidget);
      await _poll(tester, 5);
      expect(calls, 2);
      await _tap(tester, _key('auto-retry'));
      expect(_key('operation-operation-003'), findsOneWidget);
      expect(_key('auto-retry'), findsNothing);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              calls++;
              if (calls == 2) return _json({}, 503);
              return _json({
                'operations': [_timedOperation(calls == 1 ? 2 : 3)]
              });
            }));
  });

  testWidgets('late automatic responses cannot replace a newer foreground load',
      (tester) async {
    final late = Completer<http.Response>();
    var foregroundCalls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await _tap(tester, _key('refresh'));
      expect(_key('operation-operation-004'), findsOneWidget);
      late.complete(_json({
        'operations': [_timedOperation(3)]
      }));
      await tester.pumpAndSettle();
      expect(_key('operation-operation-004'), findsOneWidget);
      expect(_key('operation-operation-003'), findsNothing);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.queryParameters['limit'] == '200') {
                return late.future;
              }
              foregroundCalls++;
              return _json({
                'operations': [_timedOperation(foregroundCalls == 1 ? 2 : 4)]
              });
            }));
  });

  testWidgets(
      'polling preserves the visible row anchor when newer rows prepend',
      (tester) async {
    var refreshed = false;
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(1500, 850));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(_key('vertical-scroll'))
          .controller!;
      scroll.jumpTo(400);
      await tester.pump();
      final anchor = _key('operation-operation-013');
      final before = tester.getTopLeft(anchor).dy;
      refreshed = true;
      await _poll(tester);
      expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
      scroll.jumpTo(0);
      await tester.pump();
      await _poll(tester);
      expect(scroll.offset, 0);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              return _json({
                'operations': [
                  for (var i = refreshed ? 22 : 20; i >= 1; i--)
                    _timedOperation(i)
                ]
              });
            }));
  });

  testWidgets('read-only operations, inline event paging and applied filters',
      (tester) async {
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      expect(find.text('שליחת הודעה'), findsOneWidget);
      expect(find.text('נשמר בשרת'), findsOneWidget);
      expect(find.text('נמסר'), findsNothing);
      final initial =
          requests.firstWhere((r) => r.url.path.endsWith('/operations'));
      final from = DateTime.parse(initial.url.queryParameters['from']!);
      final to = DateTime.parse(initial.url.queryParameters['to']!);
      expect(from.isUtc, isTrue);
      expect(from.toLocal().hour, 0);
      expect(to.toLocal().hour, 0);
      expect(to.isAfter(from), isTrue);
      await _tap(tester, _key('expand-operation-1'));
      expect(_key('event-event-1'), findsOneWidget);
      expect(find.text('שירות: storage'), findsOneWidget);
      await _tap(tester, _key('events-more-operation-1'));
      expect(_key('event-event-1'), findsOneWidget);
      expect(_key('event-event-2'), findsOneWidget);
      expect(requests.last.url.queryParameters['before'], 'events-next');

      await tester.enterText(_key('user-id'), '7');
      await _tap(tester, _key('apply'));
      expect(requests.last.url.queryParameters['userId'], '7');
      await tester.enterText(_key('user-id'), '999');
      await _tap(tester, _key('more'));
      expect(requests.last.url.queryParameters['userId'], '7');
      expect(requests.last.url.queryParameters['before'], 'operations-next');
      expect(_key('operation-operation-1'), findsOneWidget);
      expect(_key('operation-operation-2'), findsOneWidget);
      expect(_key('more'), findsNothing);
      expect(requests.every((r) => r.method == 'GET'), isTrue);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              requests.add(request);
              expect(request.headers['Authorization'], 'Bearer admin-test');
              expect(request.url.queryParameters.containsKey('token'), isFalse);
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              final more = request.url.queryParameters.containsKey('before');
              if (request.url.path.endsWith('/operation-1/events')) {
                return _json({
                  'events': more
                      ? [_event('event-1'), _event('event-2')]
                      : [_event('event-1')],
                  'nextCursor': more ? null : 'events-next',
                });
              }
              return _json({
                'operations': more
                    ? [_operation('operation-1'), _operation('operation-2')]
                    : [_operation('operation-1')],
                'nextCursor': more ? null : 'operations-next'
              });
            }));
  });

  testWidgets('flat events show safe text details and copy root operation ID',
      (tester) async {
    final copied = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add(call.arguments);
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('כל האירועים'));
      expect(_key('event-event-1'), findsOneWidget);
      expect(find.text('מבצע לא ידוע'), findsOneWidget);
      await _tap(tester, _key('details-event-1'));
      final json = tester.widget<SelectableText>(_key('details-json')).data!;
      expect(json, contains('"before": false'));
      expect(json, contains('"after": true'));
      expect(json, contains('[redacted]'));
      expect(json, isNot(contains('must-not-display')));
      expect(json, contains('<img src=x onerror=bad()>'));
      expect(find.byType(Image), findsNothing);
      await _tap(tester, find.byTooltip('העתק מזהה פעולה').last);
      expect(copied, [
        {'text': 'operation-1'}
      ]);
      await _tap(tester, find.text('סגור'));
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/operations')) {
                return _json({'operations': []});
              }
              return _json({
                'events': [
                  {
                    ..._event('event-1'),
                    'executor_type': 'unknown',
                    'reason_code': '<img src=x onerror=bad()>'
                  }
                ]
              });
            }));
  });

  testWidgets(
      'actual executor types and precise local event time stay distinguishable',
      (tester) async {
    const labels = {
      'user': 'משתמש',
      'admin': 'מנהל',
      'worker': 'שירות',
      'system': 'מערכת',
      'provider': 'ספק',
      'client': 'מכשיר',
    };
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, find.text('כל האירועים'));
      for (final entry in labels.entries) {
        expect(
            find.text('${entry.value}: executor-${entry.key}'), findsOneWidget);
      }
      expect(find.textContaining(RegExp(r':01\.042 UTC[+-]\d{2}:\d{2}')),
          findsNWidgets(labels.length));
      expect(find.text('תשובת ספק ההתראות'), findsNWidgets(labels.length));
      expect(find.text('נמסר'), findsNothing);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/operations')) {
                return _json({'operations': []});
              }
              return _json({
                'events': [
                  for (final type in labels.keys)
                    {
                      ..._event('event-$type'),
                      'executor_type': type,
                      'executor_id': 'executor-$type',
                      'kind': 'push_provider_result',
                    },
                ],
              });
            }));
  });

  testWidgets(
      'late operation and expanded-event responses cannot overwrite refresh',
      (tester) async {
    final lateOperation = Completer<http.Response>();
    final lateEvents = Completer<http.Response>();
    var operations = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pump();
      await _tap(tester, _key('refresh'));
      expect(_key('operation-operation-1'), findsOneWidget);
      await tester.tap(_key('expand-operation-1'));
      await tester.pump();
      await _tap(tester, _key('refresh'));
      expect(_key('operation-operation-2'), findsOneWidget);
      lateOperation.complete(_json({
        'operations': [_operation('stale-operation')]
      }));
      lateEvents.complete(_json({
        'events': [_event('stale-event')]
      }));
      await tester.pumpAndSettle();
      expect(_key('operation-stale-operation'), findsNothing);
      expect(_key('event-stale-event'), findsNothing);
      expect(_key('operation-operation-2'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/events')) {
                return lateEvents.future;
              }
              operations++;
              if (operations == 1) return lateOperation.future;
              return _json({
                'operations': [
                  _operation(operations == 2 ? 'operation-1' : 'operation-2')
                ]
              });
            }));
  });

  testWidgets('main and per-operation errors retry without losing earlier rows',
      (tester) async {
    var operationCalls = 0;
    var eventCalls = 0;
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      expect(find.text('אין הרשאה לצפייה ביומן'), findsOneWidget);
      expect(find.textContaining('secret-server-body'), findsNothing);
      await _tap(tester, _key('retry'));
      await _tap(tester, _key('expand-operation-1'));
      await _tap(tester, _key('events-more-operation-1'));
      expect(_key('event-event-1'), findsOneWidget);
      await _tap(tester, _key('event-retry-operation-1'));
      expect(_key('event-event-2'), findsOneWidget);
      expect(_key('event-event-1'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/operations')) {
                operationCalls++;
                return operationCalls == 1
                    ? _json({'error': 'secret-server-body'}, 403)
                    : _json({
                        'operations': [_operation('operation-1')]
                      });
              }
              eventCalls++;
              if (eventCalls == 2) return _json({}, 500);
              return _json({
                'events': [_event(eventCalls == 1 ? 'event-1' : 'event-2')],
                'nextCursor': eventCalls == 1 ? 'next' : null
              });
            }));
  });

  testWidgets('bounded CSV uses auth header and native byte download',
      (tester) async {
    final downloads = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('com.betshuva.app/media');
    messenger.setMockMethodCallHandler(channel, (call) async {
      downloads.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, _key('export'));
      expect(downloads.single.method, 'saveFile');
      expect(downloads.single.arguments['bytes'],
          utf8.encode('id,status\n1,stored\n'));
      expect(downloads.single.arguments['mimeType'], 'text/csv');
      expect(find.text('הייצוא הוגבל ל-5,000 רשומות'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/export.csv')) {
                expect(request.headers['Authorization'], 'Bearer admin-test');
                expect(request.url.queryParameters['mode'], 'operations');
                expect(request.url.queryParameters['scope'], 'user');
                expect(request.url.queryParameters['match'], 'items');
                expect(request.url.queryParameters.keys,
                    containsAll(['from', 'to']));
                expect(request.url.toString(), isNot(contains('admin-test')));
                return http.Response('id,status\n1,stored\n', 200, headers: {
                  'content-type': 'text/csv',
                  'x-audit-export-truncated': 'true'
                });
              }
              return _json({'operations': []});
            }));
  });

  testWidgets('mobile uses collapsed filters and horizontally scrollable table',
      (tester) async {
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(390, 844));
      await tester.pumpAndSettle();
      expect(_key('user-id'), findsNothing);
      expect(
          tester
              .widget<SingleChildScrollView>(_key('table-scroll'))
              .scrollDirection,
          Axis.horizontal);
      expect(_key('operation-operation-1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, find.text('סינון'));
      expect(_key('user-id'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
        () =>
            MockClient((request) async => request.url.path.endsWith('/catalog')
                ? _json(_catalog)
                : _json({
                    'operations': [_operation('operation-1')]
                  })));
  });

  testWidgets('header exclusions persist in paging, CSV and child events',
      (tester) async {
    final requests = <http.Request>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('com.betshuva.app/media');
    messenger.setMockMethodCallHandler(channel, (_) async => true);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    Map<String, dynamic> filters(http.Request request) =>
        jsonDecode(request.url.queryParameters['columnFilters']!);
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, _key('column-status'));
      expect(requests.last.url.queryParameters['mode'], 'operations');
      expect(requests.last.url.queryParameters['column'], 'status');
      expect(requests.last.url.queryParameters['scope'], 'user');
      expect(requests.last.url.queryParameters['match'], 'items');
      await _tap(tester, _key('column-option-1'));
      await _tap(tester, _key('column-apply'));
      expect(filters(requests.last), {
        'status': {
          'exclude': true,
          'values': ['failed']
        }
      });
      expect(find.byTooltip('סינון מצב (פעיל)'), findsOneWidget);
      expect(requests.last.url.queryParameters.containsKey('before'), isFalse);
      await _tap(tester, _key('more'));
      expect(requests.last.url.queryParameters['before'], 'operations-next');
      expect(filters(requests.last)['status']['values'], ['failed']);
      await _tap(tester, _key('expand-operation-1'));
      expect(requests.last.url.queryParameters.containsKey('columnFilters'),
          isTrue);
      expect(_key('column-kind'), findsOneWidget);
      await _tap(tester, _key('export'));
      expect(requests.last.url.path, endsWith('/export.csv'));
      expect(filters(requests.last)['status']['exclude'], isTrue);
      await _tap(tester, _key('clear-columns'));
      expect(requests.last.url.queryParameters.containsKey('columnFilters'),
          isFalse);
      expect(_key('clear-columns'), findsNothing);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/filter-options')) {
                return _json({
                  'options': [
                    {'value': 'stored', 'label': 'נשמר בשרת'},
                    {'value': 'failed', 'label': 'נכשל'},
                  ],
                  'hasMore': true
                });
              }
              if (request.url.path.endsWith('/export.csv')) {
                return http.Response('id\noperation-1\n', 200);
              }
              if (request.url.path.endsWith('/events')) {
                return _json({
                  'events': [_event('event-1')]
                });
              }
              return _json({
                'operations': [_operation('operation-1')],
                'nextCursor': 'operations-next',
              });
            }));
  });

  testWidgets('header selections include empty values and stay mode-specific',
      (tester) async {
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, _key('column-source'));
      await _tap(tester, _key('column-all'));
      await _tap(tester, _key('column-apply'));
      expect(jsonDecode(requests.last.url.queryParameters['columnFilters']!), {
        'source': {'exclude': false, 'values': []}
      });
      await _tap(tester, _key('column-source'));
      await _tap(tester, _key('column-option-0'));
      await _tap(tester, _key('column-apply'));
      expect(jsonDecode(requests.last.url.queryParameters['columnFilters']!), {
        'source': {
          'exclude': false,
          'values': [null]
        }
      });
      await _tap(tester, find.text('כל האירועים'));
      expect(requests.last.url.path, endsWith('/events'));
      expect(requests.last.url.queryParameters.containsKey('columnFilters'),
          isFalse);
      await _tap(tester, _key('column-kind'));
      await _tap(tester, _key('column-option-1'));
      await _tap(tester, _key('column-apply'));
      expect(jsonDecode(requests.last.url.queryParameters['columnFilters']!), {
        'kind': {
          'exclude': true,
          'values': ['worker']
        }
      });
      await _tap(tester, find.text('פעולות'));
      expect(
          jsonDecode(requests.last.url.queryParameters['columnFilters']!)
              .keys
              .toList(),
          ['source']);
      await _tap(tester, _key('column-source'));
      await _tap(tester, _key('column-all'));
      await _tap(tester, _key('column-cancel'));
      await _tap(tester, _key('refresh'));
      expect(
          jsonDecode(requests.last.url.queryParameters['columnFilters']!)[
              'source']['values'],
          [null]);
      await _tap(tester, _key('column-source'));
      await _tap(tester, _key('column-clear'));
      expect(requests.last.url.queryParameters.containsKey('columnFilters'),
          isFalse);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/filter-options')) {
                return _json({
                  'options': [
                    {'value': null, 'label': '(ריק)'},
                    {'value': 'worker', 'label': 'worker'},
                  ]
                });
              }
              return _json({'operations': [], 'events': []});
            }));
  });

  testWidgets(
      'numeric and precise local date headers validate and intersect top filters',
      (tester) async {
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, _key('column-event_count'));
      await tester.enterText(_key('column-min'), '8');
      await tester.enterText(_key('column-max'), '2');
      await _tap(tester, _key('column-apply'));
      expect(_key('column-dialog'), findsOneWidget);
      expect(find.text('הערך המרבי חייב להיות גדול או שווה לערך המזערי'),
          findsOneWidget);
      await tester.enterText(_key('column-min'), '0');
      await _tap(tester, _key('column-apply'));
      expect(
          jsonDecode(requests.last.url.queryParameters['columnFilters']!)[
              'event_count'],
          {'min': '0', 'max': '2'});
      final topFrom = requests.last.url.queryParameters['from'];
      await _tap(tester, _key('column-created_at'));
      await tester.enterText(_key('column-min'), '2026-02-31 09:20:30.123');
      await _tap(tester, _key('column-apply'));
      expect(find.text('יש להזין תאריך ושעה תקינים'), findsOneWidget);
      await tester.enterText(_key('column-min'), '2026-09-24 09:20:30.123');
      await tester.enterText(_key('column-max'), '2026-09-24 09:20:30.124');
      await _tap(tester, _key('column-apply'));
      final filters =
          jsonDecode(requests.last.url.queryParameters['columnFilters']!);
      final from = DateTime.parse(filters['created_at']['from']).toLocal();
      final to = DateTime.parse(filters['created_at']['to']).toLocal();
      expect(from, DateTime(2026, 9, 24, 9, 20, 30, 123));
      expect(to.difference(from), const Duration(milliseconds: 1));
      expect(filters['event_count']['min'], '0');
      expect(requests.last.url.queryParameters['from'], topFrom);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              requests.add(request);
              return request.url.path.endsWith('/catalog')
                  ? _json(_catalog)
                  : _json({'operations': []});
            }));
  });

  testWidgets(
      'facet search ignores stale response and retries errors on mobile',
      (tester) async {
    final late = Completer<http.Response>();
    var searching = 0;
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(390, 844));
      await tester.pumpAndSettle();
      await tester.ensureVisible(_key('column-action'));
      await tester.tap(_key('column-action'));
      await tester.pump();
      expect(
          tester.widget<FilledButton>(_key('column-apply')).onPressed, isNull);
      await tester.enterText(_key('column-search'), 'new');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(_key('column-retry'), findsOneWidget);
      expect(
          tester.widget<FilledButton>(_key('column-apply')).onPressed, isNull);
      await _tap(tester, _key('column-retry'));
      late.complete(_json({
        'options': [
          {'value': 'old', 'label': 'stale-label'}
        ]
      }));
      await tester.pumpAndSettle();
      expect(find.text('fresh-label'), findsOneWidget);
      expect(find.text('stale-label'), findsNothing);
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await _tap(tester, _key('column-cancel'));
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/filter-options')) {
                if (request.url.queryParameters['search'] == null) {
                  return late.future;
                }
                expect(request.url.queryParameters['search'], 'new');
                if (++searching == 1) return _json({}, 500);
                return _json({
                  'options': [
                    {'value': 'fresh', 'label': 'fresh-label'}
                  ]
                });
              }
              return _json({'operations': []});
            }));
  });

  testWidgets(
      'composite target header chooses target ID without losing type filter',
      (tester) async {
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await _tap(tester, _key('column-target_type'));
      await _tap(tester, _key('column-option-0'));
      await _tap(tester, _key('column-apply'));
      await _tap(tester, _key('column-target_type'));
      await _tap(tester, _key('column-field'));
      await _tap(tester, find.text('מזהה יעד').last);
      expect(requests.last.url.queryParameters['column'], 'target_id');
      expect(
          jsonDecode(requests.last.url.queryParameters['columnFilters']!)[
              'target_type']['values'],
          ['group']);
      await _tap(tester, _key('column-option-0'));
      await _tap(tester, _key('column-apply'));
      expect(jsonDecode(requests.last.url.queryParameters['columnFilters']!), {
        'target_type': {
          'exclude': true,
          'values': ['group']
        },
        'target_id': {
          'exclude': true,
          'values': ['group-1']
        },
      });
      await _unmount(tester);
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/filter-options')) {
                return _json({
                  'options': [
                    {
                      'value':
                          request.url.queryParameters['column'] == 'target_id'
                              ? 'group-1'
                              : 'group',
                      'label': 'group'
                    },
                  ]
                });
              }
              return _json({'operations': []});
            }));
  });

  testWidgets(
      'authentication changes close header dialog and ignore old facet data',
      (tester) async {
    final late = Completer<http.Response>();
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(_key('column-status'));
      await tester.tap(_key('column-status'));
      await tester.pump();
      expect(_key('column-dialog'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(
        home: SystemAuditScreen(
            api: 'https://example.test/api', token: 'new-admin'),
      ));
      await tester.pumpAndSettle();
      expect(_key('column-dialog'), findsNothing);
      late.complete(_json({
        'options': [
          {'value': 'old', 'label': 'old-private-label'}
        ]
      }));
      await tester.pumpAndSettle();
      expect(find.text('old-private-label'), findsNothing);
      final latest = requests
          .lastWhere((request) => request.url.path.endsWith('/operations'));
      expect(latest.headers['Authorization'], 'Bearer new-admin');
      expect(latest.url.queryParameters.containsKey('columnFilters'), isFalse);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              requests.add(request);
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/filter-options')) {
                return late.future;
              }
              return _json({'operations': []});
            }));
  });

  testWidgets('changing a column filter invalidates an in-flight CSV export',
      (tester) async {
    final late = Completer<http.Response>();
    final downloads = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('com.betshuva.app/media');
    messenger.setMockMethodCallHandler(channel, (call) async {
      downloads.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await http.runWithClient(() async {
      await _mount(tester);
      await tester.pumpAndSettle();
      await tester.tap(_key('export'));
      await tester.pump();
      await tester.ensureVisible(_key('column-event_count'));
      await tester.tap(_key('column-event_count'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(_key('column-min'), '3');
      await tester.tap(_key('column-apply'));
      await tester.pump(const Duration(milliseconds: 300));
      late.complete(http.Response('id\n1\n', 200));
      await tester.pumpAndSettle();
      expect(downloads, isEmpty);
      expect(find.byTooltip('סינון תיעוד / ניסיון (פעיל)'), findsOneWidget);
      await _unmount(tester);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/catalog')) return _json(_catalog);
              if (request.url.path.endsWith('/export.csv')) return late.future;
              return _json({'operations': []});
            }));
  });
}
