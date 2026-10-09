import 'dart:convert';

import 'package:betshuva/shared_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shared links and map places', () {
    test('a browser share preserves its title and HTTPS URL', () {
      final link = parseSharedLink('כותרת העמוד\nhttps://example.com/a?x=1.');
      expect(link?.title, 'כותרת העמוד');
      expect(link?.url, 'https://example.com/a?x=1');
      expect(link?.toMessageText(), 'כותרת העמוד\nhttps://example.com/a?x=1');
    });
    test('URLs with credentials, non-HTTPS and unusual ports are rejected', () {
      expect(parseSharedLink('https://alice:secret@example.com/'), isNull);
      expect(parseSharedLink('http://example.com/'), isNull);
      expect(parseSharedLink('javascript:alert(1)'), isNull);
      expect(parseSharedLink('https://example.com:444/'), isNull);
      expect(parseSharedLink('https://example.com/${'x' * 2050}'), isNull);
    });
    test('explicit map pin coordinates are recognized without a lookup', () {
      final place = parseSharedPlace(
          'הכותל\nhttps://www.google.com/maps/search/?api=1&query=31.7767%2C35.2345');
      expect(place?.title, 'הכותל');
      expect(place?.latitude, 31.7767);
      expect(place?.longitude, 35.2345);
      expect(parseSharedPlace('https://maps.google.com/?q=31.7,35.2')?.latitude,
          31.7);
      expect(
          parseSharedPlace('https://www.openstreetmap.org/?mlat=31.7&mlon=35.2')
              ?.longitude,
          35.2);
    });
    test('a viewport and a short map link do not invent a place pin', () {
      final viewport = parseSharedPlace(
          'https://www.google.com/maps/place/Example/@31.7,35.2,15z');
      expect(viewport, isNotNull);
      expect(viewport?.latitude, isNull);
      expect(viewport?.longitude, isNull);
      final short = parseSharedPlace('https://maps.app.goo.gl/abc');
      expect(short?.url, 'https://maps.app.goo.gl/abc');
      expect(short?.latitude, isNull);
      expect(parseSharedPlace('https://maps.app.goo.gl.evil.test/abc'), isNull);
    });
    test('Android geo shares use explicit query pin or an address search', () {
      final pin = parseSharedPlace('geo:0,0?q=31.7,35.2(Place)');
      expect(pin?.latitude, 31.7);
      expect(pin?.longitude, 35.2);
      final search = parseSharedPlace('geo:0,0?q=Jerusalem');
      expect(search?.latitude, isNull);
      expect(Uri.parse(search!.url).queryParameters['query'], 'Jerusalem');
      expect(parseSharedPlace('geo:31.7,35.2')?.longitude, 35.2);
    });
    test('invalid and partial coordinates cannot produce a pin', () {
      expect(parseSharedPlace('geo:91,35'), isNull);
      expect(parseSharedPlace('https://www.google.com/maps?q=1,181'), isNull);
      expect(
          parseSharedPlace('https://www.openstreetmap.org/?mlat=31.7'), isNull);
      expect(() => SharedPlace.point(double.nan, 1), throwsFormatException);
      expect(
          () => SharedPlace.point(1, double.infinity), throwsFormatException);
      expect(SharedPlace.point(-90, -180).latitude, -90);
      expect(SharedPlace.point(90, 180).longitude, 180);
    });
  });

  group('vCard import', () {
    test(
        'vCard 3 keeps each choice and ignores PHOTO, URL and private extensions',
        () {
      final cards = parseSharedVCard('''BEGIN:VCARD
VERSION:3.0
FN:דנה כהן
TEL;TYPE=CELL:0501111111
TEL;TYPE=WORK:025555555
TEL:0501111111
EMAIL:one@example.com
EMAIL:two@example.com
ADR:;;רחוב ראשי 1;ירושלים;;91000;ישראל
PHOTO;VALUE=URI:https://private.example.com/photo
URL:https://private.example.com/profile
X-SECRET:hidden
END:VCARD''');
      expect(cards, hasLength(1));
      expect(cards.single.name, 'דנה כהן');
      expect(cards.single.phones, ['0501111111', '025555555']);
      expect(cards.single.emails, ['one@example.com', 'two@example.com']);
      expect(cards.single.addresses, ['רחוב ראשי 1, ירושלים, 91000, ישראל']);
      expect(cards.single.city, 'ירושלים');
    });
    test('vCard 4 URI fields and structured escaped name/address are decoded',
        () {
      final card = parseSharedVCard(r'''BEGIN:VCARD
VERSION:4.0
N:Cohen;Dana\;Sarah;;;
TEL;VALUE=uri:tel:+972501111111
EMAIL:mailto:dana@example.com
ADR:;;Room\; 2;Jerusalem;;;
END:VCARD''').single;
      expect(card.name, 'Dana;Sarah Cohen');
      expect(card.phones, ['+972501111111']);
      expect(card.emails, ['dana@example.com']);
      expect(card.addresses, ['Room; 2, Jerusalem']);
    });
    test(
        'vCard 2.1 quoted printable, soft line breaks and base64 text are supported',
        () {
      final encoded = base64.encode(utf8.encode('דנה'));
      final cards = parseSharedVCard('''BEGIN:VCARD\r
VERSION:2.1\r
FN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:=D7=93=D7=A0=\r
 =D7=94\r
END:VCARD\r
BEGIN:VCARD\r
VERSION:2.1\r
FN;ENCODING=BASE64:$encoded\r
END:VCARD''');
      expect(cards.map((card) => card.name), ['דנה', 'דנה']);
      final latin = parseSharedVCard(
          'BEGIN:VCARD\nFN;CHARSET=ISO-8859-1;ENCODING=QUOTED-PRINTABLE:Andr=E9\nEND:VCARD');
      expect(latin.single.name, 'André');
    });
    test('folded UTF-8 fields and escaped newlines stay local text', () {
      final card = parseSharedVCard(
              'BEGIN:VCARD\nFN:דנה\n כהן\nADR:;;Street\\nFloor 2;City;;;\nEND:VCARD')
          .single;
      expect(card.name, 'דנהכהן');
      expect(card.addresses.single, 'Street\nFloor 2, City');
    });
    test('size and card count are bounded including empty cards', () {
      expect(() => parseSharedVCard('a' * (maxSharedVCardBytes + 1)),
          throwsFormatException);
      expect(() => parseSharedVCard('א' * (maxSharedVCardBytes ~/ 2 + 1)),
          throwsFormatException);
      expect(() => parseSharedVCard('BEGIN:VCARD\nEND:VCARD\n' * 51),
          throwsFormatException);
      expect(parseSharedVCard('BEGIN:VCARD\nFN:Example\nEND:VCARD\n' * 50),
          hasLength(50));
    });
    test('malformed, truncated and excessively long fields fail cleanly', () {
      expect(() => parseSharedVCard('BEGIN:VCARD\nFN:Example'),
          throwsFormatException);
      expect(() => parseSharedVCard('BEGIN:VCARD\nBEGIN:VCARD\nEND:VCARD'),
          throwsFormatException);
      expect(() => parseSharedVCard('BEGIN:VCARD\nFN:${'x' * 4097}\nEND:VCARD'),
          throwsFormatException);
      expect(
          () => parseSharedVCard('BEGIN:VCARD\nFN;ENCODING=B:###\nEND:VCARD'),
          throwsFormatException);
      expect(parseSharedVCard('unrecognized file contents'), isEmpty);
    });
  });

  testWidgets(
      'contact selection starts with name only, with no hidden details in wire',
      (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await selectContactDetails(
                          context,
                          const SharedContactDetails(
                              name: 'דנה',
                              phones: ['0501111111'],
                              emails: ['dana@example.com'],
                              addresses: ['כתובת פרטית'],
                              city: 'ירושלים'));
                    },
                    child: const Text('פתיחה'))))));
    await tester.tap(find.text('פתיחה'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('המשך לשיתוף'));
    await tester.pumpAndSettle();
    final fields = jsonDecode(utf8.decode(
        base64Url.decode(result!.substring(sharedContactWirePrefix.length))));
    expect(fields, {'name': 'דנה'});
  });

  testWidgets(
      'a selected second phone replaces the first and group sharing is disclosed',
      (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      result = await selectContactDetails(
                          context,
                          const SharedContactDetails(
                              name: 'דנה',
                              phones: ['0501111111', '0502222222']),
                          isGroup: true);
                    },
                    child: const Text('פתיחה'))))));
    await tester.tap(find.text('פתיחה'));
    await tester.pumpAndSettle();
    expect(find.text('כל חברי הקבוצה יוכלו לראות ולשמור את הפרטים.'),
        findsOneWidget);
    await tester.tap(find.text('טלפון: 0501111111'));
    await tester.pump();
    await tester.tap(find.text('טלפון: 0502222222'));
    await tester.pump();
    await tester.tap(find.text('המשך לשיתוף'));
    await tester.pumpAndSettle();
    final fields = jsonDecode(utf8.decode(
        base64Url.decode(result!.substring(sharedContactWirePrefix.length))));
    expect(fields, {'name': 'דנה', 'phone': '0502222222'});
  });
}
