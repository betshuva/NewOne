import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'welcome_entry_policy.dart';

const _primary = Color(0xFF1B6CA8);
const _text = Color(0xFF0D2137);

/// An optional introduction; examples never change account or filter settings.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({
    super.key,
    required this.onContinue,
    this.onOpenUrl,
  });

  final ValueChanged<bool> onContinue;
  final ValueChanged<String>? onOpenUrl;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  var _feature = 0;
  var _leaving = false;

  Future<void> _continue({bool registration = false}) async {
    if (_leaving) return;
    setState(() => _leaving = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(welcomeSeenVersionKey, welcomeIntroductionVersion);
    } catch (_) {
      // A restricted browser storage must not turn an optional tour into a gate.
    }
    if (mounted) widget.onContinue(registration);
  }

  Widget _preview() {
    final feature = _features[_feature];
    return Container(
      key: const ValueKey('welcome-preview'),
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F7FD),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFCDE2F2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(feature.icon, size: 34, color: _primary),
          const SizedBox(height: 12),
          Text(feature.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: _text, fontSize: 19, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(feature.description,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _text, fontSize: 14, height: 1.6)),
          if (_feature == 2) ...[
            const SizedBox(height: 14),
            LayoutBuilder(builder: (context, constraints) {
              final columns = constraints.maxWidth >= 420 ? 3 : 2;
              final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (icon, label) in _marketplaceCategories)
                    Container(
                      width: width,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFDCE7EE)),
                      ),
                      child: Column(children: [
                        Icon(icon, size: 22, color: _primary),
                        const SizedBox(height: 6),
                        Text(label,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: _text,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ]),
                    ),
                ],
              );
            }),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(feature.example,
                textAlign: TextAlign.right,
                style: const TextStyle(color: _primary, height: 1.6)),
          ),
          const SizedBox(height: 6),
          const Text('דוגמה להמחשה',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF526B7C), fontSize: 11)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          key: const ValueKey('welcome-screen'),
          backgroundColor: const Color(0xFFF2F7FB),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 580),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.asset('icon_source.png',
                                width: 46, height: 46),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text('בתשובה',
                                style: TextStyle(
                                    color: _primary,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800)),
                          ),
                          TextButton(
                            key: const ValueKey('welcome-skip'),
                            onPressed: _leaving ? null : () => _continue(),
                            child: const Text('דלג'),
                          ),
                        ]),
                        const SizedBox(height: 22),
                        Semantics(
                          header: true,
                          child: const Text(
                              'נעים להכיר.\nהקהילה שלכם, במקום אחד.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: _text,
                                  fontSize: 25,
                                  fontWeight: FontWeight.w800,
                                  height: 1.3)),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                            'בחרו נושא כדי להציץ במה שאפשר לעשות בבתשובה.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: _text, height: 1.5)),
                        const SizedBox(height: 18),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            for (var i = 0; i < _features.length; i++)
                              ChoiceChip(
                                key: ValueKey('welcome-feature-$i'),
                                label: Text(_features[i].label),
                                selected: _feature == i,
                                onSelected: _leaving
                                    ? null
                                    : (_) => setState(() => _feature = i),
                              ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _preview(),
                        const SizedBox(height: 22),
                        FilledButton.icon(
                          key: const ValueKey('welcome-finish'),
                          onPressed: _leaving ? null : () => _continue(),
                          icon: const Icon(Icons.arrow_back, size: 19),
                          label:
                              Text(_leaving ? 'ממשיכים…' : 'ממשיכים עם Google'),
                          style: FilledButton.styleFrom(
                              backgroundColor: _primary,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14)),
                        ),
                        TextButton(
                          key: const ValueKey('welcome-register'),
                          onPressed: _leaving
                              ? null
                              : () => _continue(registration: true),
                          child: const Text('עוד אין לי חשבון — הרשמה חדשה'),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                            'לבני 18 ומעלה. בטא פתוחה ללא תשלום כרגע.\n'
                            'הגדרות הסינון ואישור תנאי השימוש נבחרים בהרשמה.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Color(0xFF526B7C),
                                fontSize: 12,
                                height: 1.5)),
                        if (widget.onOpenUrl != null)
                          Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              TextButton(
                                onPressed: () => widget.onOpenUrl!(
                                    'https://betshuva.com/betshuva-app/terms'),
                                child: const Text('תנאי שימוש'),
                              ),
                              TextButton(
                                onPressed: () => widget.onOpenUrl!(
                                    'https://betshuva.com/betshuva-app/privacy'),
                                child: const Text('פרטיות'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class _WelcomeFeature {
  const _WelcomeFeature(
      this.label, this.icon, this.title, this.description, this.example);
  final String label;
  final IconData icon;
  final String title;
  final String description;
  final String example;
}

const _marketplaceCategories = [
  (Icons.directions_car_outlined, 'רכבים'),
  (Icons.home_outlined, 'נדל״ן'),
  (Icons.kitchen_outlined, 'מוצרי חשמל'),
  (Icons.chair_outlined, 'רהיטים'),
  (Icons.devices_outlined, 'אלקטרוניקה'),
  (Icons.menu_book_outlined, 'ספרים'),
];

const _features = [
  _WelcomeFeature(
      'שיחות',
      Icons.forum_outlined,
      'נשארים קרובים לקהילה',
      'שיחות פרטיות וקבוצות, הודעות קוליות, תמונות וקבצים — במקום אחד.',
      'שלום לקהילה 👋\nבשמחה! טוב להיות בקשר.'),
  _WelcomeFeature(
      'סינון',
      Icons.tune,
      'בוחרים את התוכן שרוצים לראות',
      'הגדירו את סוגי התוכן המתאימים לכם ולכללי הקבוצה. '
          'מערכת הסינון מסייעת לשמור על הסביבה שבחרתם.',
      'הגדרות אישיות  •  סינון בקבוצות\nהבחירות שלכם נשמרות בהגדרות החשבון.'),
  _WelcomeFeature(
      'מודעות',
      Icons.storefront_outlined,
      'קונים, מוכרים ומוסרים בקהילה',
      'רכבים, נדל״ן, מוצרי חשמל, רהיטים, אלקטרוניקה וספרים — ועוד קטגוריות. '
          'חפשו לפי קטגוריה, אזור, מחיר ופרטי המודעה.',
      'מחפשים לקנות  •  מפרסמים למכירה\n'
          'מוסרים ללא תשלום  •  מוצאים קרוב לבית'),
];
