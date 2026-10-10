import 'dart:convert';
import 'package:betshuva/chat_file_name.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
      'sticker labels and rename controls are hidden without an owner lookup',
      (tester) async {
    var lookups = 0;
    final client = MockClient((_) async {
      lookups++;
      throw StateError('Sticker name lookup must not run');
    });
    await http.runWithClient(() async {
      for (final filename in [
        'betshuva-sticker-01.png',
        'betshuva-sticker-sticker-22.png',
        'betshuva-sticker-sticker-95.png',
        'betshuva-sticker-sticker-145.png',
        'betshuva-sticker-שבת שלום.webp',
        'betshuva-sticker-new.gif',
        'betshuva-sticker-new.jpg',
        'BETSHUVA-STICKER-new.JPEG',
      ]) {
        for (final editable in [true, false]) {
          await tester.pumpWidget(MaterialApp(
              home: Scaffold(
                  body: ChatFileName(
                      api: 'https://example.test/api',
                      token: 'owner',
                      url: '/uploads/sticker.png',
                      filename: filename,
                      editable: editable))));
          await tester.pumpAndSettle();
          expect(find.text(filename), findsNothing);
          expect(find.byIcon(Icons.edit_outlined), findsNothing);
          expect(find.byType(InkWell), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      expect(lookups, 0);
    }, () => client);
    client.close();
  });
  testWidgets('chat rename saves the owner filename and survives reopening',
      (tester) async {
    var saved = 'original.JPG';
    var writes = 0;
    String? changed;
    final client = MockClient((request) async {
      if (request.method == 'PATCH') {
        writes++;
        saved = jsonDecode(request.body)['name'] as String;
      }
      return http.Response(
          jsonEncode({
            'item': {'id': 'owned-file', 'name': saved}
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    Widget app() => MaterialApp(
        home: Scaffold(
            body: ChatFileName(
                api: 'https://example.test/api',
                token: 'owner',
                url: '/uploads/original.JPG',
                filename: 'original.JPG',
                editable: true,
                onRenamed: (name) => changed = name)));
    await http.runWithClient(() async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('original.JPG'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('media-rename-input')), 'שם חדש');
      await tester.tap(find.byKey(const ValueKey('media-rename-save')));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(changed, 'שם חדש.JPG');
      expect(find.text('שם חדש.JPG'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('שם חדש.JPG'), findsOneWidget);
    }, () => client);
    client.close();
  });

  testWidgets('received filenames stay visible without owner write controls',
      (tester) async {
    final client =
        MockClient((_) async => throw StateError('Unexpected owner lookup'));
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: ChatFileName(
                  api: 'https://example.test/api',
                  token: 'recipient',
                  url: '/uploads/movie.mp4',
                  filename: 'movie.mp4',
                  editable: false))));
      await tester.pumpAndSettle();
      expect(find.text('movie.mp4'), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      await tester.tap(find.text('movie.mp4'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    }, () => client);
    client.close();
  });
}
