import 'package:flutter/material.dart';

class MainNavigationTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const MainNavigationTab({super.key, required this.label,
    required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true, selected: selected,
    child: InkWell(onTap: onTap, child: Container(
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(
        color: selected ? Colors.white : Colors.transparent, width: 2))),
      child: Text(label, textAlign: TextAlign.center, style: TextStyle(
        fontSize: 12, fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        color: selected ? Colors.white : Colors.white.withValues(alpha: 0.6))),
    )),
  );
}
