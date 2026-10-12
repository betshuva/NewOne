import 'package:betshuva/education_form_message_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _message({String type = 'survey'}) => {
      'educationFormId': 'form-1',
      'educationFormType': type,
      'educationFormTitle': 'בחירת יעד לטיול הראשון',
      'educationFormStatus': 'open',
      'educationIsRecipient': true,
      'createdAt': '2026-10-12T15:30:00',
      'educationFormCreatedAt': '2026-09-01T08:00:00',
      'text': '📋 סקר חדש: כותרת ישנה',
    };

Future<void> _showCard(
  WidgetTester tester,
  Map<String, dynamic> message, {
  double width = 380,
  double textScale = 1,
  bool canManage = false,
  VoidCallback? onOpen,
}) =>
    tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: width,
                child: EducationFormMessageCard(
                  message: message,
                  canManage: canManage,
                  onOpen: onOpen ?? () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  test('identifies linked forms and legacy announcements without matching chat',
      () {
    expect(
        isEducationFormAnnouncement({'educationFormId': 'saved-form'}), isTrue);
    expect(isEducationFormAnnouncement({'text': '  📋 סקר חדש: טיול'}), isTrue);
    expect(isEducationFormAnnouncement({'text': 'סקר מעניין מאוד'}), isFalse);
    expect(isEducationFormAnnouncement({'educationFormId': ' ', 'text': ''}),
        isFalse);
  });

  test('structured metadata preserves the entered title including punctuation',
      () {
    final message = {
      ..._message(type: 'signature'),
      'educationFormTitle': '  סקר ראשון: לאן יוצאים? 🚌  ',
    };
    expect(educationFormMessageType(message), 'signature');
    expect(educationFormMessageTitle(message), 'סקר ראשון: לאן יוצאים? 🚌');
  });

  for (final (text, type, title) in [
    ('📋 סקר חדש: סקר ראשון לטיול', 'survey', 'סקר ראשון לטיול'),
    ('📋 סקר: בוקר: או ערב?\nפרטים נוספים', 'survey', 'בוקר: או ערב?'),
    ('📋 אישור חדש: אישור יציאה', 'approval', 'אישור יציאה'),
    ('📋 מסמך חדש לחתימה:בקשת חתימה', 'signature', 'בקשת חתימה'),
    ('📋 מסמך לחתימה: טופס רפואי', 'signature', 'טופס רפואי'),
  ]) {
    test('legacy $type extracts the actual title from $text', () {
      final message = {'text': text};
      expect(educationFormMessageType(message), type);
      expect(educationFormMessageTitle(message), title);
    });
  }

  test('missing legacy title falls back to the type without a generic prefix',
      () {
    expect(educationFormMessageTitle({'text': '📋 סקר חדש:'}), 'סקר');
    expect(educationFormMessageTitle({'text': '📋 אישור חדש'}), 'אישור');
  });

  test('the displayed date belongs to this send, including a repeated send',
      () {
    final first = _message();
    final repeated = {...first, 'createdAt': '2026-10-14T10:45:00'};
    expect(educationFormMessageSentDate(first), '12/10/2026');
    expect(educationFormMessageSentDate(repeated), '14/10/2026');
    expect(first['educationFormId'], repeated['educationFormId']);
    expect(educationFormMessageSentAt(repeated)?.hour, 10);
    final utc = {...first, 'createdAt': '2026-10-12T23:30:00Z'};
    expect(educationFormMessageSentAt(utc),
        DateTime.parse('2026-10-12T23:30:00Z').toLocal());
    expect(educationFormMessageSentAt({'createdAt': 'invalid'}), isNull);
    expect(educationFormMessageSentDate({}), '');
  });

  for (final (type, label, icon, action) in [
    ('survey', 'סקר', Icons.poll_outlined, 'פתח סקר'),
    ('approval', 'אישור', Icons.fact_check_outlined, 'פתח אישור'),
    ('signature', 'מסמך לחתימה', Icons.draw_outlined, 'פתח מסמך'),
  ]) {
    testWidgets('$type shows its title, icon, sent date and opening action',
        (tester) async {
      await _showCard(tester, _message(type: type));
      expect(find.text(label), findsOneWidget);
      expect(find.byIcon(icon), findsOneWidget);
      expect(find.text('בחירת יעד לטיול הראשון'), findsOneWidget);
      expect(find.text('נשלח ב־12/10/2026'), findsOneWidget);
      expect(find.text('15:30'), findsOneWidget);
      expect(find.text(action), findsOneWidget);
      expect(find.text('ממתין לתשובתך'), findsOneWidget);
      expect(find.textContaining('כותרת ישנה'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (response, status, icon) in [
    ('completed', 'הושלם', Icons.check_rounded),
    ('approved', 'הושלם', Icons.check_rounded),
    ('declined', 'לא אושר', Icons.close_rounded),
  ]) {
    testWidgets('a manager who is a recipient sees their $response response',
        (tester) async {
      await _showCard(
          tester,
          {
            ..._message(),
            'educationResponseStatus': response,
          },
          canManage: true);
      expect(find.text(status), findsOneWidget);
      expect(find.byIcon(icon), findsOneWidget);
      expect(find.text('לניהול'), findsNothing);
    });
  }

  testWidgets(
      'an unanswered manager recipient can still see the required reply',
      (tester) async {
    await _showCard(tester, _message(), canManage: true);
    expect(find.text('ממתין לתשובתך'), findsOneWidget);
    await _showCard(
        tester,
        {
          ..._message(),
          'educationIsRecipient': false,
        },
        canManage: true);
    expect(find.text('לניהול'), findsOneWidget);
    expect(find.text('ממתין לתשובתך'), findsNothing);
  });

  testWidgets('closed state takes priority over both response and management',
      (tester) async {
    await _showCard(
        tester,
        {
          ..._message(),
          'educationResponseStatus': 'completed',
          'educationFormStatus': 'closed',
        },
        canManage: true);
    expect(find.text('סגור'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    expect(find.text('הושלם'), findsNothing);
  });

  for (final type in ['survey', 'approval', 'signature']) {
    testWidgets(
        '$type fits a narrow bubble with enlarged text and a long title',
        (tester) async {
      final title = 'סקר ראשון לבחירת יעד לטיול של הקבוצה בשבוע הבא '
          'בשיתוף כל המשתתפים: בואו לבחור יחד!';
      await _showCard(
          tester,
          {
            ..._message(type: type),
            'educationFormTitle': title,
          },
          width: 240,
          textScale: 1.3);
      expect(tester.takeException(), isNull);
      expect(find.text(title), findsOneWidget);
      final renderedTitle = tester
          .widget<Text>(find.byKey(const ValueKey('education-message-title')));
      expect(renderedTitle.maxLines, isNull);
      expect(renderedTitle.overflow, isNull);
      expect(tester.getSize(find.byType(EducationFormMessageCard)).width,
          lessThanOrEqualTo(240));
      expect(find.text('ממתין לתשובתך'), findsOneWidget);
    });
  }

  testWidgets('missing timestamps do not invent a date or throw',
      (tester) async {
    await _showCard(tester, {'text': '📋 סקר חדש: סקר ישן'});
    expect(find.text('סקר ישן'), findsOneWidget);
    expect(find.byIcon(Icons.calendar_today_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the entire card and its action open the same form once per tap',
      (tester) async {
    var opened = 0;
    await _showCard(tester, _message(), onOpen: () => opened++);
    await tester.tap(find.text('בחירת יעד לטיול הראשון'));
    expect(opened, 1);
    await tester.tap(find.text('פתח סקר'));
    expect(opened, 2);
  });

  testWidgets('an unselected member sees an informational card without opening',
      (tester) async {
    var opened = 0;
    await _showCard(
        tester,
        {
          ..._message(),
          'educationIsRecipient': false,
        },
        onOpen: () => opened++,
        width: 240,
        textScale: 1.3);
    expect(find.text('לידיעה'), findsOneWidget);
    expect(find.text('לנמענים שנבחרו'), findsOneWidget);
    expect(find.text('ממתין לתשובתך'), findsNothing);
    expect(find.text('פתח סקר'), findsNothing);
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    expect(tester.takeException(), isNull);
    final access = tester.widget<Semantics>(
        find.byKey(const ValueKey('education-message-access')));
    expect(access.properties.enabled, isFalse);
    expect(access.properties.button, isFalse);
    expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
    await tester.tap(find.text('בחירת יעד לטיול הראשון'));
    await tester.tap(find.text('לנמענים שנבחרו'));
    expect(opened, 0);
  });

  testWidgets('a manager outside the selected recipients can open management',
      (tester) async {
    var opened = 0;
    await _showCard(
        tester,
        {
          ..._message(),
          'educationIsRecipient': false,
        },
        canManage: true,
        onOpen: () => opened++);
    expect(find.text('לניהול'), findsOneWidget);
    expect(find.text('פתח סקר'), findsOneWidget);
    expect(find.text('לידיעה'), findsNothing);
    await tester.tap(find.text('פתח סקר'));
    expect(opened, 1);
  });

  testWidgets('legacy messages without a recipient flag retain open access',
      (tester) async {
    var opened = 0;
    await _showCard(
        tester,
        {
          'text': '📋 סקר חדש: סקר ישן',
          'createdAt': '2026-10-12T15:30:00',
        },
        onOpen: () => opened++);
    expect(find.text('ממתין לתשובתך'), findsOneWidget);
    expect(find.text('לידיעה'), findsNothing);
    await tester.tap(find.text('פתח סקר'));
    expect(opened, 1);
  });
}
