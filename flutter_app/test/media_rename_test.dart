import 'package:betshuva/media_rename.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'basename edits retain the exact original extension and allow inner dots',
      () {
    expect(mediaFilenameBasename('תמונה.v2.JpG'), 'תמונה.v2');
    expect(mediaFilenameExtension('תמונה.v2.JpG'), '.JpG');
    expect(mediaFilenameFromBasename(' שם חדש ', 'תמונה.JpG'), 'שם חדש.JpG');
    expect(
        mediaFilenameFromBasename('גרסה.שנייה', 'תמונה.JpG'), 'גרסה.שנייה.JpG');
    expect(mediaFilenameFromBasename('שם חדש', 'ללא סיומת'), 'שם חדש');
    for (final name in ['', ' ', '.', '..', 'a/b', r'a\b', 'a\nb']) {
      expect(mediaFilenameFromBasename(name, 'original.JPG'), isNull);
    }
    expect(mediaFilenameFromBasename(List.filled(252, 'א').join(), 'photo.JPG'),
        isNull);
  });

  testWidgets('rename dialog edits only basename and returns fixed extension',
      (tester) async {
    String? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        return Scaffold(
          body: TextButton(
            onPressed: () async {
              saved = await showMediaRenameDialog(context,
                  filename: 'תמונה.original.JpG');
            },
            child: const Text('rename'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('rename'));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('media-rename-input'));
    expect(tester.widget<TextField>(input).controller!.text, 'תמונה.original');
    expect(
        find.byKey(const ValueKey('media-rename-extension')), findsOneWidget);
    expect(find.text('.JpG'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(input, 'שם חדש');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('media-rename-save')));
    await tester.pumpAndSettle();
    expect(saved, 'שם חדש.JpG');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('invalid basename cannot submit and cancel leaves name unchanged',
      (tester) async {
    String? saved = 'unchanged';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    saved = await showMediaRenameDialog(context,
                        filename: 'original.PNG');
                  },
                  child: const Text('rename'),
                ),
              )),
    ));
    await tester.tap(find.text('rename'));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('media-rename-input'));
    for (final invalid in ['', '../bad', 'a/b']) {
      await tester.enterText(input, invalid);
      await tester.pump();
      expect(
          tester
              .widget<FilledButton>(
                  find.byKey(const ValueKey('media-rename-save')))
              .onPressed,
          isNull);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(saved, 'unchanged');
    }
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
  });
}
