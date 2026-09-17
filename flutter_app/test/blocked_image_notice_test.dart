import 'package:betshuva/blocked_image_notice.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _title = 'התמונה נחסמה בהגדרות הסינון האישיות';
const _reason =
    'תמונות גברים חסומות בהגדרות הנמען. הקובץ עבר את בדיקת הבטיחות וניתן להעביר אותו לשיחה אחרת.';
const _onlyYou = 'התמונה מוצגת רק לך ולא נשלחה';
const _recipient = 'מור אליהו';
const _fileName = 'camera-1789649113675-with-a-long-file-name.jpg';
const _expiry = 'התמונה תימחק בעוד 24 שעות';

final _preview = find.byKey(const ValueKey('blocked-image-preview'));
final _details = find.byKey(const ValueKey('blocked-image-details'));
final _marker = find.byKey(const ValueKey('blocked-image-marker'));
final _menu = find.byKey(const ValueKey('blocked-image-menu'));

Future<void> _pumpNotice(
  WidgetTester tester, {
  double width = 900,
  double height = 1200,
  TextDirection direction = TextDirection.rtl,
  double textScale = 1,
  VoidCallback? onImageTap,
  VoidCallback? onMoreActions,
  bool metadata = true,
  DateTime? previewExpiresAt,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: Directionality(textDirection: direction, child: child!),
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        child: BlockedImageNotice(
          image: GestureDetector(
            onTap: onImageTap,
            child: const AspectRatio(
              aspectRatio: 4 / 3,
              child: ColoredBox(color: Colors.blue),
            ),
          ),
          title: _title,
          reason: _reason,
          onlyYouText: _onlyYou,
          recipientName: metadata ? _recipient : null,
          fileName: metadata ? _fileName : null,
          expiryText: metadata ? _expiry : null,
          previewExpiresAt: previewExpiresAt,
          onMoreActions: onMoreActions,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void _expectRightAlignedPreview(WidgetTester tester, double viewportWidth) {
  expect(_preview, findsOneWidget);
  expect(_menu, findsOneWidget);
  final imageRect = tester.getRect(_preview);
  final menuRect = tester.getRect(_menu);
  expect(imageRect.right, closeTo(viewportWidth, 1));
  expect(menuRect.right, lessThanOrEqualTo(imageRect.left));
  expect(imageRect.top, closeTo(menuRect.top, 1));
  expect(menuRect.left, greaterThanOrEqualTo(0));
  expect(imageRect.width, greaterThan(0));
  expect(tester.takeException(), isNull);
}

Future<void> _openDetails(WidgetTester tester) async {
  await tester.tap(_menu);
  await tester.pumpAndSettle();
  expect(_details, findsNothing);
  await tester.tap(find.text('פרטי החסימה'));
  await tester.pumpAndSettle();
  expect(_details, findsOneWidget);
}

void _expectRightAlignedLabels() {
  final labels = find.descendant(of: _details, matching: find.byType(Text));
  expect(labels, findsWidgets);
  for (final element in labels.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(paragraph.textAlign, TextAlign.right);
    expect(paragraph.textDirection, TextDirection.rtl);
  }
}

void main() {
  for (final direction in TextDirection.values) {
    testWidgets(
        'preview stays right and explanations open only from menu in $direction',
        (tester) async {
      await _pumpNotice(tester, direction: direction);
      _expectRightAlignedPreview(tester, 900);
      expect(_details, findsNothing);
      for (final label in [_title, _reason, _onlyYou, _fileName, _expiry]) {
        expect(find.text(label), findsNothing);
      }

      await _openDetails(tester);
      for (final label in [_title, _reason, _onlyYou, _fileName, _expiry]) {
        expect(find.descendant(of: _details, matching: find.text(label)),
            findsOneWidget);
      }
      expect(find.text('נמען: $_recipient'), findsOneWidget);
      _expectRightAlignedLabels();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('סגירה'));
      await tester.pumpAndSettle();
      expect(_details, findsNothing);
      expect(find.text(_reason), findsNothing);
      _expectRightAlignedPreview(tester, 900);
    });
  }

  for (final direction in TextDirection.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          '320px menu and scrollable details fit $direction scale $scale',
          (tester) async {
        await _pumpNotice(tester,
            width: 320, height: 600, textScale: scale, direction: direction);
        _expectRightAlignedPreview(tester, 320);
        await _openDetails(tester);
        expect(tester.getRect(_details).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(_details).right, lessThanOrEqualTo(320));
        _expectRightAlignedLabels();
        final fileName = find.text(_fileName);
        await tester.ensureVisible(fileName);
        await tester.pumpAndSettle();
        expect(fileName.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('סגירה'));
        await tester.pumpAndSettle();
        expect(_details, findsNothing);
      });
    }
  }

  testWidgets('preview has exactly one block badge and no text or zoom icon',
      (tester) async {
    await _pumpNotice(tester);
    expect(_marker, findsOneWidget);
    expect(find.descendant(of: _preview, matching: _marker), findsOneWidget);
    expect(find.descendant(of: _preview, matching: find.byType(Text)),
        findsNothing);
    expect(find.descendant(of: _preview, matching: find.byType(Icon)),
        findsOneWidget);
    expect(find.byIcon(Icons.gpp_bad_outlined), findsOneWidget);
    expect(find.byIcon(Icons.zoom_in), findsNothing);
    expect(find.byIcon(Icons.zoom_out_map), findsNothing);
    expect(
        tester.getRect(_preview).contains(tester.getCenter(_marker)), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preview tap remains available including beneath blocked badge',
      (tester) async {
    var imageTaps = 0;
    await _pumpNotice(tester, onImageTap: () => imageTaps++);
    await tester.tapAt(tester.getCenter(_preview));
    await tester.tapAt(tester.getCenter(_marker));
    await tester.pump();
    expect(imageTaps, 2);
    expect(_details, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('optional metadata is omitted from details when unavailable',
      (tester) async {
    await _pumpNotice(tester, width: 320, metadata: false);
    await _openDetails(tester);
    expect(find.text(_title), findsOneWidget);
    expect(find.text(_reason), findsOneWidget);
    expect(find.text(_onlyYou), findsOneWidget);
    expect(find.textContaining(_recipient), findsNothing);
    expect(find.text(_fileName), findsNothing);
    expect(find.text(_expiry), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('menu preserves additional image actions when provided',
      (tester) async {
    var moreActions = 0;
    await _pumpNotice(tester, onMoreActions: () => moreActions++);
    await tester.tap(_menu);
    await tester.pumpAndSettle();
    expect(find.text('פרטי החסימה'), findsOneWidget);
    await tester.tap(find.text('אפשרויות נוספות'));
    await tester.pumpAndSettle();
    expect(moreActions, 1);
    expect(_details, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('menu omits unavailable additional actions', (tester) async {
    await _pumpNotice(tester);
    await tester.tap(_menu);
    await tester.pumpAndSettle();
    expect(find.text('פרטי החסימה'), findsOneWidget);
    expect(find.text('אפשרויות נוספות'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('open details updates countdown and shows expiration in place',
      (tester) async {
    await withClock(tester.binding.clock, () async {
      await _pumpNotice(tester,
          previewExpiresAt: clock.now().add(const Duration(seconds: 12)));
      await _openDetails(tester);
      final countdown = find.textContaining('מוצגת רק לך ותימחק בעוד');
      expect(countdown, findsOneWidget);
      expect(find.text(_expiry), findsNothing);
      final initialText = tester.widget<Text>(countdown).data;

      await tester.pump(const Duration(seconds: 2));
      expect(countdown, findsOneWidget);
      expect(tester.widget<Text>(countdown).data, isNot(initialText));

      await tester.pump(const Duration(seconds: 12));
      expect(_details, findsOneWidget);
      expect(countdown, findsNothing);
      expect(find.text('תצוגת התמונה הסתיימה והקובץ נמחק'), findsOneWidget);
      expect(find.text(_reason), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('סגירה'));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('closing details cancels countdown before preview expires',
      (tester) async {
    await withClock(tester.binding.clock, () async {
      await _pumpNotice(tester,
          previewExpiresAt: clock.now().add(const Duration(minutes: 10)));
      await _openDetails(tester);
      expect(find.textContaining('מוצגת רק לך ותימחק בעוד'), findsOneWidget);
      await tester.tap(find.text('סגירה'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(_details, findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
