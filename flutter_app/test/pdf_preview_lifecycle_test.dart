import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:betshuva/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Keep the actual pdfrx widget and document-reference lifecycle, replacing only
// the engine so this test counts document opens/renders without network or FFI.
class _PdfEngine extends Fake implements PdfrxEntryFunctions {
  final opened = <_PdfDocument>[];

  @override
  Future<void> init() async {}

  @override
  Future<PdfDocument> openUri(
    Uri uri, {
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
    PdfDownloadProgressCallback? progressCallback,
    bool preferRangeAccess = false,
    Map<String, String>? headers,
    bool withCredentials = false,
    Duration? timeout,
  }) async {
    final document = _PdfDocument(uri.toString());
    opened.add(document);
    return document;
  }
}

class _PdfDocument extends Fake implements PdfDocument {
  _PdfDocument(this.sourceName);

  @override
  final String sourceName;
  late final page = _PdfPage(this);
  int disposals = 0;

  @override
  List<PdfPage> get pages => [page];

  @override
  Stream<PdfDocumentEvent> get events => const Stream.empty();

  @override
  Future<void> loadPagesProgressively<T>({
    PdfPageLoadingCallback<T>? onPageLoadProgress,
    T? data,
    Duration loadUnitDuration = const Duration(milliseconds: 250),
  }) async {}

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

class _PdfPage extends Fake implements PdfPage {
  _PdfPage(this.document);

  @override
  final _PdfDocument document;
  int renders = 0;

  @override
  int get pageNumber => 1;
  @override
  double get width => 600;
  @override
  double get height => 800;
  @override
  PdfPageRotation get rotation => PdfPageRotation.none;

  @override
  PdfPageRenderCancellationToken createCancellationToken() => _RenderToken();

  @override
  Future<PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    PdfPageRotation? rotationOverride,
    PdfAnnotationRenderingMode annotationRenderingMode =
        PdfAnnotationRenderingMode.annotationAndForms,
    int flags = PdfPageRenderFlags.none,
    PdfPageRenderCancellationToken? cancellationToken,
  }) async {
    renders++;
    return PdfImage.createFromBgraData(
      Uint8List.fromList([255, 255, 255, 255]),
      width: 1,
      height: 1,
    );
  }
}

class _RenderToken implements PdfPageRenderCancellationToken {
  @override
  bool isCanceled = false;

  @override
  void cancel() => isCanceled = true;
}

class _ChatServer {
  String fileUrl = '/uploads/pdf-preview-original.pdf';
  int historyReads = 0;

  Future<http.Response> respond(http.Request request) async {
    Object response = {};
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/messages/viewer')) {
      historyReads++;
      response = [
        {
          'id': 'pdf-message',
          'sender_id': 'viewer',
          'recipient_id': 'viewer',
          'type': 'document',
          'file_url': fileUrl,
          'file_name': 'document.pdf',
          'created_at': '2026-09-17T12:00:00Z',
          'message_status': 'read',
          'is_read': true,
        }
      ];
    } else if (path.endsWith('/filter-settings')) {
      response = {
        'filter': {'text': true},
        'requiresChoice': false,
      };
    } else if (path.endsWith('/receiving-filter')) {
      response = {
        'filter': {'text': true},
      };
    }
    return http.Response(jsonEncode(response), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }
}

Widget _chat() => MaterialApp(
      home: ChatScreen(
        key: const ValueKey('self-chat'),
        token: 'test-token',
        me: const {'id': 'viewer', 'name': 'אני'},
        recipient: const {'id': 'viewer', 'name': 'הודעות לעצמי'},
        socket: null,
        embedded: true,
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

void main() {
  late _PdfEngine engine;
  late _ChatServer server;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final previousEngine = PdfrxEntryFunctions.instance;
    final previousCachePath = Pdfrx.cacheDirectoryPath;
    engine = _PdfEngine();
    server = _ChatServer();
    PdfrxEntryFunctions.instance = engine;
    Pdfrx.cacheDirectoryPath = '/unused-pdf-test-cache';
    addTearDown(() {
      PdfrxEntryFunctions.instance = previousEngine;
      Pdfrx.cacheDirectoryPath = previousCachePath;
    });
  });

  testWidgets('self-chat PDF stays loaded and rendered across parent refreshes',
      (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(_chat());
      await _settle(tester);
      expect(engine.opened, hasLength(1));
      final document = engine.opened.single;
      expect(document.page.renders, 1);
      final pageState = tester.state(find.byType(PdfPageView));

      // Home refreshes its conversation list every ten seconds. Rebuilding the
      // same chat must preserve the loaded document and rendered first page.
      for (var refresh = 0; refresh < 3; refresh++) {
        await tester.pump(const Duration(seconds: 10));
        await tester.pumpWidget(_chat());
        await _settle(tester);
        expect(engine.opened, hasLength(1));
        expect(document.disposals, 0);
        expect(document.page.renders, 1);
        expect(tester.state(find.byType(PdfPageView)), same(pageState));
        expect(find.byType(CircularProgressIndicator), findsNothing);
      }
      expect(server.historyReads, greaterThan(1));

      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      expect(document.disposals, 1);
      expect(tester.takeException(), isNull);
    }, () => MockClient(server.respond));
  });

  testWidgets('a changed PDF URL replaces and renders the new document once',
      (tester) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(_chat());
      await _settle(tester);
      expect(engine.opened, hasLength(1));
      final original = engine.opened.single;

      server.fileUrl = '/uploads/pdf-preview-replacement.pdf';
      await tester.pump(const Duration(seconds: 4));
      await _settle(tester);
      expect(engine.opened, hasLength(2));
      expect(original.disposals, 1);
      final replacement = engine.opened.last;
      expect(replacement.sourceName, endsWith(server.fileUrl));
      expect(replacement.page.renders, 1);
      expect(tester.widget<PdfPageView>(find.byType(PdfPageView)).document,
          same(replacement));

      // Relative and absolute forms of the same effective URI also retain it.
      server.fileUrl = replacement.sourceName;
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpWidget(_chat());
      await _settle(tester);
      expect(engine.opened, hasLength(2));
      expect(replacement.disposals, 0);
      expect(replacement.page.renders, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      expect(replacement.disposals, 1);
      expect(tester.takeException(), isNull);
    }, () => MockClient(server.respond));
  });
}
