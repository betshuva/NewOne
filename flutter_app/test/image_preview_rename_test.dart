import 'dart:async';
import 'dart:convert';

import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _firstUrl = 'https://example.test/rename-first.png';
const _secondUrl = 'https://example.test/rename-second.png';
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'chat viewer resolves owner name, renames it and reloads on reopen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    const url = '$kServer/uploads/chat-rename.png';
    const fileId = '88000000-0000-4000-8000-000000000011';
    var savedName = 'owner-name.JPG';
    var lookups = 0;
    var renames = 0;
    Widget preview() => const MaterialApp(
          home: ImagePreviewScreen(
            url: url,
            filename: 'stale-message-name.jpg',
            filterToken: 'test-token',
          ),
        );
    await http.runWithClient(() async {
      await tester.pumpWidget(preview());
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(lookups, 1);
      expect(find.text('owner-name.JPG'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('image-preview-rename')));
      await tester.pump(const Duration(milliseconds: 300));
      final input = find.byKey(const ValueKey('media-rename-input'));
      expect(tester.widget<TextField>(input).controller!.text, 'owner-name');
      expect(find.text('.JPG'), findsOneWidget);
      await tester.enterText(input, 'שמי החדש');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('media-rename-save')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(renames, 1);
      expect(lookups, 1);
      expect(find.text('שמי החדש.JPG'), findsOneWidget);
      expect(find.byType(ImagePreviewScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(preview());
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(lookups, 2);
      expect(find.text('שמי החדש.JPG'), findsOneWidget);
      expect(find.text('stale-message-name.jpg'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/media-library/resolve')) {
                lookups++;
                expect(request.headers['Authorization'], 'Bearer test-token');
                expect(request.url.queryParameters['url'],
                    '/betshuva-app/uploads/chat-rename.png');
                return http.Response(
                    jsonEncode({
                      'item': {'id': fileId, 'name': savedName}
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8'
                    });
              }
              if (request.method == 'PATCH') {
                renames++;
                expect(request.url.path.endsWith('/media-library/$fileId'),
                    isTrue);
                expect(request.headers['Authorization'], 'Bearer test-token');
                expect(jsonDecode(request.body), {'name': 'שמי החדש.JPG'});
                savedName = 'שמי החדש.JPG';
                return http.Response(
                    jsonEncode({
                      'item': {'id': fileId, 'name': savedName}
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8'
                    });
              }
              return http.Response.bytes(_png, 200,
                  headers: {'content-type': 'image/png'});
            }));
  });

  testWidgets('unowned viewer images keep navigation without enabling rename',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final lookups = <String>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
        home: ImagePreviewScreen(
          url: _firstUrl,
          urls: [_firstUrl, _secondUrl],
          filenames: ['first.PNG', 'second.png'],
          filterToken: 'test-token',
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('image-preview-rename')), findsNothing);
      expect(find.text('first.PNG'), findsOneWidget);
      await tester.tap(find.byTooltip('התמונה הבאה'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('second.png'), findsOneWidget);
      expect(find.byKey(const ValueKey('image-preview-rename')), findsNothing);
      await tester.tap(find.byTooltip('התמונה הקודמת'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(lookups, [_firstUrl, _secondUrl]);
      expect(find.text('1 / 2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              expect(request.method, 'GET');
              if (request.url.path.endsWith('/media-library/resolve')) {
                lookups.add(request.url.queryParameters['url']!);
                return http.Response('{}', 404);
              }
              return http.Response.bytes(_png, 200,
                  headers: {'content-type': 'image/png'});
            }));
  });

  testWidgets(
      'rename updates the requested image while page navigation remains',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final gate = Completer<String?>();
    final renamed = <(String, String?)>[];
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: ImagePreviewScreen(
          url: _firstUrl,
          urls: const [_firstUrl, _secondUrl],
          filenames: const ['first.PNG', 'second.png'],
          onRename: (url, filename) {
            renamed.add((url, filename));
            return gate.future;
          },
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      final renameButton = find.byKey(const ValueKey('image-preview-rename'));
      await tester.tap(renameButton);
      await tester.pump();
      expect(renamed, [(_firstUrl, 'first.PNG')]);
      expect(tester.widget<TextButton>(renameButton).onPressed, isNull);

      await tester.tap(find.byTooltip('התמונה הבאה'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('second.png'), findsOneWidget);
      gate.complete('renamed.PNG');
      await tester.pump();
      expect(find.text('second.png'), findsOneWidget);
      expect(find.text('renamed.PNG'), findsNothing);

      await tester.tap(find.byTooltip('התמונה הקודמת'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('renamed.PNG'), findsOneWidget);
      expect(find.text('first.PNG'), findsNothing);
      expect(find.byType(ImagePreviewScreen), findsOneWidget);
      expect(renamed, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
        () => MockClient((_) async => http.Response.bytes(_png, 200,
            headers: {'content-type': 'image/png'})));
  });

  testWidgets('cancelled rename preserves name and preview route',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
        home: ImagePreviewScreen(
          url: _firstUrl,
          filename: 'original.PNG',
          onRename: (_, __) async {
            calls++;
            return null;
          },
        ),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const ValueKey('image-preview-rename')));
      await tester.pump();
      expect(calls, 1);
      expect(find.text('original.PNG'), findsOneWidget);
      expect(find.byType(ImagePreviewScreen), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
        () => MockClient((_) async => http.Response.bytes(_png, 200,
            headers: {'content-type': 'image/png'})));
  });
}
