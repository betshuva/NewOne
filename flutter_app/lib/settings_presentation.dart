import 'package:flutter/material.dart';

/// Presentation only: the settings keep their existing actions and permissions.
class SettingsCategoryIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  const SettingsCategoryIcon(this.icon,
      {super.key, this.color = const Color(0xFF21BDD2)});

  @override
  Widget build(BuildContext context) => Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 23),
      );
}

class SettingsPanel extends StatelessWidget {
  final Widget child;
  const SettingsPanel({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: ListTileTheme(
            data: const ListTileThemeData(
              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              minVerticalPadding: 12,
              horizontalTitleGap: 14,
              titleTextStyle: TextStyle(
                  fontFamily: 'NotoSansHebrew',
                  fontSize: 16,
                  color: Color(0xFF263747),
                  fontWeight: FontWeight.w500),
              subtitleTextStyle: TextStyle(
                  fontFamily: 'NotoSansHebrew',
                  fontSize: 12,
                  color: Color(0xFF6A7B8A)),
            ),
            child: child,
          ),
        ),
      );
}

class SettingsSectionHeading extends StatelessWidget {
  final String title;
  const SettingsSectionHeading({super.key, required this.title});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
        child: Text(title,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6A7B8A))),
      );
}
