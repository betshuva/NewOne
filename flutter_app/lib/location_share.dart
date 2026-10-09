import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import 'location_autocomplete.dart';
import 'location_map_cache.dart';
import 'shared_content.dart';

const _mapTileHost = 'tile.openstreetmap.org';
const _mercatorLatitudeLimit = 85.05112878;

class LocationMapPoint {
  final double latitude;
  final double longitude;
  const LocationMapPoint(this.latitude, this.longitude);
}

/// Pixel coordinates in the tile world's Web Mercator projection.
Offset locationMapProject(LocationMapPoint point, int zoom) {
  final world = 256.0 * math.pow(2, zoom);
  final lat =
      point.latitude.clamp(-_mercatorLatitudeLimit, _mercatorLatitudeLimit);
  final radians = lat * math.pi / 180;
  return Offset(
      (point.longitude + 180) / 360 * world,
      (1 - math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) /
          2 *
          world);
}

LocationMapPoint locationMapUnproject(Offset pixels, int zoom) {
  final world = 256.0 * math.pow(2, zoom);
  final x = ((pixels.dx % world) + world) % world;
  final y = pixels.dy.clamp(0, world);
  final n = math.pi * (1 - 2 * y / world);
  final latitude = math.atan((math.exp(n) - math.exp(-n)) / 2) * 180 / math.pi;
  return LocationMapPoint(latitude, x / world * 360 - 180);
}

/// This one-time location flow never calls /location or stores profile GPS.
/// Returns existing plain-text message wire format with an HTTPS map link.
Future<String?> showLocationShareDialog(BuildContext context,
        {required String api, bool isGroup = false}) =>
    showDialog<String>(
        context: context,
        builder: (_) => _LocationShareDialog(api: api, isGroup: isGroup));

class _LocationShareDialog extends StatefulWidget {
  final String api;
  final bool isGroup;
  const _LocationShareDialog({required this.api, required this.isGroup});
  @override
  State<_LocationShareDialog> createState() => _LocationShareDialogState();
}

class _LocationShareDialogState extends State<_LocationShareDialog> {
  final _name = TextEditingController();
  final _latitude = TextEditingController();
  final _longitude = TextEditingController();
  LocationMapPoint? _point;
  bool _mapAllowed = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _latitude.dispose();
    _longitude.dispose();
    super.dispose();
  }

  void _selectPoint(LocationMapPoint point) {
    setState(() {
      _point = point;
      _latitude.text = point.latitude.toStringAsFixed(6);
      _longitude.text = point.longitude.toStringAsFixed(6);
      _error = null;
    });
  }

  void _coordinatesChanged() {
    final lat = double.tryParse(_latitude.text.trim());
    final lon = double.tryParse(_longitude.text.trim());
    setState(() {
      _point = lat != null && lon != null && validSharedCoordinates(lat, lon)
          ? LocationMapPoint(lat, lon)
          : null;
      _error = null;
    });
  }

  Future<void> _currentLocation() async {
    final agreed = await showDialog<bool>(
        context: context,
        builder: (context) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('שיתוף המיקום הנוכחי'),
              content: const Text(
                  'המיקום ייקרא פעם אחת לצורך ההודעה. הוא לא יישמר בפרופיל '
                  'ולא יבוצע מעקב ברקע. הנמען יקבל קישור לנקודה המדויקת לאחר שתאשרו את השיתוף.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('ביטול')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('קבלת מיקום'))
              ],
            )));
    if (agreed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const _LocationShareFailure(
            'שירותי המיקום כבויים. אפשר לבחור נקודה במפה או להזין מיקום ידנית.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw const _LocationShareFailure(
            'לא ניתנה הרשאה למיקום. אפשר לבחור נקודה במפה או להזין מיקום ידנית.');
      }
      final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 15)));
      if (mounted) {
        _selectPoint(LocationMapPoint(position.latitude, position.longitude));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is _LocationShareFailure
            ? error.message
            : 'לא ניתן לקבל מיקום כעת. אפשר לבחור נקודה במפה או להזין מיקום ידנית.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _message() {
    final name = _name.text.trim();
    if (_point != null) {
      return SharedPlace.point(_point!.latitude, _point!.longitude,
              title: name.isEmpty ? 'מיקום משותף' : name)
          .toMessageText();
    }
    if (_latitude.text.trim().isNotEmpty ||
        _longitude.text.trim().isNotEmpty ||
        name.isEmpty) {
      return null;
    }
    return SharedPlace(
            title: name,
            url: Uri.https('www.google.com', '/maps/search/',
                {'api': '1', 'query': name}).toString())
        .toMessageText();
  }

  @override
  Widget build(BuildContext context) {
    final message = _message();
    return Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('שיתוף מיקום או מקום'),
          content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                    const Text(
                        'בחרו נקודה מדויקת או הזינו שם מקום לחיפוש במפה.'),
                    if (widget.isGroup)
                      const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('כל חברי הקבוצה יוכלו לראות את המיקום.',
                              style: TextStyle(color: Colors.orange))),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                        onPressed: _busy ? null : _currentLocation,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.my_location),
                        label: const Text('קבלת המיקום הנוכחי')),
                    const SizedBox(height: 12),
                    LocationAutocompleteField(
                        controller: _name,
                        api: widget.api,
                        label: 'שם המקום או כתובת (אפשר גם ללא נקודה)',
                        hint: 'לדוגמה: הכותל, ירושלים',
                        onChanged: (_) => setState(() {}),
                        onSelected: (_) => setState(() {})),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                          child: TextField(
                              controller: _latitude,
                              textDirection: TextDirection.ltr,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true, signed: true),
                              onChanged: (_) => _coordinatesChanged(),
                              decoration: const InputDecoration(
                                  labelText: 'קו רוחב (-90 עד 90)',
                                  border: OutlineInputBorder()))),
                      const SizedBox(width: 8),
                      Expanded(
                          child: TextField(
                              controller: _longitude,
                              textDirection: TextDirection.ltr,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true, signed: true),
                              onChanged: (_) => _coordinatesChanged(),
                              decoration: const InputDecoration(
                                  labelText: 'קו אורך (-180 עד 180)',
                                  border: OutlineInputBorder())))
                    ]),
                    if (_point == null &&
                        (_latitude.text.isNotEmpty ||
                            _longitude.text.isNotEmpty))
                      const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text('יש להזין שני מספרים בטווח המצוין.',
                              style: TextStyle(color: Colors.red))),
                    const SizedBox(height: 12),
                    if (!_mapAllowed) ...[
                      const Text(
                          'הצגת המפה דרך OpenStreetMap תעביר לשירות את אזור המפה ואת כתובת הרשת שלכם.'),
                      TextButton.icon(
                          onPressed: () => setState(() => _mapAllowed = true),
                          icon: const Icon(Icons.map_outlined),
                          label: const Text('הצגת מפה לבחירת נקודה')),
                    ] else
                      LocationPointPicker(
                          point: _point, onSelected: _selectPoint),
                    if (_point != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                              'הנקודה שתישלח: ${_point!.latitude.toStringAsFixed(6)}, ${_point!.longitude.toStringAsFixed(6)}',
                              textDirection: TextDirection.rtl)),
                    if (_error != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(_error!,
                              style: const TextStyle(color: Colors.red))),
                  ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('ביטול')),
            FilledButton(
                onPressed: message == null || _busy
                    ? null
                    : () => Navigator.pop(context, message),
                child: const Text('המשך לשיתוף'))
          ],
        ));
  }
}

class _LocationShareFailure implements Exception {
  final String message;
  const _LocationShareFailure(this.message);
}

/// Only currently visible OSM tiles are requested. There is no prefetching,
/// offline download, reverse geocoding or location tracking.
class LocationPointPicker extends StatefulWidget {
  final LocationMapPoint? point;
  final ValueChanged<LocationMapPoint> onSelected;
  final bool loadTiles;
  const LocationPointPicker(
      {super.key, this.point, required this.onSelected, this.loadTiles = true});
  @override
  State<LocationPointPicker> createState() => _LocationPointPickerState();
}

class _LocationPointPickerState extends State<LocationPointPicker> {
  late LocationMapPoint _center =
      widget.point ?? const LocationMapPoint(31.7683, 35.2137);
  int _zoom = 7;
  @override
  void didUpdateWidget(LocationPointPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.point != oldWidget.point && widget.point != null) {
      _center = widget.point!;
    }
  }

  void _move(Offset delta) => setState(() => _center =
      locationMapUnproject(locationMapProject(_center, _zoom) - delta, _zoom));

  @override
  Widget build(BuildContext context) =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('לחצו על המפה לבחירת נקודה. גררו כדי להזיז את המפה.')),
        ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
                height: 280,
                child: LayoutBuilder(builder: (context, constraints) {
                  final size =
                      Size(constraints.maxWidth, constraints.maxHeight);
                  final center = locationMapProject(_center, _zoom);
                  final origin =
                      center - Offset(size.width / 2, size.height / 2);
                  final count = 1 << _zoom;
                  final minX = (origin.dx / 256).floor(),
                      maxX = ((origin.dx + size.width) / 256).floor();
                  final minY = math.max(0, (origin.dy / 256).floor());
                  final maxY = math.min(
                      count - 1, ((origin.dy + size.height) / 256).floor());
                  final pin = widget.point == null
                      ? null
                      : locationMapProject(widget.point!, _zoom);
                  var pinX = pin == null ? 0.0 : pin.dx - origin.dx;
                  if (pin != null) {
                    final world = 256.0 * count;
                    while (pinX < -world / 2) {
                      pinX += world;
                    }
                    while (pinX > size.width + world / 2) {
                      pinX -= world;
                    }
                  }
                  return Stack(children: [
                    GestureDetector(
                        key: const ValueKey('location-map-canvas'),
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (details) => _move(details.delta),
                        onTapUp: (details) => widget.onSelected(
                            locationMapUnproject(
                                origin + details.localPosition, _zoom)),
                        child: ColoredBox(
                            color: const Color(0xffe4e9e8),
                            child: Stack(children: [
                              if (widget.loadTiles)
                                for (var y = minY; y <= maxY; y++)
                                  for (var x = minX; x <= maxX; x++)
                                    Positioned(
                                        left: x * 256 - origin.dx,
                                        top: y * 256 - origin.dy,
                                        width: 256,
                                        height: 256,
                                        child: _LocationMapTile(
                                            key: ValueKey(
                                                '$_zoom/${(x % count + count) % count}/$y'),
                                            uri: Uri.https(_mapTileHost,
                                                '/$_zoom/${(x % count + count) % count}/$y.png'))),
                              if (pin != null)
                                Positioned(
                                    left: pinX - 16,
                                    top: pin.dy - origin.dy - 32,
                                    child: const IgnorePointer(
                                        child: Icon(Icons.location_on,
                                            color: Colors.red, size: 32))),
                            ]))),
                    Positioned(
                        right: 8,
                        top: 8,
                        child: Column(children: [
                          _zoomButton(
                              Icons.add,
                              'התקרבות',
                              _zoom < 18
                                  ? () => setState(() => _zoom++)
                                  : null),
                          const SizedBox(height: 4),
                          _zoomButton(Icons.remove, 'התרחקות',
                              _zoom > 2 ? () => setState(() => _zoom--) : null),
                        ])),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      child: Material(
                          color: Colors.white.withValues(alpha: 0.9),
                          child: InkWell(
                              onTap: () => launchUrl(
                                  Uri.parse(
                                      'https://www.openstreetmap.org/copyright'),
                                  mode: LaunchMode.externalApplication),
                              child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 2),
                                  child: Text('© OpenStreetMap contributors',
                                      textDirection: TextDirection.ltr,
                                      style: TextStyle(fontSize: 11))))),
                    ),
                  ]);
                }))),
      ]);

  Widget _zoomButton(
          IconData icon, String label, VoidCallback? action) =>
      Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(5),
          child: IconButton(
              tooltip: label,
              onPressed: action,
              icon: Icon(icon),
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero));
}

class _LocationMapTile extends StatefulWidget {
  final Uri uri;
  const _LocationMapTile({super.key, required this.uri});
  @override
  State<_LocationMapTile> createState() => _LocationMapTileState();
}

class _LocationMapTileState extends State<_LocationMapTile> {
  late final Future<Uint8List?> _bytes = loadLocationMapTile(widget.uri);
  Widget _missing() => const Center(
      child: Icon(Icons.map_outlined, color: Colors.grey, size: 24));
  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Image.network(widget.uri.toString(),
          fit: BoxFit.fill, errorBuilder: (_, error, stack) => _missing());
    }
    return FutureBuilder<Uint8List?>(
        future: _bytes,
        builder: (context, snapshot) => snapshot.data == null
            ? (snapshot.connectionState == ConnectionState.done
                ? _missing()
                : const SizedBox.shrink())
            : Image.memory(snapshot.data!,
                fit: BoxFit.fill,
                errorBuilder: (_, error, stack) => _missing()));
  }
}
