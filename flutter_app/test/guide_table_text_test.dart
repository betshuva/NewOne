import 'package:betshuva/guide_table_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _style = TextStyle(fontSize: 14, height: 1.45, color: Colors.black);

Widget _app(String text, {double width = 420}) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: GuideTableText(text, style: _style),
          ),
        ),
      ),
    );

void main() {
  testWidgets('ordinary guide text keeps its content, style and RTL direction',
      (tester) async {
    const message = 'שלום!\n\nזה טקסט **רגיל** עם | סימן.\n';
    await tester.pumpWidget(_app(message));

    final text = tester.widget<Text>(find.text(message));
    expect(text.style, _style);
    expect(text.textDirection, TextDirection.rtl);
    expect(text.textAlign, TextAlign.right);
    expect(find.byType(Table), findsNothing);
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('mixed guide answer shows RTL table with LTR phone numbers',
      (tester) async {
    await tester.pumpWidget(_app('חברי קבוצת המטיילים:\n\n'
        '| שם | טלפון |\n'
        '| --- | --- |\n'
        '| דנה | +972-50-1234567 |\n'
        '| יוסף | לא זמין |\n\n'
        'סה״כ 2 חברים.'));

    expect(find.text('חברי קבוצת המטיילים:'), findsOneWidget);
    expect(find.text('סה״כ 2 חברים.'), findsOneWidget);
    expect(tester.widget<Table>(find.byType(Table)).children, hasLength(3));
    expect(tester.getCenter(find.text('שם')).dx,
        greaterThan(tester.getCenter(find.text('טלפון')).dx));
    expect(
        tester.widget<Text>(find.text('דנה')).textDirection, TextDirection.rtl);
    expect(tester.widget<Text>(find.text('+972-50-1234567')).textDirection,
        TextDirection.ltr);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tables scroll within a narrow message without layout overflow',
      (tester) async {
    await tester.pumpWidget(_app(
        '| שם | טלפון | תפקיד |\n'
        '| --- | --- | --- |\n'
        '| שם ארוך מאוד של חבר בקבוצה | 0501234567 | מנהל |',
        width: 180));

    final scroll = find.byWidgetPredicate((widget) =>
        widget is SingleChildScrollView &&
        widget.scrollDirection == Axis.horizontal);
    expect(tester.getSize(scroll).width, 180);
    final scrollState = tester.state<ScrollableState>(
        find.descendant(of: scroll, matching: find.byType(Scrollable)));
    expect(scrollState.position.maxScrollExtent, greaterThan(0));
    await tester.drag(scroll, const Offset(160, 0));
    await tester.pumpAndSettle();
    expect(scrollState.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cell content stays plain and decoded pipes remain copyable',
      (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(_app('| שם | טלפון |\n'
        '| --- | --- |\n'
        '| דנה &#124; לוי | +972501234567 |\n'
        '| [קישור](javascript:alert(1)) | <script>alert(1)</script> |'));

    expect(find.text('דנה | לוי'), findsOneWidget);
    final link = tester.widget<Text>(find.text('[קישור](javascript:alert(1))'));
    expect(link.textSpan, isNull);
    expect(find.text('<script>alert(1)</script>'), findsOneWidget);

    await tester.pumpAndSettle();
    final selection =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    selection.selectAll(SelectionChangedCause.keyboard);
    await tester.pump();
    selection.contextMenuButtonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await tester.pump();
    expect(copied, contains('דנה | לוי'));
    expect(copied, contains('+972501234567'));
    expect(copied, contains('[קישור](javascript:alert(1))'));
    expect(copied, isNot(contains('&#124;')));
  });

  testWidgets('malformed tables and unmatched rows retain their text',
      (tester) async {
    const malformed = '| שם | טלפון |\n| --- |\n| דנה | 0501234567 |';
    await tester.pumpWidget(_app(malformed));
    expect(find.text(malformed), findsOneWidget);
    expect(find.byType(Table), findsNothing);

    await tester.pumpWidget(_app('| שם | טלפון |\n| :--- | ---: |\n'
        '| דנה | 0501234567 |\n'
        '| שורה | עם | שלושה תאים |\n'
        'סיום'));
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('| שורה | עם | שלושה תאים |\nסיום'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
