import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/link.dart';

const geocodingConsentVersion = 'geoapify-v1';

enum GeocodingPurpose { address, city, nearby }

Future<bool> requestGeocodingConsent(
    BuildContext context, GeocodingPurpose purpose) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('זיהוי כתובת לפי המיקום שלך'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text(
                    'באישור שלך, המיקום מהמכשיר יישלח דרך שרת בתשובה ל־Geoapify באירופה, כדי לזהות עיר וכתובת. שם, טלפון ואימייל אינם מצורפים לבקשה. הספק עשוי לשמור יומני בקשות לפי מדיניות הפרטיות שלו.'),
                const SizedBox(height: 12),
                Text(switch (purpose) {
                  GeocodingPurpose.address =>
                    'הקואורדינטות לא יישמרו בפרופיל. הכתובת תמולא בטופס, ותוכל/י לבדוק ולתקן אותה לפני שיתוף.',
                  GeocodingPurpose.city =>
                    'העיר והמדינה יישמרו בפרופיל והעיר תמולא במודעה. הקואורדינטות לא יישמרו בפעולה זו.',
                  GeocodingPurpose.nearby =>
                    'המיקום המדויק יישמר בשרת בתשובה לחיפוש בקרבתך. משתמשים אחרים יקבלו עיר ומרחק משוער בלבד. ניתן למחוק את המיקום בהגדרות.',
                }),
                const SizedBox(height: 12),
                const Text('הפעולה אינה חובה. אפשר להזין עיר וכתובת ידנית.'),
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse('https://www.geoapify.com/privacy-policy/'),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('מדיניות הפרטיות של Geoapify'),
                ),
              ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('ביטול')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('אישור ושליחת המיקום')),
            ],
          ),
        ),
      ) ??
      false;
}

// Kept next to automatically completed information and in the app's About
// section so source credits remain available for saved/reused addresses.
class GeocodingAttribution extends StatelessWidget {
  const GeocodingAttribution({super.key});

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('זיהוי כתובות:', style: TextStyle(fontSize: 11)),
          for (final credit in const [
            ('Powered by Geoapify', 'https://www.geoapify.com/'),
            (
              '© OpenStreetMap contributors',
              'https://www.openstreetmap.org/copyright'
            ),
            ('© OpenAddresses contributors', 'https://openaddresses.io/'),
          ])
            Link(
              uri: Uri.parse(credit.$2),
              target: LinkTarget.blank,
              builder: (context, followLink) => TextButton(
                style: TextButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 11),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: followLink,
                child: Text(credit.$1),
              ),
            ),
        ],
      );
}

String geocodingErrorMessage(String body) {
  try {
    final value = jsonDecode(body);
    if (value is Map && value['error'] is String) {
      final message = value['error'] as String;
      if (message.isNotEmpty && message.length <= 300) return message;
    }
  } catch (_) {}
  return 'לא ניתן לזהות את הכתובת כרגע. אפשר להזין אותה ידנית';
}
