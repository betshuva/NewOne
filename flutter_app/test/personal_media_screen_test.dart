import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _token = 'personal-media-user-a';
const _friendId = '11111111-1111-4111-8111-111111111111';
const _groupId = '22222222-2222-4222-8222-222222222222';

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
  Future<http.Response> Function(http.Request)? deleting;

  List<http.Request> get listings => requests
      .where((request) =>
          request.method == 'GET' &&
          request.url.path.endsWith('/media-library'))
      .toList();

  List<http.Request> get deletes =>
      requests.where((request) => request.method == 'DELETE').toList();

  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    if (request.url.path.endsWith('/media-library/catalog')) {
      return catalog != null ? await catalog!(request) : _json(_catalog());
    }
    if (request.method == 'DELETE') {
      if (deleting != null) return deleting!(request);
      final id = request.url.pathSegments.last;
      final item = items.firstWhere((item) => item['id'] == id);
      items.removeWhere((item) => item['id'] == id);
      return _json({'ok': true, 'deletedBytes': item['size']});
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

Future<void> _search(WidgetTester tester, String value,
    {bool settle = true}) async {
  await tester.enterText(_key('media-search'), value);
  await tester.pump(const Duration(milliseconds: 400));
  if (settle) await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
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
      expect(find.text('מחיקה לצמיתות'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'מחק לצמיתות'));
      await tester.pumpAndSettle();
      expect(backend.deletes, hasLength(1));
      expect(backend.deletes.single.url.path, endsWith('/media-library/first'));
      expect(backend.deletes.single.headers['Authorization'], 'Bearer $_token');
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

  testWidgets('server refusal keeps the file and shows the delete error',
      (tester) async {
    final backend = _MediaBackend()
      ..deleting = (request) async =>
          _json({'error': 'הקובץ עדיין בשימוש בשיחה אחרת'}, 409);
    await _withLibrary(tester, (backend, token) async {
      await _tapVisible(tester, _key('media-delete-first'));
      await tester.tap(find.widgetWithText(FilledButton, 'מחק לצמיתות'));
      await tester.pumpAndSettle();
      expect(backend.deletes, hasLength(1));
      expect(find.text('first.pdf'), findsOneWidget);
      expect(find.text('הקובץ עדיין בשימוש בשיחה אחרת'), findsOneWidget);
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

  testWidgets('bulk delete preserves protected and server-rejected files',
      (tester) async {
    final backend = _MediaBackend()
      ..items = [
        _file('first'),
        _file('second'),
        _file('protected', canDelete: false),
      ];
    backend.deleting = (request) async {
      if (request.url.path.endsWith('/first')) {
        backend.items.removeWhere((item) => item['id'] == 'first');
        return _json({'ok': true, 'deletedBytes': 1048576});
      }
      return _json({'error': 'הקובץ עדיין בשימוש'}, 409);
    };
    await _withLibrary(tester, (backend, token) async {
      await _tapVisible(tester, _key('media-select-mode'));
      expect(tester.widget<Checkbox>(_key('media-select-protected')).onChanged,
          isNull);
      await _tapVisible(tester, _key('media-select-first'));
      await _tapVisible(tester, _key('media-select-second'));
      await _tapVisible(tester, _key('media-delete-selected'));
      expect(backend.deletes, isEmpty);
      expect(find.textContaining('2 קבצים שנבחרו'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'מחק לצמיתות'));
      await tester.pumpAndSettle();
      expect(backend.deletes.map((request) => request.url.pathSegments.last),
          ['first', 'second']);
      expect(find.text('first.pdf'), findsNothing);
      expect(find.text('second.pdf'), findsOneWidget);
      expect(find.text('protected.pdf'), findsOneWidget);
      expect(find.textContaining('לא נמחק'), findsOneWidget);
    }, backend: backend);
  });

  testWidgets('protected media explains usage without calling delete',
      (tester) async {
    final backend = _MediaBackend()
      ..items = [_file('protected', canDelete: false)];
    await _withLibrary(tester, (backend, token) async {
      await _tapVisible(tester, _key('media-delete-protected'));
      expect(find.text('הקובץ מוגן ממחיקה'), findsOneWidget);
      expect(backend.deletes, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'הצג שימושים'));
      await tester.pumpAndSettle();
      expect(find.text('לאן הקובץ שייך?'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('קבוצת המטיילים')),
          findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'סגור'));
      await tester.pumpAndSettle();
      expect(find.text('protected.pdf'), findsOneWidget);
    }, backend: backend);
  });
}
