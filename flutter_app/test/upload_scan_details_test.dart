import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:betshuva/upload_scan_details.dart';

void main() {
  test('metadata uses known sizes and duration without guessing missing values',
      () {
    expect(uploadScanMetadata('image', 'keyboard-image.gif', bytes: 506815),
        'GIF · 495 KB');
    expect(
        uploadScanMetadata('video', 'clip.mp4',
            bytes: 2097152, durationSeconds: 75),
        'וידאו · 2.0 MB · משך 1:15');
    expect(uploadScanMetadata('image', 'photo.jpg'), 'תמונה');
    expect(uploadMetadataNumber('506815'), 506815);
    for (final value in [null, '', 'NaN', -1, 0, double.infinity]) {
      expect(uploadMetadataNumber(value), isNull);
    }
  });
  testWidgets('long filenames and metadata stay in a compact two line card',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Directionality(
                textDirection: TextDirection.rtl,
                child: Align(
                    alignment: Alignment.topRight,
                    child: SizedBox(
                        width: 265,
                        child: UploadScanDetails(
                            name: 'very-long-file-name-that-does-not-fit.gif',
                            phase: 'סורק',
                            metadata: 'GIF · 495 KB · משך 1:15',
                            elapsedSeconds: 23,
                            icon: const Icon(Icons.auto_awesome, size: 20),
                            color: Colors.blue,
                            secondaryColor: Colors.grey)))))));
    expect(tester.takeException(), isNull);
    expect(find.text('חלפו 23 שנ׳'), findsOneWidget);
    expect(tester.getSize(find.byType(UploadScanDetails)).height, lessThan(50));
    expect(tester.widget<Text>(find.textContaining('very-long')).maxLines, 1);
  });
}
