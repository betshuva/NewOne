import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'location_map_embed.dart';
import 'shared_content.dart';

/// Resolve only an explicit place query or selected pin, never a map viewport.
String? sharedPlaceMapQuery(SharedPlace place) {
  if (place.latitude != null && place.longitude != null) {
    if (!validSharedCoordinates(place.latitude!, place.longitude!)) return null;
    return '${place.latitude!.toStringAsFixed(6)},${place.longitude!.toStringAsFixed(6)}';
  }
  final uri = Uri.tryParse(place.url);
  final query =
      (uri?.queryParameters['query'] ?? uri?.queryParameters['q'])?.trim();
  return query == null || query.isEmpty || query.length > 500 ? null : query;
}

SharedPlace? previewableSharedPlace(String text) {
  final place = parseSharedPlace(text);
  return place != null && sharedPlaceMapQuery(place) != null ? place : null;
}

String locationMessageDisplayText(String text) {
  final place = previewableSharedPlace(text);
  if (place == null) return text;
  final remaining = text.replaceFirst(place.url, '').trim();
  // The title already appears on the card; retain any additional commentary.
  return remaining == place.title ? '' : remaining;
}

Uri sharedPlaceGoogleUrl(SharedPlace place) => Uri.https('www.google.com',
    '/maps/search/', {'api': '1', 'query': sharedPlaceMapQuery(place)!});

Uri sharedPlaceWazeUrl(SharedPlace place) => Uri.https('waze.com', '/ul', {
      if (place.latitude != null && place.longitude != null)
        'll': sharedPlaceMapQuery(place)!
      else
        'q': sharedPlaceMapQuery(place)!,
      'navigate': 'yes',
      'utm_source': 'betshuva',
    });

class LocationMessagePreview extends StatelessWidget {
  final SharedPlace place;
  final Future<bool> Function(Uri)? openLink;
  const LocationMessagePreview({super.key, required this.place, this.openLink});

  Future<void> _open(BuildContext context, Uri url) async {
    // Start navigation directly from the user's click, preserving web activation.
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final opened = await (openLink?.call(url) ??
          launchUrl(url, mode: LaunchMode.externalApplication));
      if (!opened) throw StateError('navigation unavailable');
    } catch (_) {
      messenger?.showSnackBar(
          const SnackBar(content: Text('לא ניתן לפתוח את המפה. נסה שוב.')));
    }
  }

  void _chooseNavigation(BuildContext context) {
    showDialog<void>(
        context: context,
        builder: (dialogContext) => Directionality(
            textDirection: TextDirection.rtl,
            child: SimpleDialog(title: const Text('פתיחת המיקום'), children: [
              for (final option in [
                (
                  'Google Maps',
                  Icons.map_outlined,
                  sharedPlaceGoogleUrl(place)
                ),
                ('Waze', Icons.navigation_outlined, sharedPlaceWazeUrl(place)),
              ])
                SimpleDialogOption(
                    onPressed: () {
                      _open(context, option.$3);
                      Navigator.pop(dialogContext);
                    },
                    child: Row(children: [
                      Icon(option.$2),
                      const SizedBox(width: 12),
                        Expanded(child: Text(option.$1)),
                    ])),
            ])));
  }

  @override
  Widget build(BuildContext context) {
    final query = sharedPlaceMapQuery(place)!;
    final title = place.title == 'מקום במפה' ? query : place.title;
    return SizedBox(
        width: 330,
        child: Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: Theme.of(context).dividerColor)),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
                key: const ValueKey('shared-location-map'),
                onTap: () => _chooseNavigation(context),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                      height: 190,
                      width: double.infinity,
                      child: locationMapEmbed(Uri.https(
                          'www.google.com',
                          '/maps',
                          {'q': query, 'output': 'embed', 'hl': 'he'}))),
                  Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      child: Row(textDirection: TextDirection.rtl, children: [
                        const Icon(Icons.location_on_outlined, size: 22),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(title,
                                textDirection: TextDirection.rtl,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 8),
                        const Icon(Icons.open_in_new, size: 18),
                      ])),
                ]))));
  }
}
