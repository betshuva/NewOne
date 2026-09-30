import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/attachment_picker.dart';
import 'own_media_filter_test.dart' as fixtures;

void main() {
  FilePicker.platform = AttachmentPicker([]);
  for (final group in [false, true]) {
    for (final images in [false, true]) {
      for (final count in [100, 101]) {
        testWidgets(
            '$count selected files respect the batch limit group=$group images=$images',
            (tester) async {
          fixtures.size(tester);
          SharedPreferences.setMockInitialValues({});
          final previous = FilePicker.platform;
          FilePicker.platform = AttachmentPicker(List.generate(
              count,
              (i) => MemoryPickedFile(
                  'file-$i.${images ? 'png' : 'pdf'}', fixtures.png)));
          addTearDown(() => FilePicker.platform = previous);
          final gate = Completer<void>();
          var uploads = 0;
          var active = 0;
          var peak = 0;
          var sent = 0;
          final names = <String>[];
          await http.runWithClient(() async {
            await tester.pumpWidget(fixtures.chat(group));
            await tester.pumpAndSettle();
            await tester.tap(find.byIcon(Icons.attach_file));
            await tester.pumpAndSettle();
            await tester.tap(find.text('העלאת קבצים'));
            for (var i = 0; i < 20; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(uploads, 0);
            if (count > 100) {
              expect(
                  find.text('נבחרו 101 קבצים. ניתן להעלות עד 100 '
                      'קבצים בכל פעם. הפעולה בוטלה.'),
                  findsOneWidget);
              expect(find.text('כן, העלה'), findsNothing);
              expect(sent, 0);
              expect(names, isEmpty);
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pumpAndSettle();
              return;
            }
            expect(find.text('אתה עומד להעלות 100 קבצים. האם אתה בטוח?'),
                findsOneWidget);
            await tester.tap(find.text('כן, העלה'));
            for (var i = 0; i < 20; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(uploads, images ? 2 : 1);
            if (!images) expect(find.text('מעלה 100 קבצים'), findsOneWidget);
            expect(find.text('סוף העלאת 100 קבצים'), findsNothing);
            gate.complete();
            for (var i = 0; i < 500 && sent < 100; i++) {
              await tester.pump(const Duration(milliseconds: 50));
            }
            for (var i = 0; i < 10; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(uploads, 100);
            expect(sent, 100);
            expect(peak, images ? 2 : 1);
            expect(
                names, isNot(contains('file-100.${images ? 'png' : 'pdf'}')));
            expect(find.text('סוף העלאת 100 קבצים'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          },
              () => MockClient((request) async {
                    if (fixtures.isHistory(request, group))
                      return fixtures.json([]);
                    if (request.url.path.endsWith('/upload')) {
                      final number = ++uploads;
                      active++;
                      if (active > peak) peak = active;
                      names.add(RegExp('filename="([^"]+)"')
                          .firstMatch(latin1.decode(request.bodyBytes))!
                          .group(1)!);
                      await gate.future;
                      active--;
                      return fixtures.json(
                          {'status': 'approved', 'url': '/uploads/$number'});
                    }
                    if (request.method == 'POST' &&
                        request.url.path.endsWith('/messages')) {
                      sent++;
                      return fixtures
                          .json({'id': 'message-$sent', 'status': 'sent'});
                    }
                    return fixtures.defaultResponse(request);
                  }));
        });
      }
    }
  }
}
