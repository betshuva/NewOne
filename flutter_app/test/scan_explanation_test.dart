import 'package:betshuva/scan_explanation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('saved classification, uncertainty and block reason remain distinct', () {
    final details=scanExplanation({'status':'rejected_scan','scanReason':'חסום בהגדרות הנמען',
      'classification': {'detectedCategories':['men','children'],'uncertain':true}});
    expect(details,contains('גברים, ילדים')); expect(details,contains('הסיווג אינו ודאי'));
    expect(details,contains('חסום בהגדרות הנמען'));expect(details,isNot(contains('אושר למסירה')));
    expect(scanExplanation({'status':'pending_scan'}),contains('טרם אושרה'));
    expect(scanExplanation({}),isNot(contains('אושר למסירה')));
  });
  testWidgets('scan details open and close in a small viewport', (tester) async {
    await tester.pumpWidget(MaterialApp(home:Builder(builder:(context)=>Scaffold(
      body:TextButton(onPressed:()=>showScanExplanation(context, {'status':'read',
      'classification':{'category':'women'}}),child:const Text('scan'))))));
    await tester.tap(find.text('scan'));await tester.pumpAndSettle();
    expect(find.text('פרטי הסריקה'),findsOneWidget);
    expect(find.textContaining('נשים'),findsOneWidget);
    await tester.tap(find.text('סגור'));await tester.pumpAndSettle();
    expect(find.byType(AlertDialog),findsNothing);
  });
}
