import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:betshuva/filter_history.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _token = 'personal-media-user-a';
const _friendId = '11111111-1111-4111-8111-111111111111';
const _groupId = '22222222-2222-4222-8222-222222222222';
const _sourceMessageId = '33333333-3333-4333-8333-333333333333';

http.Response _json(Object data, [int status = 200]) => http.Response(
      jsonEncode(data),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, Object?> _file(String id,
        {String? name, bool canDelete = true, int size = 1048576}) =>
    {
      'id': id,
      'name': name ?? '$id.pdf',
      'url': '/uploads/$id.pdf',
      'mimeType': 'application/pdf',
      'fileType': 'document',
      'size': size,
      'createdAt': '2026-09-10T06:30:00.000Z',
      'moderationStatus': 'approved',
      'classification': null,
      'releasedAt': null,
      'backupStatus': null,
      'restoreVerified': false,
      'appealStatus': null,
      'referenceCount': canDelete ? 0 : 1,
      'destinations': canDelete
          ? []
          : [
              {
                'kind': 'group_chat',
                'targetId': _groupId,
                'label': 'קבוצת המטיילים',
                'date': '2026-09-10T06:30:00.000Z',
              },
            ],
      'usages': {'messages': canDelete ? 0 : 1},
      'canDelete': canDelete,
    };

Map<String, Object?> _catalog({int total = 83}) => {
      'summary': {
        'totalCount': total,
        'totalBytes': 125829120,
        'byType': {
          'image': {'count': 51, 'bytes': 52428800},
          'video': {'count': 17, 'bytes': 52428800},
          'audio': {'count': 9, 'bytes': 10485760},
          'document': {'count': 6, 'bytes': 10485760},
        },
        'deletableCount': 12,
        'deletableBytes': 20971520,
        'backedUpCount': 60,
        'releasedCount': 7,
      },
      'destinations': [
        {
          'kind': 'chat',
          'id': _friendId,
          'label': 'משפחה',
          'count': 23,
          'bytes': 31457280,
        },
        {
          'kind': 'group',
          'id': _groupId,
          'label': 'משפחה',
          'count': 32,
          'bytes': 41943040,
        },
      ],
    };

class _MediaBackend {
  final requests = <http.Request>[];
  List<Map<String, Object?>> items = [_file('first'), _file('second')];
  int? total;
  Future<http.Response> Function(http.Request)? listing;
  Future<http.Response> Function(http.Request)? catalog;
  Future<http.Response> Function(http.Request)? previewing;
  Future<http.Response> Function(http.Request)? deleting;
  Future<http.Response> Function(http.Request)? renaming;
  Future<http.Response> Function(http.Request)? forwarding;

  List<http.Request> get listings => requests
      .where((request) =>
          request.method == 'GET' &&
          request.url.path.endsWith('/media-library'))
      .toList();

  List<http.Request> get deletePreviews => requests
      .where((request) =>
          request.method == 'POST' &&
          request.url.path.endsWith('/media-library/delete-preview'))
      .toList();

  List<http.Request> get deletes => requests
      .where((request) =>
          request.method == 'POST' &&
          request.url.path.endsWith('/media-library/delete-confirm'))
      .toList();

  Map<String, Object?> deletePreview(
    List<dynamic> ids, {
    String confirmationToken = 'preview-token-1',
    List<Map<String, Object?>> pendingRecipients = const [],
    List<Map<String, Object?>> linkedUses = const [],
  }) =>
      {
        'ids': ids,
        'fileCount': ids.length,
        'copyCount': ids.length,
        'totalBytes': ids.length * 1048576,
        'hasBackup': false,
        'files': [
          for (final id in ids)
            {
              'id': id,
              'name': items
                      .where((item) => item['id'] == id)
                      .firstOrNull?['name'] ??
                  '$id.pdf'
            },
        ],
        'pendingRecipients': pendingRecipients,
        'pendingCount': pendingRecipients.fold<int>(
            0, (total, recipient) => total + (recipient['count'] as int? ?? 1)),
        'linkedUses': linkedUses,
        'confirmationToken': confirmationToken,
      };

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    if (request.url.path.endsWith('/users/directory')) return _json([]);
    if (request.url.path.endsWith('/users')) {
      return _json([
        {'id': _friendId, 'name': 'חבר לבדיקה'}
      ]);
    }
    if (request.url.path.endsWith('/groups')) {
      return _json([
        {'id': _groupId, 'name': 'קבוצה לבדיקה'}
      ]);
    }
    if (request.method == 'POST' && request.url.path.endsWith('/messages')) {
      return forwarding != null
          ? await forwarding!(request)
          : _json({'ok': true});
    }
    if (request.method == 'PATCH') {
      if (renaming != null) return renaming!(request);
      final id = request.url.pathSegments.last;
      final index = items.indexWhere((item) => item['id'] == id);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final name = body['name'].toString();
      items[index] = {...items[index], 'name': name};
      return _json({'item': items[index]});
    }
    if (request.url.path.endsWith('/media-library/catalog')) {
      return catalog != null ? await catalog!(request) : _json(_catalog());
    }
    if (request.url.path.endsWith('/media-library/delete-preview')) {
      if (previewing != null) return previewing!(request);
      final ids = jsonDecode(request.body)['ids'] as List<dynamic>;
      return _json(deletePreview(ids));
    }
    if (request.url.path.endsWith('/media-library/delete-confirm')) {
      if (deleting != null) return deleting!(request);
      final ids = jsonDecode(request.body)['ids'] as List<dynamic>;
      final deletedBytes = items
          .where((item) => ids.contains(item['id']))
          .fold<int>(0, (total, item) => total + (item['size'] as int));
      items.removeWhere((item) => ids.contains(item['id']));
      return _json(
          {'deletedIds': ids, 'failed': [], 'deletedBytes': deletedBytes});
    }
    if (request.url.path.endsWith('/media-library')) {
      return listing != null
          ? await listing!(request)
          : _json({
              'total': total ?? items.length,
              'totalBytes': items.fold<int>(
                  0, (sum, item) => sum + (item['size']! as int)),
              'items': items,
            });
    }
    throw StateError('Unexpected request: ${request.method} ${request.url}');
  }
}

Finder _key(String key) => find.byKey(ValueKey(key));

Future<void> _withLibrary(
  WidgetTester tester,
  Future<void> Function(_MediaBackend backend, ValueNotifier<String> token)
      check, {
  Size size = const Size(1280, 1100),
  _MediaBackend? backend,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final mediaBackend = backend ?? _MediaBackend();
  final token = ValueNotifier(_token);
  await http.runWithClient(() async {
    try {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'NotoSansHebrew'),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: ValueListenableBuilder<String>(
            valueListenable: token,
            builder: (context, token, child) =>
                PersonalMediaScreen(token: token),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await check(mediaBackend, token);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      token.dispose();
    }
  }, () => MockClient(mediaBackend.respond));
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openBulkDeletePreview(WidgetTester tester) async {
  await tester.ensureVisible(_key('media-delete-selected'));
  await tester.tap(_key('media-delete-selected'));
  await tester.pump();
  // The selection bar keeps its progress indicator while the user confirms.
  await tester.pump(const Duration(milliseconds: 350));
  expect(_key('media-delete-confirm'), findsOneWidget);
}

Future<void> _search(WidgetTester tester, String value,
    {bool settle = true}) async {
  await tester.enterText(_key('media-search'), value);
  await tester.pump(const Duration(milliseconds: 400));
  if (settle) await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (kIsWeb) return;
    final font = FontLoader('NotoSansHebrew')
      ..addFont(rootBundle.load('assets/fonts/NotoSansHebrew.ttf'));
    await font.load();
  });

  for (final width in [375.0, 1280.0]) {
    testWidgets('media library fits ${width.toInt()}px and uses global counts',
        (tester) async {
      final backend = _MediaBackend()..total = 83;
      await _withLibrary(tester, (backend, token) async {
        expect(find.text('המדיה שלי'), findsWidgets);
        expect(_key('media-grid'), findsOneWidget);
        expect(find.textContaining('83'), findsWidgets);
        expect(
            find.descendant(
                of: _key('media-type-image'),
                matching: find.textContaining('51')),
            findsOneWidget);
        expect(backend.listings.single.url.queryParameters['limit'], '40');
        expect(
            backend.requests.map((request) => request.headers['Authorization']),
            everyElement('Bearer $_token'));
        expect(tester.takeException(), isNull);
        await _tapVisible(tester, _key('media-view-list'));
        expect(_key('media-list'), findsOneWidget);
        expect(find.text('first.pdf'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, backend: backend, size: Size(width, 1100));
    });
  }

  testWidgets(
      'hidden received copies never request an image and disable open actions',
      (tester) async {
    final backend = _MediaBackend()
      ..items = [
        {
          ..._file('hidden-copy'),
          'fileType': 'image',
          'name': 'תמונה מוסתרת',
          'filterHidden': true,
          'hiddenReason': 'content_filter',
          'sourceMessageId': _sourceMessageId,
          'url': null,
        }
      ];
    await _withLibrary(tester, (backend, _) async {
      expect(find.text('התמונה מוסתרת לפי בחירת הסינון שלך'), findsOneWidget);
      final observations = backend.requests
          .where(
              (request) => request.url.path.endsWith('/filter-display-events'))
          .toList();
      expect(observations, hasLength(1));
      expect(
          jsonDecode(observations.single.body)['messageId'], _sourceMessageId);
      expect(jsonDecode(observations.single.body)['event'], 'hidden');

      expect(
          backend.requests
              .where((request) => request.url.path.contains('/uploads/')),
          isEmpty);
      await _tapVisible(tester, find.byTooltip('פעולות'));
      expect(
          tester
              .widget<PopupMenuItem<String>>(find.ancestor(
                  of: find.text('שליחה לחבר או לקבוצה'),
                  matching: find.byType(PopupMenuItem<String>)))
              .enabled,
          false);
      expect(
          tester
              .widget<PopupMenuItem<String>>(find.ancestor(
                  of: find.text('הורדה'),
                  matching: find.byType(PopupMenuItem<String>)))
              .enabled,
          false);
    }, backend: backend);
  });

  for (final fixture in [
    (
      name: 'pending',
      status: 'pending',
      hiddenReason: 'moderation',
      reason: null,
      purged: false,
      expected: 'התמונה ממתינה לסריקה ולאישור',
    ),
    (
      name: 'rejected',
      status: 'rejected',
      hiddenReason: 'moderation',
      reason: 'התמונה נחסמה בשל תוכן אלים',
      purged: false,
      expected: 'התמונה נחסמה בבדיקת הבטיחות\nהתמונה נחסמה בשל תוכן אלים',
    ),
    (
      name: 'purged',
      status: 'approved',
      hiddenReason: 'content_filter',
      reason: null,
      purged: true,
      expected: 'התמונה נמחקה ואינה זמינה עוד',
    ),
  ]) {
    testWidgets(
        '${fixture.name} hidden media shows its actual state without filter audit',
        (tester) async {
      final backend = _MediaBackend()
        ..items = [
          {
            ..._file('moderated-copy'),
            'fileType': 'image',
            'name': 'תמונה בבדיקה',
            'filterHidden': true,
            'hiddenReason': fixture.hiddenReason,
            'moderationStatus': fixture.status,
            'scanReason': fixture.reason,
            'contentPurged': fixture.purged,
            'sourceMessageId': _sourceMessageId,
            'url': null,
          },
        ];
      await _withLibrary(tester, (backend, _) async {
        expect(find.text(fixture.expected), findsOneWidget);
        expect(find.byTooltip(fixture.expected), findsOneWidget);
        expect(find.text('התמונה מוסתרת לפי בחירת הסינון שלך'), findsNothing);
        expect(find.text('להחזיר את התמונה הזו'), findsNothing);

        await _tapVisible(tester, _key('media-view-list'));
        expect(find.byTooltip(fixture.expected), findsOneWidget);
        await _tapVisible(tester, find.byTooltip('פעולות'));
        for (final action in ['שליחה לחבר או לקבוצה', 'הורדה']) {
          expect(
              tester
                  .widget<PopupMenuItem<String>>(find.ancestor(
                      of: find.text(action),
                      matching: find.byType(PopupMenuItem<String>)))
                  .enabled,
              isFalse);
        }
        expect(
            backend.requests.where((request) =>
                request.url.path.endsWith('/filter-display-events')),
            isEmpty);
        expect(
            backend.requests
                .where((request) => request.url.path.contains('/uploads/')),
            isEmpty);
        expect(backend.requests.every((request) => request.method == 'GET'),
            isTrue);
      }, backend: backend);
    });
  }

  testWidgets(
      'a filter change discards personal media immediately until fresh visibility arrives',
      (tester) async {
    final gate = Completer<http.Response>();
    await _withLibrary(tester, (backend, _) async {
      expect(find.byKey(const ValueKey('media-file-first')), findsOneWidget);
      backend.listing = (_) => gate.future;
      receivingFilterChanges.add(_token);
      await tester.pump();
      expect(find.byKey(const ValueKey('media-file-first')), findsNothing);
      gate.complete(_json({'items': [], 'total': 0}));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('media-file-first')), findsNothing);
    });
  });

  testWidgets('type and exact destination IDs reach the server',
      (tester) async {
    await _withLibrary(tester, (backend, token) async {
      await _tapVisible(tester, _key('media-type-document'));
      expect(backend.listings.last.url.queryParameters['type'], 'document');
      expect(backend.listings.last.url.queryParameters['offset'], '0');
      await _tapVisible(tester, _key('media-destination-filter'));
      await _tapVisible(tester, _key('media-destination-group-$_groupId'));
      expect(backend.listings.last.url.queryParameters['destinationKind'],
          'group');
      expect(
          backend.listings.last.url.queryParameters['destinationId'], _groupId);
      await _tapVisible(tester, _key('media-destination-filter'));
      await _tapVisible(tester, _key('media-destination-chat-$_friendId'));
      expect(
          backend.listings.last.url.queryParameters['destinationKind'], 'chat');
      expect(backend.listings.last.url.queryParameters['destinationId'],
          _friendId);
      await _tapVisible(tester, _key('media-destination-filter'));
      await _tapVisible(tester, _key('media-destination-all'));
      expect(backend.listings.last.url.queryParameters,
          isNot(contains('destinationId')));
      expect(backend.deletes, isEmpty);
    });
  });

  testWidgets('size filters send bytes and sorting stays active',
      (tester) async {
    await _withLibrary(tester, (backend, token) async {
      await _tapVisible(tester, _key('media-advanced-filters'));
      await tester.enterText(_key('media-min-size'), '1.5');
      await tester.enterText(_key('media-max-size'), '12');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(backend.listings.last.url.queryParameters['minSize'], '1572864');
      expect(backend.listings.last.url.queryParameters['maxSize'], '12582912');
      await _tapVisible(tester, _key('media-sort'));
      await _tapVisible(tester, find.text('הגדול ביותר').last);
      expect(backend.listings.last.url.queryParameters['sort'], 'size_desc');
      expect(backend.listings.last.url.queryParameters['minSize'], '1572864');
      expect(backend.listings.last.url.queryParameters['maxSize'], '12582912');
      expect(backend.listings.last.url.queryParameters['offset'], '0');
    });
  });

  testWidgets('a slower old search cannot replace the latest result',
      (tester) async {
    await _withLibrary(tester, (backend, token) async {
      final oldSearch = Completer<http.Response>();
      backend.listing = (request) async {
        if (request.url.queryParameters['search'] == 'ישן') {
          return oldSearch.future;
        }
        return _json({
          'total': 1,
          'totalBytes': 1048576,
          'items': [_file('latest', name: 'תוצאת החיפוש החדשה.pdf')],
        });
      };
      await _search(tester, 'ישן', settle: false);
      await _search(tester, 'חדש');
      expect(find.text('תוצאת החיפוש החדשה.pdf'), findsOneWidget);
      oldSearch.complete(_json({
        'total': 1,
        'totalBytes': 1048576,
        'items': [_file('stale', name: 'תוצאת החיפוש הישנה.pdf')],
      }));
      await tester.pumpAndSettle();
      expect(find.text('תוצאת החיפוש החדשה.pdf'), findsOneWidget);
      expect(find.text('תוצאת החיפוש הישנה.pdf'), findsNothing);
    });
  });

  testWidgets('a pending next page cannot append after changing the filter',
      (tester) async {
    final backend = _MediaBackend()..total = 3;
    await _withLibrary(tester, (backend, token) async {
      final oldPage = Completer<http.Response>();
      backend.listing = (request) async {
        if (request.url.queryParameters['offset'] == '2') {
          return oldPage.future;
        }
        return _json({
          'total': 1,
          'totalBytes': 1048576,
          'items': [_file('filtered', name: 'קובץ מהמסנן החדש.pdf')],
        });
      };
      await tester.ensureVisible(_key('media-load-more'));
      await tester.tap(_key('media-load-more'));
      await tester.pump();
      expect(backend.listings.last.url.queryParameters['offset'], '2');
      await _tapVisible(tester, _key('media-type-document'));
      expect(backend.listings.last.url.queryParameters['offset'], '0');
      expect(find.text('קובץ מהמסנן החדש.pdf'), findsOneWidget);
      oldPage.complete(_json({
        'total': 3,
        'totalBytes': 3145728,
        'items': [_file('old-page', name: 'קובץ מהעמוד הישן.pdf')],
      }));
      await tester.pumpAndSettle();
      expect(find.text('קובץ מהמסנן החדש.pdf'), findsOneWidget);
      expect(find.text('קובץ מהעמוד הישן.pdf'), findsNothing);
      expect(find.text('first.pdf'), findsNothing);
      expect(
          find.descendant(
              of: _key('media-type-image'),
              matching: find.textContaining('51')),
          findsOneWidget);
    }, backend: backend);
  });

  testWidgets('switching account discards pending media from the prior token',
      (tester) async {
    await _withLibrary(tester, (backend, token) async {
      final oldResponse = Completer<http.Response>();
      backend.listing = (request) async {
        if (request.headers['Authorization'] == 'Bearer $_token') {
          return oldResponse.future;
        }
        return _json({
          'total': 1,
          'totalBytes': 1048576,
          'items': [_file('new-owner', name: 'המדיה של החשבון החדש.pdf')],
        });
      };
      await _search(tester, 'ממתין', settle: false);
      token.value = 'personal-media-user-b';
      await tester.pumpAndSettle();
      expect(find.text('המדיה של החשבון החדש.pdf'), findsOneWidget);
      expect(tester.widget<TextField>(_key('media-search')).controller!.text,
          isEmpty);
      oldResponse.complete(_json({
        'total': 1,
        'totalBytes': 1048576,
        'items': [_file('prior-owner', name: 'קובץ פרטי מהחשבון הקודם.pdf')],
      }));
      await tester.pumpAndSettle();
      expect(find.text('קובץ פרטי מהחשבון הקודם.pdf'), findsNothing);
      expect(find.text('המדיה של החשבון החדש.pdf'), findsOneWidget);
      expect(backend.listings.last.headers['Authorization'],
          'Bearer personal-media-user-b');
    });
  });

  testWidgets(
      'successful delete requires confirmation and removes only its row',
      (tester) async {
    await _withLibrary(tester, (backend, token) async {
      await _tapVisible(tester, _key('media-delete-first'));
      expect(backend.deletes, isEmpty);
      expect(backend.deletePreviews, hasLength(1));
      expect(jsonDecode(backend.deletePreviews.single.body), {
        'ids': ['first']
      });
      expect(find.text('מחיקה לצמיתות'), findsOneWidget);
      await tester.tap(_key('media-delete-confirm'));
      await tester.pumpAndSettle();
      expect(backend.deletes, hasLength(1));
      expect(backend.deletes.single.url.path,
          endsWith('/media-library/delete-confirm'));
      expect(jsonDecode(backend.deletes.single.body), {
        'ids': ['first'],
        'confirmationToken': 'preview-token-1',
      });
      expect(backend.deletes.single.headers['Authorization'], 'Bearer $_token');
      expect(backend.requests.where((request) => request.method == 'DELETE'),
          isEmpty);
      expect(find.text('first.pdf'), findsNothing);
      expect(find.text('second.pdf'), findsOneWidget);
    });
  });

  testWidgets('old-account catalog cannot expose contacts after account change',
      (tester) async {
    await _withLibrary(tester, (backend, token) async {
      final oldCatalog = Completer<http.Response>();
      backend.catalog = (request) async {
        if (request.headers['Authorization'] == 'Bearer $_token') {
          return oldCatalog.future;
        }
        final next = _catalog(total: 2);
        next['destinations'] = <Object>[];
        return _json(next);
      };
      await tester.tap(find.byTooltip('רענון המדיה'));
      await tester.pump();
      token.value = 'personal-media-user-b';
      await tester.pumpAndSettle();
      oldCatalog.complete(_json(_catalog()));
      await tester.pumpAndSettle();
      expect(find.textContaining('83'), findsNothing);
      await _tapVisible(tester, _key('media-destination-filter'));
      expect(_key('media-destination-chat-$_friendId'), findsNothing);
      expect(_key('media-destination-group-$_groupId'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, 'סגור'));
      await tester.pumpAndSettle();
    });
  });

  testWidgets(
      'logical deletion with pending cleanup removes selection without claiming freed bytes',
      (tester) async {
    final backend = _MediaBackend();
    backend.deleting = (request) async {
      backend.items.removeWhere((item) => item['id'] == 'first');
      return _json({
        'deletedIds': ['first'],
        'failed': [],
        'deletedBytes': 0,
        'cleanupPendingCount': 1,
        'cleanupPendingBytes': 1048576,
      });
    };
    await _withLibrary(tester, (backend, _) async {
      await _tapVisible(tester, _key('media-select-first'));
      await _openBulkDeletePreview(tester);
      await _tapVisible(tester, _key('media-delete-confirm'));
      expect(backend.deletes, hasLength(1));
      expect(_key('media-file-first'), findsNothing);
      expect(_key('media-file-second'), findsOneWidget);
      expect(tester.widget<Text>(_key('media-selection-count')).data,
          startsWith('0 נבחרו'));
      expect(find.textContaining('הקובץ נמחק'), findsOneWidget);
      expect(find.textContaining('פינוי האחסון והגיבוי של 1 קבצים יושלם בהמשך'),
          findsOneWidget);
      expect(find.textContaining('ופונו'), findsNothing);
      expect(find.textContaining('לא נמחקו'), findsNothing);
      expect(find.textContaining('נכשלה'), findsNothing);
    }, backend: backend);
  });

  testWidgets(
      'transient server refusal keeps the file and shows the delete error',
      (tester) async {
    final backend = _MediaBackend()
      ..deleting =
          (request) async => _json({'error': 'השרת אינו זמין כרגע'}, 503);
    await _withLibrary(tester, (backend, token) async {
      await _tapVisible(tester, _key('media-delete-first'));
      await tester.tap(find.widgetWithText(FilledButton, 'מחק לצמיתות'));
      await tester.pumpAndSettle();
      expect(backend.deletes, hasLength(1));
      expect(find.text('first.pdf'), findsOneWidget);
      expect(find.textContaining('השרת אינו זמין כרגע'), findsOneWidget);
    }, backend: backend);
  });

  testWidgets('a delete confirmation cannot carry over to another account',
      (tester) async {
    await _withLibrary(tester, (backend, token) async {
      await _tapVisible(tester, _key('media-delete-first'));
      token.value = 'personal-media-user-b';
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'מחק לצמיתות'));
      await tester.pumpAndSettle();
      expect(backend.deletes, isEmpty);
      expect(find.text('first.pdf'), findsOneWidget);
    });
  });

  testWidgets('changed delete preview requires a second explicit confirmation',
      (tester) async {
    final backend = _MediaBackend();
    backend.deleting = (request) async {
      final body = jsonDecode(request.body) as Map;
      if (backend.deletes.length == 1) {
        expect(body['confirmationToken'], 'preview-token-1');
        return _json({
          'code': 'DELETE_PREVIEW_CHANGED',
          'preview': backend.deletePreview(
            ['first'],
            confirmationToken: 'preview-token-2',
            pendingRecipients: [
              {'id': _friendId, 'name': 'נמען שהתווסף', 'count': 1},
            ],
          ),
        }, 409);
      }
      expect(body['confirmationToken'], 'preview-token-2');
      backend.items.removeWhere((item) => item['id'] == 'first');
      return _json({
        'deletedIds': ['first'],
        'failed': [],
        'deletedBytes': 1048576
      });
    };
    await _withLibrary(tester, (backend, _) async {
      await _tapVisible(tester, _key('media-delete-first'));
      expect(backend.deletes, isEmpty);
      await _tapVisible(tester, _key('media-delete-confirm'));
      expect(backend.deletes, hasLength(1));
      expect(
          find.text('מצב הקבצים השתנה. יש לבדוק ולאשר שוב.'), findsOneWidget);
      expect(find.textContaining('נמען שהתווסף'), findsOneWidget);
      expect(_key('media-file-first'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(backend.deletes, hasLength(1));

      await _tapVisible(tester, _key('media-delete-confirm'));
      expect(backend.deletes, hasLength(2));
      expect(_key('media-file-first'), findsNothing);
      expect(_key('media-file-second'), findsOneWidget);
      expect(backend.requests.where((request) => request.method == 'DELETE'),
          isEmpty);
    }, backend: backend);
  });

  testWidgets(
      'late delete preview cannot expose prior-account recipients or delete',
      (tester) async {
    final backend = _MediaBackend();
    final gate = Completer<http.Response>();
    backend.previewing = (_) => gate.future;
    await _withLibrary(tester, (backend, token) async {
      await tester.ensureVisible(_key('media-delete-first'));
      await tester.tap(_key('media-delete-first'));
      await tester.pump();
      expect(backend.deletePreviews, hasLength(1));
      token.value = 'personal-media-user-b';
      await tester.pump();
      gate.complete(_json(backend.deletePreview(
        ['first'],
        pendingRecipients: [
          {'id': _friendId, 'name': 'איש קשר של החשבון הקודם', 'count': 1},
        ],
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('איש קשר של החשבון הקודם'), findsNothing);
      expect(_key('media-delete-confirm'), findsNothing);
      expect(backend.deletes, isEmpty);
      expect(backend.deletePreviews.single.headers['Authorization'],
          'Bearer $_token');
    }, backend: backend);
  });

  testWidgets(
      'bulk delete includes linked media and preserves only failed selections',
      (tester) async {
    final backend = _MediaBackend()
      ..items = [
        _file('first'),
        _file('second'),
        _file('protected', canDelete: false),
      ];
    backend.deleting = (request) async {
      backend.items.removeWhere((item) => item['id'] != 'second');
      return _json({
        'deletedIds': ['first', 'protected'],
        'failed': [
          {
            'id': 'second',
            'error': 'המחיקה נכשלה זמנית',
            'code': 'DELETE_FAILED'
          },
        ],
        'deletedBytes': 2097152,
      });
    };
    await _withLibrary(tester, (backend, token) async {
      expect(tester.widget<Checkbox>(_key('media-select-protected')).onChanged,
          isNotNull);
      await _tapVisible(tester, _key('media-select-protected'));
      await _tapVisible(tester, _key('media-select-first'));
      await _tapVisible(tester, _key('media-select-second'));
      await _openBulkDeletePreview(tester);
      expect(backend.deletes, isEmpty);
      expect(backend.deletePreviews, hasLength(1));
      expect(jsonDecode(backend.deletePreviews.single.body)['ids'],
          unorderedEquals(['first', 'second', 'protected']));
      await tester.tap(find.widgetWithText(FilledButton, 'מחק לצמיתות'));
      await tester.pumpAndSettle();
      expect(backend.deletes, hasLength(1));
      expect(jsonDecode(backend.deletes.single.body)['ids'],
          unorderedEquals(['first', 'second', 'protected']));
      expect(find.text('first.pdf'), findsNothing);
      expect(find.text('second.pdf'), findsOneWidget);
      expect(find.text('protected.pdf'), findsNothing);
      expect(
          tester.widget<Checkbox>(_key('media-select-second')).value, isTrue);
      expect(tester.widget<Text>(_key('media-selection-count')).data,
          startsWith('1 נבחרו'));
      expect(find.textContaining('לא נמחק'), findsOneWidget);
    }, backend: backend);
  });

  testWidgets(
      'delete preview names pending recipients and cancellation performs no deletion',
      (tester) async {
    final backend = _MediaBackend()
      ..items = [_file('protected', canDelete: false)];
    backend.previewing = (request) async => _json(backend.deletePreview(
          jsonDecode(request.body)['ids'] as List<dynamic>,
          pendingRecipients: [
            {'id': _friendId, 'name': 'דנה לוי', 'count': 1},
            {
              'id': 'waiting-person',
              'name': 'אורי כהן',
              'groupId': _groupId,
              'groupName': 'קבוצת המטיילים',
              'count': 2
            },
          ],
          linkedUses: [
            {'type': 'messages', 'count': 3}
          ],
        ));
    await _withLibrary(tester, (backend, token) async {
      await _tapVisible(tester, _key('media-delete-protected'));
      expect(backend.deletePreviews, hasLength(1));
      expect(backend.deletes, isEmpty);
      for (final name in ['דנה לוי', 'אורי כהן', 'קבוצת המטיילים']) {
        expect(
            find.descendant(
                of: find.byType(AlertDialog),
                matching: find.textContaining(name)),
            findsOneWidget);
      }
      expect(find.textContaining('טרם התקבל'), findsWidgets);
      await tester.tap(find.widgetWithText(TextButton, 'ביטול'));
      await tester.pumpAndSettle();
      expect(backend.deletes, isEmpty);
      expect(backend.requests.where((request) => request.method == 'DELETE'),
          isEmpty);
      expect(find.text('protected.pdf'), findsOneWidget);
    }, backend: backend);
  });

  testWidgets('selection survives search, sort, table and newly loaded pages',
      (tester) async {
    final backend = _MediaBackend()..total = 3;
    await _withLibrary(tester, (backend, _) async {
      await _tapVisible(tester, _key('media-select-first'));
      backend.listing = (request) async {
        if (request.url.queryParameters['search'] == 'second') {
          return _json({
            'total': 1,
            'items': [_file('second')],
            'totalBytes': 1048576
          });
        }
        if (request.url.queryParameters['offset'] == '2') {
          return _json({
            'total': 3,
            'items': [_file('third')],
            'totalBytes': 3145728
          });
        }
        return _json({
          'total': 3,
          'items': [_file('first'), _file('second')],
          'totalBytes': 3145728
        });
      };
      await _search(tester, 'second');
      expect(find.textContaining('1 מחוץ לסינון הנוכחי'), findsOneWidget);
      await _tapVisible(tester, _key('media-select-second'));
      expect(tester.widget<Text>(_key('media-selection-count')).data,
          startsWith('2 נבחרו'));
      await _search(tester, '');
      await _tapVisible(tester, _key('media-sort'));
      await _tapVisible(tester, find.text('הגדול ביותר').last);
      await _tapVisible(tester, _key('media-view-table'));
      expect(tester.widget<Checkbox>(_key('media-select-first')).value, true);
      expect(tester.widget<Checkbox>(_key('media-select-second')).value, true);
      await _tapVisible(tester, _key('media-load-more'));
      await _tapVisible(tester, _key('media-select-third'));
      await _tapVisible(tester, _key('media-view-list'));
      expect(tester.widget<Text>(_key('media-selection-count')).data,
          startsWith('3 נבחרו'));
      expect(tester.widget<Checkbox>(_key('media-select-first')).value, true);
      expect(tester.widget<Checkbox>(_key('media-select-third')).value, true);
    }, backend: backend);
  });

  testWidgets('rename updates selected media and uses the owner endpoint',
      (tester) async {
    final backend = _MediaBackend()..items = [_file('first', canDelete: false)];
    await _withLibrary(tester, (backend, _) async {
      await _tapVisible(tester, _key('media-select-first'));
      await _tapVisible(tester, _key('media-rename-first'));
      expect(
          tester.widget<TextField>(_key('media-rename-input')).controller!.text,
          'first');
      await tester.enterText(_key('media-rename-input'), 'שם חדש');
      await _tapVisible(tester, _key('media-rename-save'));
      final patches = backend.requests
          .where((request) => request.method == 'PATCH')
          .toList();
      expect(patches, hasLength(1));
      expect(patches.single.url.path, endsWith('/media-library/first'));
      expect(patches.single.headers['Authorization'], 'Bearer $_token');
      expect(jsonDecode(patches.single.body), {'name': 'שם חדש.pdf'});
      expect(find.text('שם חדש.pdf'), findsOneWidget);
      expect(tester.widget<Checkbox>(_key('media-select-first')).value, true);
      await _tapVisible(tester, _key('media-forward-selected'));
      await _tapVisible(tester, _key('forward-target-user:$_friendId'));
      await _tapVisible(
          tester, find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
      final sent = backend.requests.singleWhere((request) =>
          request.method == 'POST' && request.url.path.endsWith('/messages'));
      expect(jsonDecode(sent.body)['fileName'], 'שם חדש.pdf');
    }, backend: backend);
  });

  for (final view in ['list', 'table']) {
    testWidgets('$view filename opens rename and preserves the original suffix',
        (tester) async {
      final backend = _MediaBackend()
        ..items = [_file('first', name: 'first.PDF')];
      await _withLibrary(tester, (backend, _) async {
        await _tapVisible(tester, _key('media-view-$view'));
        expect(tester.widget<Checkbox>(_key('media-select-first')).onChanged,
            isNotNull);
        await _tapVisible(tester, _key('media-rename-first'));
        expect(
            tester
                .widget<TextField>(_key('media-rename-input'))
                .controller!
                .text,
            'first');
        expect(
            tester.widget<Text>(_key('media-rename-extension')).data, '.PDF');
        await tester.enterText(_key('media-rename-input'), 'שם מתוך $view');
        await _tapVisible(tester, _key('media-rename-save'));
        final patch = backend.requests
            .singleWhere((request) => request.method == 'PATCH');
        expect(patch.url.path, endsWith('/media-library/first'));
        expect(jsonDecode(patch.body), {'name': 'שם מתוך $view.PDF'});
        expect(find.text('שם מתוך $view.PDF'), findsOneWidget);
        expect(
            tester.widget<Checkbox>(_key('media-select-first')).value, isFalse);
      }, backend: backend);
    });
  }

  testWidgets(
      'select all loads every matching page and forwards every selected file',
      (tester) async {
    final all = [
      _file('first'),
      _file('second'),
      _file('third', canDelete: false),
      _file('fourth'),
      _file('fifth'),
    ];
    final backend = _MediaBackend()..items = all;
    backend.listing = (request) async {
      final offset =
          int.tryParse(request.url.queryParameters['offset'] ?? '') ?? 0;
      return _json({
        'total': all.length,
        'totalBytes': all.length * 1048576,
        'items': all.skip(offset).take(2).toList(),
      });
    };
    await _withLibrary(tester, (backend, _) async {
      expect(
          tester.widget<Checkbox>(_key('media-select-first')).value, isFalse);
      await _search(tester, 'matching-query');
      await _tapVisible(tester, _key('media-select-all'));
      expect(tester.widget<Text>(_key('media-selection-count')).data,
          startsWith('5 נבחרו'));
      expect(
          backend.listings
              .map((request) => request.url.queryParameters['offset']),
          containsAll(['2', '4']));
      final laterPages = backend.listings.where((request) =>
          const ['2', '4'].contains(request.url.queryParameters['offset']));
      expect(laterPages.map((request) => request.url.queryParameters['search']),
          everyElement('matching-query'));
      expect(backend.requests.where((request) => request.method == 'POST'),
          isEmpty);
      await _tapVisible(tester, _key('media-forward-selected'));
      await _tapVisible(tester, _key('forward-target-user:$_friendId'));
      await _tapVisible(
          tester, find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
      final sends = backend.requests
          .where((request) =>
              request.method == 'POST' &&
              request.url.path.endsWith('/messages'))
          .toList();
      expect(sends, hasLength(5));
      expect(sends.map((request) => jsonDecode(request.body)['fileUrl']),
          unorderedEquals(all.map((item) => item['url'])));
      expect(sends.map((request) => jsonDecode(request.body)['toUserId']),
          everyElement(_friendId));
      expect(
          backend.requests
              .where((request) => request.url.path.endsWith('/upload')),
          isEmpty);
      expect(tester.widget<Text>(_key('media-selection-count')).data,
          startsWith('0 נבחרו'));
    }, backend: backend);
  });

  testWidgets(
      'clear selection also clears selected files outside the current search',
      (tester) async {
    await _withLibrary(tester, (backend, _) async {
      await _tapVisible(tester, _key('media-select-first'));
      backend.listing = (request) async => _json({
            'total': request.url.queryParameters['search'] == 'second' ? 1 : 2,
            'items': request.url.queryParameters['search'] == 'second'
                ? [_file('second')]
                : [_file('first'), _file('second')],
          });
      await _search(tester, 'second');
      await _tapVisible(tester, _key('media-select-second'));
      expect(tester.widget<Text>(_key('media-selection-count')).data,
          startsWith('2 נבחרו'));
      await _tapVisible(tester, _key('media-clear-selection'));
      await _search(tester, '');
      expect(
          tester.widget<Checkbox>(_key('media-select-first')).value, isFalse);
      expect(
          tester.widget<Checkbox>(_key('media-select-second')).value, isFalse);
      expect(
          backend.requests.every((request) => request.method == 'GET'), isTrue);
    });
  });

  testWidgets(
      'changing the query during select all does not select late old results',
      (tester) async {
    final backend = _MediaBackend()..total = 3;
    final gate = Completer<http.Response>();
    backend.listing = (request) async {
      if (request.url.queryParameters['search'] == 'new-query') {
        return _json({
          'total': 1,
          'items': [_file('new-result')]
        });
      }
      if (request.url.queryParameters['offset'] == '2') return gate.future;
      return _json({
        'total': 3,
        'items': [_file('first'), _file('second')]
      });
    };
    await _withLibrary(tester, (backend, _) async {
      await tester.ensureVisible(_key('media-select-all'));
      await tester.tap(_key('media-select-all'));
      await tester.pump();
      expect(backend.listings.last.url.queryParameters['offset'], '2');
      await _search(tester, 'new-query');
      expect(_key('media-file-new-result'), findsOneWidget);
      expect(tester.widget<Checkbox>(_key('media-select-new-result')).value,
          isFalse);

      gate.complete(_json({
        'total': 3,
        'items': [_file('late-old-result')]
      }));
      await tester.pumpAndSettle();
      expect(_key('media-file-late-old-result'), findsNothing);
      expect(_key('media-file-first'), findsNothing);
      expect(tester.widget<Checkbox>(_key('media-select-new-result')).value,
          isFalse);
      // Selecting the current row exposes the total, revealing any stale picks.
      await _tapVisible(tester, _key('media-select-new-result'));
      expect(tester.widget<Text>(_key('media-selection-count')).data,
          startsWith('1 נבחרו'));
      expect(find.textContaining('מחוץ לסינון הנוכחי'), findsNothing);
      expect(
          backend.requests.every((request) => request.method == 'GET'), isTrue);
    }, backend: backend);
  });

  testWidgets('rename refusal keeps the original file name and selection',
      (tester) async {
    final backend = _MediaBackend()
      ..items = [_file('first')]
      ..renaming = (_) async => _json({'error': 'השם אינו תקין'}, 400);
    await _withLibrary(tester, (backend, _) async {
      await _tapVisible(tester, _key('media-select-first'));
      await _tapVisible(tester, find.byTooltip('פעולות'));
      await _tapVisible(tester, find.text('שינוי שם הקובץ'));
      await tester.enterText(_key('media-rename-input'), 'שם אחר');
      await _tapVisible(tester, _key('media-rename-save'));
      expect(find.text('first.pdf'), findsOneWidget);
      expect(find.text('השם אינו תקין'), findsOneWidget);
      expect(tester.widget<Checkbox>(_key('media-select-first')).value, true);
    }, backend: backend);
  });

  testWidgets('a rename dialog cannot save into another account',
      (tester) async {
    final backend = _MediaBackend()..items = [_file('first')];
    await _withLibrary(tester, (backend, token) async {
      await _tapVisible(tester, find.byTooltip('פעולות'));
      await _tapVisible(tester, find.text('שינוי שם הקובץ'));
      await tester.enterText(_key('media-rename-input'), 'שם אחר');
      token.value = 'personal-media-user-b';
      await tester.pumpAndSettle();
      await _tapVisible(tester, _key('media-rename-save'));
      expect(backend.requests.where((request) => request.method == 'PATCH'),
          isEmpty);
      expect(find.text('first.pdf'), findsOneWidget);
    }, backend: backend);
  });

  testWidgets(
      'bulk forwarding includes protected selections outside the search',
      (tester) async {
    final backend = _MediaBackend()
      ..items = [_file('first', canDelete: false), _file('second')];
    await _withLibrary(tester, (backend, _) async {
      await _tapVisible(tester, _key('media-select-first'));
      backend.listing = (_) async => _json({
            'total': 1,
            'items': [_file('second')]
          });
      await _search(tester, 'second');
      await _tapVisible(tester, _key('media-select-second'));
      await _tapVisible(tester, _key('media-forward-selected'));
      await _tapVisible(tester, _key('forward-target-user:$_friendId'));
      await _tapVisible(tester, _key('forward-target-group:$_groupId'));
      await _tapVisible(
          tester, find.widgetWithText(FilledButton, 'העבר ל־2 יעדים'));
      final sent = backend.requests
          .where((request) =>
              request.method == 'POST' &&
              request.url.path.endsWith('/messages'))
          .toList();
      expect(sent, hasLength(4));
      expect(
          sent.map((request) => jsonDecode(request.body)['fileUrl']),
          unorderedEquals([
            '/uploads/first.pdf',
            '/uploads/second.pdf',
            '/uploads/first.pdf',
            '/uploads/second.pdf'
          ]));
      expect(
          backend.requests
              .where((request) => request.url.path.endsWith('/upload')),
          isEmpty);
      expect(backend.deletes, isEmpty);
      expect(tester.widget<Text>(_key('media-selection-count')).data,
          startsWith('0 נבחרו'));
    }, backend: backend);
  });

  testWidgets(
      'cancelled and failed forwarding preserve selections; successes alone clear',
      (tester) async {
    await _withLibrary(tester, (backend, _) async {
      await _tapVisible(tester, _key('media-select-first'));
      await _tapVisible(tester, _key('media-select-second'));
      await _tapVisible(tester, _key('media-forward-selected'));
      await _tapVisible(tester, find.byTooltip('ביטול העברה'));
      expect(tester.widget<Checkbox>(_key('media-select-first')).value, true);
      expect(tester.widget<Checkbox>(_key('media-select-second')).value, true);
      backend.forwarding = (request) async =>
          jsonDecode(request.body)['fileUrl'] == '/uploads/first.pdf'
              ? _json({'ok': true})
              : _json({'error': 'השליחה נכשלה'}, 500);
      await _tapVisible(tester, _key('media-forward-selected'));
      await _tapVisible(tester, _key('forward-target-user:$_friendId'));
      await _tapVisible(
          tester, find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
      expect(tester.widget<Checkbox>(_key('media-select-first')).value, false);
      expect(tester.widget<Checkbox>(_key('media-select-second')).value, true);
      expect(tester.widget<Text>(_key('media-selection-count')).data,
          startsWith('1 נבחרו'));
    });
  });

  testWidgets(
      'fresh visibility reconciles selections and blocks hidden forwarding',
      (tester) async {
    await _withLibrary(tester, (backend, _) async {
      await _tapVisible(tester, _key('media-select-first'));
      backend.items = [
        {..._file('first'), 'filterHidden': true, 'url': null}
      ];
      await _tapVisible(tester, find.byTooltip('רענון המדיה'));
      expect(tester.widget<Checkbox>(_key('media-select-first')).value, true);
      expect(
          tester.widget<FilledButton>(_key('media-forward-selected')).onPressed,
          isNull);
      receivingFilterChanges.add(_token);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(_key('media-select-first')).value, false);
    });
  });

  testWidgets(
      'receiving filter changes while forwarding chooser is open stop sending',
      (tester) async {
    await _withLibrary(tester, (backend, _) async {
      await _tapVisible(tester, _key('media-select-first'));
      await _tapVisible(tester, _key('media-forward-selected'));
      await _tapVisible(tester, _key('forward-target-user:$_friendId'));
      receivingFilterChanges.add(_token);
      await tester.pumpAndSettle();
      await _tapVisible(
          tester, find.widgetWithText(FilledButton, 'העבר ל־1 יעדים'));
      expect(
          backend.requests.where((request) =>
              request.method == 'POST' &&
              request.url.path.endsWith('/messages')),
          isEmpty);
      expect(tester.widget<Checkbox>(_key('media-select-first')).value, false);
    });
  });

  testWidgets(
      'grouped deletion confirms copies and keeps the failed copy selected',
      (tester) async {
    final backend = _MediaBackend()
      ..items = [
        {
          ..._file('first'),
          'duplicateIds': ['first', 'copy'],
          'duplicateCount': 2,
          'storageBytes': 2097152
        }
      ];
    backend.deleting = (request) async {
      backend.items = [_file('copy')];
      return _json({
        'deletedIds': ['first'],
        'failed': [
          {
            'id': 'copy',
            'error': 'מחיקת העותק נכשלה זמנית',
            'code': 'DELETE_FAILED'
          },
        ],
        'deletedBytes': 1048576,
      });
    };
    backend.previewing = (request) async => _json({
          ...backend
              .deletePreview(jsonDecode(request.body)['ids'] as List<dynamic>),
          'fileCount': 1,
          'copyCount': 2,
        });
    await _withLibrary(tester, (backend, _) async {
      await _tapVisible(tester, _key('media-select-first'));
      await _openBulkDeletePreview(tester);
      expect(find.textContaining('יימחקו כל 2 העותקים הזהים'), findsOneWidget);
      expect(backend.deletePreviews, hasLength(1));
      expect(jsonDecode(backend.deletePreviews.single.body), {
        'ids': ['first', 'copy']
      });
      expect(backend.deletes, isEmpty);
      await _tapVisible(
          tester, find.widgetWithText(FilledButton, 'מחק לצמיתות'));
      expect(backend.deletes, hasLength(1));
      expect(jsonDecode(backend.deletes.single.body)['ids'], ['first', 'copy']);
      expect(find.text('first.pdf'), findsNothing);
      expect(find.text('copy.pdf'), findsOneWidget);
      expect(tester.widget<Checkbox>(_key('media-select-copy')).value, true);
      expect(tester.widget<Text>(_key('media-selection-count')).data,
          startsWith('1 נבחרו'));
    }, backend: backend);
  });
}
