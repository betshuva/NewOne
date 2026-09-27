import 'dart:convert';

import 'package:betshuva/system_audit_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _api = 'https://example.test/betshuva-app/api';
const _catalog = {'actions': [], 'statuses': [], 'categories': []};
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');

Map<String, dynamic> _event(int id, {bool preview = true}) => {
      'id': '$id',
      'operation_id': 'operation-1',
      'created_at': '2026-09-25T09:00:01Z',
      'kind': 'provider_call_finished',
      'status': 'observed',
      'checkLabel': 'בדיקת צניעות הלבוש',
      'checkResultLabel': 'תוצאה לא ודאית',
      'details': {'provider': 'openai'},
      if (preview)
        'checkPreviewUrl': '/api/admin/audit/events/$id/preview?size=thumb',
      if (preview)
        'checkPreviewFullUrl': '/api/admin/audit/events/$id/preview?size=full',
    };

http.Response _json(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _Server {
  _Server(this.events, {this.thumbStatus = 200, this.fullStatus = 200});

  final List<Map<String, dynamic>> events;
  final int thumbStatus;
  final int fullStatus;
  final previews = <http.Request>[];

  Future<http.Response> respond(http.Request request) async {
    expect(request.method, 'GET');
    if (request.url.path.endsWith('/catalog')) return _json(_catalog);
    if (request.url.path.endsWith('/preview')) {
      previews.add(request);
      final status = request.url.queryParameters['size'] == 'full'
          ? fullStatus
          : thumbStatus;
      return http.Response.bytes(status == 200 ? _png : [], status, headers: {
        'content-type': status == 200 ? 'image/png' : 'application/json'
      });
    }
    if (request.url.path.endsWith('/events')) return _json({'events': events});
    return _json({
      'operations': [
        {
          'id': 'operation-1',
          'created_at': '2026-09-25T09:00:00Z',
          'action': 'upload_file',
          'status': 'completed',
          'event_count': events.length,
        }
      ]
    });
  }
}

Finder _key(String name) => find.byKey(ValueKey('system-audit-$name'));

Future<void> _mount(WidgetTester tester,
    {Size size = const Size(1500, 1100), String token = 'admin-token'}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
      MaterialApp(home: SystemAuditScreen(api: _api, token: token)));
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  expect(tester.takeException(), isNull);
}

void main() {
  for (final eventsMode in [false, true]) {
    testWidgets(
        '${eventsMode ? 'all events' : 'expanded events'} use authenticated cached thumbnails and full image',
        (tester) async {
      final server = _Server([_event(2)]);
      await http.runWithClient(() async {
        await _mount(tester);
        expect(server.previews, isEmpty);
        await _tap(tester,
            eventsMode ? find.text('כל האירועים') : _key('expand-operation-1'));
        expect(server.previews, hasLength(1));
        expect(server.previews.single.url.path,
            '/betshuva-app/api/admin/audit/events/2/preview');
        expect(server.previews.single.url.queryParameters, {'size': 'thumb'});
        expect(server.previews.single.headers['Authorization'],
            'Bearer admin-token');
        expect(find.byType(Image), findsOneWidget);
        expect(
            tester.widget<Image>(find.byType(Image)).image, isA<MemoryImage>());
        await _tap(tester, find.byTooltip('הגדל את התמונה שנבדקה'));
        expect(_key('preview-dialog'), findsOneWidget);
        expect(_key('preview-zoom'), findsOneWidget);
        expect(server.previews, hasLength(2));
        expect(server.previews.last.url.queryParameters, {'size': 'full'});
        expect(server.previews.last.headers['Authorization'],
            'Bearer admin-token');
        await _tap(tester, _key('preview-close'));
        expect(_key('preview-dialog'), findsNothing);
        await _tap(tester, find.byTooltip('הגדל את התמונה שנבדקה'));
        expect(server.previews, hasLength(2));
        await _tap(tester, _key('preview-close'));
        if (!eventsMode) {
          await _tap(tester, _key('expand-operation-1'));
          await _tap(tester, _key('expand-operation-1'));
          expect(server.previews, hasLength(2));
        }
        await _unmount(tester);
      }, () => MockClient(server.respond));
    });
  }

  for (final representativeAvailable in [true, false]) {
    testWidgets(
        'operation preview overrides later frame: $representativeAvailable',
        (tester) async {
      final event = _event(2);
      event['operationPreview'] = representativeAvailable
          ? {
              'eventId': '7',
              'mediaType': 'video',
              'url': '/api/admin/audit/events/7/preview?size=thumb',
              'fullUrl': '/api/admin/audit/events/7/preview?size=full',
            }
          : null;
      final server = _Server([event]);
      await http.runWithClient(() async {
        await _mount(tester);
        await _tap(tester, find.text('כל האירועים'));
        if (representativeAvailable) {
          expect(server.previews.single.url.path,
              '/betshuva-app/api/admin/audit/events/7/preview');
          await _tap(tester, find.byTooltip('הגדל את התמונה שנבדקה'));
          expect(server.previews.last.url.path,
              '/betshuva-app/api/admin/audit/events/7/preview');
          expect(server.previews.last.url.queryParameters['size'], 'full');
          await _tap(tester, _key('preview-close'));
        } else {
          expect(server.previews, isEmpty);
          expect(find.byType(Image), findsNothing);
        }
        await _unmount(tester);
      }, () => MockClient(server.respond));
    });
  }

  testWidgets(
      'historical events without preview fields do not reserve image space or fetch images',
      (tester) async {
    final server = _Server([_event(2, preview: false)]);
    await http.runWithClient(() async {
      await _mount(tester);
      await _tap(tester, _key('expand-operation-1'));
      expect(_key('preview-2'), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(server.previews, isEmpty);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  for (final status in [401, 403, 404]) {
    testWidgets(
        'thumbnail HTTP $status stays unavailable without retry or enlargement',
        (tester) async {
      final server = _Server([_event(2)], thumbStatus: status);
      await http.runWithClient(() async {
        await _mount(tester);
        await _tap(tester, _key('expand-operation-1'));
        expect(find.byTooltip('התמונה אינה זמינה'), findsOneWidget);
        expect(find.byTooltip('הגדל את התמונה שנבדקה'), findsNothing);
        expect(find.byType(Image), findsNothing);
        expect(server.previews, hasLength(1));
        await _unmount(tester);
      }, () => MockClient(server.respond));
    });
  }

  testWidgets('missing full image has a closable unavailable dialog',
      (tester) async {
    final server = _Server([_event(2)], fullStatus: 404);
    await http.runWithClient(() async {
      await _mount(tester);
      await _tap(tester, _key('expand-operation-1'));
      await _tap(tester, find.byTooltip('הגדל את התמונה שנבדקה'));
      expect(find.text('התמונה אינה זמינה'), findsOneWidget);
      expect(_key('preview-zoom'), findsNothing);
      await _tap(tester, _key('preview-close'));
      expect(_key('preview-dialog'), findsNothing);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets('offscreen thumbnails load only when vertically visible',
      (tester) async {
    final server = _Server([for (var id = 2; id < 42; id++) _event(id)]);
    await http.runWithClient(() async {
      await _mount(tester);
      await _tap(tester, _key('expand-operation-1'));
      expect(server.previews, isNotEmpty);
      expect(server.previews.length, lessThan(40));
      expect(
          server.previews
              .any((request) => request.url.path.contains('/events/41/')),
          isFalse);
      await tester.ensureVisible(_key('preview-41'));
      await tester.pumpAndSettle();
      expect(
          server.previews
              .any((request) => request.url.path.contains('/events/41/')),
          isTrue);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets(
      'mobile preview waits for horizontal visibility, fits the dialog and supports zoom',
      (tester) async {
    final server = _Server([_event(2)]);
    await http.runWithClient(() async {
      await _mount(tester, size: const Size(390, 844));
      await _tap(tester, _key('expand-operation-1'));
      expect(server.previews, isEmpty);
      await tester.ensureVisible(_key('preview-2'));
      await tester.pumpAndSettle();
      expect(server.previews, hasLength(1));
      await _tap(tester, find.byTooltip('הגדל את התמונה שנבדקה'));
      final rectangle = tester.getRect(_key('preview-dialog'));
      expect(rectangle.left, greaterThanOrEqualTo(0));
      expect(rectangle.right, lessThanOrEqualTo(390));
      expect(rectangle.top, greaterThanOrEqualTo(0));
      expect(rectangle.bottom, lessThanOrEqualTo(844));
      final center = tester.getCenter(_key('preview-zoom'));
      final first =
          await tester.startGesture(center - const Offset(20, 0), pointer: 1);
      final second =
          await tester.startGesture(center + const Offset(20, 0), pointer: 2);
      await tester.pump();
      await first.moveBy(const Offset(-40, 0));
      await second.moveBy(const Offset(40, 0));
      await tester.pump();
      final transforms = tester.widgetList<Transform>(find.descendant(
          of: _key('preview-zoom'), matching: find.byType(Transform)));
      expect(
          transforms.any((widget) => widget.transform.getMaxScaleOnAxis() > 1),
          isTrue);
      await first.up();
      await second.up();
      await _tap(tester, _key('preview-close'));
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets('authentication change closes the preview and clears image cache',
      (tester) async {
    final server = _Server([_event(2)]);
    await http.runWithClient(() async {
      await _mount(tester);
      await _tap(tester, _key('expand-operation-1'));
      await _tap(tester, find.byTooltip('הגדל את התמונה שנבדקה'));
      await tester.pumpWidget(const MaterialApp(
          home: SystemAuditScreen(api: _api, token: 'new-admin')));
      await tester.pumpAndSettle();
      expect(_key('preview-dialog'), findsNothing);
      await _tap(tester, _key('expand-operation-1'));
      expect(server.previews, hasLength(3));
      expect(server.previews.last.headers['Authorization'], 'Bearer new-admin');
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });

  testWidgets('preview URLs cannot send authorization to a different origin',
      (tester) async {
    final server = _Server([
      {
        ..._event(2),
        'checkPreviewUrl':
            'https://untrusted.example/api/admin/audit/events/2/preview?size=thumb',
      }
    ]);
    await http.runWithClient(() async {
      await _mount(tester);
      await _tap(tester, _key('expand-operation-1'));
      expect(server.previews, isEmpty);
      expect(find.byTooltip('התמונה אינה זמינה'), findsOneWidget);
      await _unmount(tester);
    }, () => MockClient(server.respond));
  });
}
