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
    final client = MockClient(
        (_) async => throw StateError('Sticker name lookup must not run'));
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: ChatFileName(
                  api: 'https://example.test/api',
                  token: 'owner',
                  url: '/uploads/sticker.png',
                  filename: 'betshuva-sticker-01.png',
                  editable: true))));
      await tester.pumpAndSettle();
      expect(find.text('betshuva-sticker-01.png'), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.byType(InkWell), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    }, () => client);
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
