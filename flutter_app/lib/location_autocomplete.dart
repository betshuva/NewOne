import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const israeliLocations = [
  'כל הארץ',
  'אזור המרכז',
  'אזור ירושלים',
  'אזור הצפון',
  'אזור הדרום',
  'אזור השרון',
  'ירושלים',
  'תל אביב-יפו',
  'חיפה',
  'ראשון לציון',
  'פתח תקווה',
  'אשדוד',
  'נתניה',
  'באר שבע',
  'בני ברק',
  'חולון',
  'רמת גן',
  'אשקלון',
  'רחובות',
  'בית שמש',
  'כפר סבא',
  'הרצליה',
  'חדרה',
  'מודיעין',
  'לוד',
  'רמלה',
  'רעננה',
  'גבעתיים',
  'הוד השרון',
  'קריית גת',
  'נהריה',
  'עכו',
  'טבריה',
  'צפת',
  'עפולה',
  'נצרת',
  'כרמיאל',
  'קריית שמונה',
  'אילת',
  'יבנה',
  'נס ציונה',
  'אריאל',
  'מעלה אדומים',
  'קריית ארבע',
];

/// City selection shared by profile, listings, and calendar settings.
class LocationAutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final String api;
  final String label;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSelected;
  final List<String> extraCities;
  final bool citiesOnly;

  const LocationAutocompleteField({
    super.key,
    required this.controller,
    required this.api,
    this.label = 'עיר או אזור',
    this.hint,
    this.onChanged,
    this.onSelected,
    this.extraCities = const [],
    this.citiesOnly = false,
  });

  @override
  State<LocationAutocompleteField> createState() =>
      _LocationAutocompleteFieldState();
}

class _LocationAutocompleteFieldState extends State<LocationAutocompleteField> {
  final _focusNode = FocusNode();
  int _searchGeneration = 0;

  bool _isCity(String value) =>
      value != 'כל הארץ' && !value.startsWith('אזור ');

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s\-־]+'), '');

  Future<Iterable<String>> _options(TextEditingValue value) async {
    final generation = ++_searchGeneration;
    final query = value.text.trim();
    final normalized = _normalize(query);
    final fallback = {...widget.extraCities, ...israeliLocations};
    final remote = <String>[];

    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted || generation != _searchGeneration) return const [];
    try {
      final uri =
          Uri.parse('${widget.api.replaceFirst(RegExp(r'/$'), '')}/localities')
              .replace(queryParameters: {if (query.isNotEmpty) 'q': query});
      final response = await http.get(uri).timeout(const Duration(seconds: 5));
      if (!mounted || generation != _searchGeneration) return const [];
      if (response.statusCode == 200) {
        for (final row in jsonDecode(response.body) as List) {
          if (row is Map && row['city'] is String) {
            final city = (row['city'] as String).trim();
            if (city.isNotEmpty) remote.add(city);
          }
        }
      }
    } catch (_) {
      // Keep familiar cities available when the locality service is unavailable.
    }
    if (!mounted || generation != _searchGeneration) return const [];
    // The locality service also matches canonical spelling variants. Keep its
    // results intact; the local fallback list still needs query filtering.
    return {
      ...remote,
      ...fallback.where((city) =>
          normalized.isEmpty || _normalize(city).contains(normalized)),
    }.where((city) => !widget.citiesOnly || _isCity(city)).take(30);
  }

  @override
  void dispose() {
    _searchGeneration++;
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawAutocomplete<String>(
        textEditingController: widget.controller,
        focusNode: _focusNode,
        displayStringForOption: (option) => option,
        optionsBuilder: _options,
        onSelected: widget.onSelected,
        fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
            TextField(
          controller: controller,
          focusNode: focusNode,
          textDirection: TextDirection.rtl,
          onChanged: widget.onChanged,
          onSubmitted: (_) => onSubmitted(),
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            prefixIcon: const Icon(Icons.location_city_outlined),
            border: const OutlineInputBorder(),
          ),
        ),
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topRight,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260, maxWidth: 420),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (_, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      _isCity(option)
                          ? Icons.location_on_outlined
                          : Icons.map_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    title: Text(option, textDirection: TextDirection.rtl),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        ),
      );
}
