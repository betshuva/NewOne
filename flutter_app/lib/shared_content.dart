import 'dart:convert';

import 'package:flutter/material.dart';

const sharedContactWirePrefix = 'betshuva://contact/';
const maxSharedVCardBytes = 1024 * 1024;
const maxSharedVCardContacts = 50;

class SharedLink {
  final String title;
  final String url;
  const SharedLink({required this.title, required this.url});
  String toMessageText() => title.isEmpty ? url : '$title\n$url';
}

class SharedPlace extends SharedLink {
  final double? latitude;
  final double? longitude;
  const SharedPlace(
      {required super.title,
      required super.url,
      this.latitude,
      this.longitude});

  factory SharedPlace.point(double latitude, double longitude,
      {String title = 'מיקום משותף'}) {
    if (!validSharedCoordinates(latitude, longitude)) {
      throw const FormatException('קואורדינטות לא תקינות');
    }
    return SharedPlace(
        title: title.trim(),
        latitude: latitude,
        longitude: longitude,
        url: Uri.https('www.google.com', '/maps/search/', {
          'api': '1',
          'query':
              '${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}',
        }).toString());
  }
}

bool validSharedCoordinates(double latitude, double longitude) =>
    latitude.isFinite &&
    longitude.isFinite &&
    latitude.abs() <= 90 &&
    longitude.abs() <= 180;

SharedLink? parseSharedLink(String text) {
  if (text.length > 16384) return null;
  final match = RegExp(r'https://[^\s<>"\x00-\x1f]+', caseSensitive: false)
      .firstMatch(text);
  if (match == null) return null;
  final raw = match.group(0)!.replaceFirst(RegExp(r'[.,!?)\]}]+$'), '');
  final uri = Uri.tryParse(raw);
  if (raw.length > 2048 ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443) {
    return null;
  }
  final before = text.substring(0, match.start).trim();
  final title = before.isEmpty ? '' : before.split('\n').first.trim();
  return SharedLink(
      title: title.length > 200 ? title.substring(0, 200) : title,
      url: uri.toString());
}

SharedPlace? parseSharedPlace(String text) {
  if (text.length > 16384) return null;
  final geo = RegExp(r'^geo:([+-]?[\d.]+),([+-]?[\d.]+)(?:[;?].*)?$',
          caseSensitive: false)
      .firstMatch(text.trim());
  if (geo != null) {
    var lat = double.tryParse(geo.group(1)!);
    var lon = double.tryParse(geo.group(2)!);
    final query = Uri.tryParse(text.trim())?.queryParameters['q'];
    final pin = query == null
        ? null
        : RegExp(
                r'^\s*([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)(?:\s*\([^\n]*\))?\s*$')
            .firstMatch(query);
    if (pin != null) {
      lat = double.tryParse(pin.group(1)!);
      lon = double.tryParse(pin.group(2)!);
    } else if (query != null && query.trim().isNotEmpty) {
      // geo:0,0?q=address denotes an address search, not a pin at 0,0.
      return SharedPlace(
          title: query.trim(),
          url: Uri.https('www.google.com', '/maps/search/',
              {'api': '1', 'query': query.trim()}).toString());
    }
    if (lat == null || lon == null || !validSharedCoordinates(lat, lon)) {
      return null;
    }
    return SharedPlace.point(lat, lon);
  }
  final link = parseSharedLink(text);
  if (link == null) return null;
  final uri = Uri.parse(link.url);
  final host = uri.host.toLowerCase();
  const googleHosts = {
    'google.com',
    'www.google.com',
    'maps.google.com',
    'google.co.il',
    'www.google.co.il',
    'maps.google.co.il'
  };
  final google = googleHosts.contains(host) &&
      (uri.path == '/maps' ||
          uri.path.startsWith('/maps/') ||
          (host.startsWith('maps.') && (uri.path.isEmpty || uri.path == '/')));
  final short = host == 'maps.app.goo.gl' ||
      (host == 'goo.gl' && uri.path.startsWith('/maps/'));
  final osm = {'openstreetmap.org', 'www.openstreetmap.org'}.contains(host);
  if (!google && !short && !osm) return null;
  double? lat, lon;
  // A map viewport (@lat,lng) is not necessarily the place's pin. Never
  // mislabel it as the point the sender selected.
  final query = uri.queryParameters['query'] ?? uri.queryParameters['q'];
  final coordinate = query == null
      ? null
      : RegExp(r'^\s*([+-]?\d+(?:\.\d+)?)\s*,\s*([+-]?\d+(?:\.\d+)?)\s*$')
          .firstMatch(query);
  if (coordinate != null) {
    lat = double.tryParse(coordinate.group(1)!);
    lon = double.tryParse(coordinate.group(2)!);
  } else if (osm) {
    lat = double.tryParse(uri.queryParameters['mlat'] ?? '');
    lon = double.tryParse(uri.queryParameters['mlon'] ?? '');
  }
  if ((lat == null) != (lon == null)) return null;
  if (lat != null && lon != null && !validSharedCoordinates(lat, lon)) {
    return null;
  }
  return SharedPlace(
      title: link.title.isEmpty ? 'מקום במפה' : link.title,
      url: link.url,
      latitude: lat,
      longitude: lon);
}

class SharedContactDetails {
  final String name;
  final List<String> phones;
  final List<String> emails;
  final List<String> addresses;
  final String city;
  const SharedContactDetails(
      {required this.name,
      this.phones = const [],
      this.emails = const [],
      this.addresses = const [],
      this.city = ''});
}

String encodeSharedContactCard(Map<String, String> fields) =>
    '$sharedContactWirePrefix${base64Url.encode(utf8.encode(jsonEncode(fields)))}';

/// vCard text is local input. PHOTO, LOGO, URLs and arbitrary extensions are
/// never downloaded or added to the shared card.
List<SharedContactDetails> parseSharedVCard(String text) {
  if (text.length > maxSharedVCardBytes ||
      utf8.encode(text).length > maxSharedVCardBytes) {
    throw const FormatException('קובץ אנשי הקשר גדול מדי (עד 1 MB)');
  }
  text = text.replaceFirst(RegExp(r'^\uFEFF'), '');
  final unfolded = <String>[];
  for (final line in text.replaceAll(RegExp(r'\r\n|\r'), '\n').split('\n')) {
    if (unfolded.isNotEmpty &&
        unfolded.last.endsWith('=') &&
        unfolded.last.toUpperCase().contains('ENCODING=QUOTED-PRINTABLE')) {
      unfolded[unfolded.length - 1] =
          unfolded.last.substring(0, unfolded.last.length - 1) +
              (line.startsWith(' ') || line.startsWith('\t')
                  ? line.substring(1)
                  : line);
    } else if (unfolded.isNotEmpty &&
        (line.startsWith(' ') || line.startsWith('\t'))) {
      unfolded[unfolded.length - 1] += line.substring(1);
    } else {
      unfolded.add(line);
    }
  }
  final cards = <SharedContactDetails>[];
  bool active = false;
  var cardCount = 0;
  var name = '', alternateName = '', city = '';
  var phones = <String>[], emails = <String>[], addresses = <String>[];
  for (final line in unfolded) {
    if (line.toUpperCase() == 'BEGIN:VCARD') {
      if (active) throw const FormatException('מבנה vCard אינו תקין');
      if (++cardCount > maxSharedVCardContacts) {
        throw const FormatException('אפשר לייבא עד 50 אנשי קשר בכל פעם');
      }
      active = true;
      name = '';
      alternateName = '';
      city = '';
      phones = [];
      emails = [];
      addresses = [];
      continue;
    }
    if (line.toUpperCase() == 'END:VCARD') {
      if (!active) continue;
      final displayName = name.isNotEmpty ? name : alternateName;
      if (displayName.isNotEmpty ||
          phones.isNotEmpty ||
          emails.isNotEmpty ||
          addresses.isNotEmpty) {
        cards.add(SharedContactDetails(
            name: displayName,
            phones: phones,
            emails: emails,
            addresses: addresses,
            city: city));
      }
      active = false;
      continue;
    }
    if (!active) continue;
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final header = line.substring(0, colon);
    final property = header.split(';').first.split('.').last.toUpperCase();
    if (!{'FN', 'N', 'TEL', 'EMAIL', 'ADR'}.contains(property)) continue;
    final value = _vCardValue(header, line.substring(colon + 1));
    if (value.length > 4096) {
      throw const FormatException('פרט איש קשר ארוך מדי');
    }
    switch (property) {
      case 'FN':
        name = _unescapeVCard(value).trim();
      case 'N':
        final parts = _vCardComponents(value);
        alternateName = [if (parts.length > 1) parts[1], parts.first]
            .where((part) => part.isNotEmpty)
            .join(' ')
            .trim();
      case 'TEL':
        final phone = _unescapeVCard(value)
            .trim()
            .replaceFirst(RegExp(r'^tel:', caseSensitive: false), '');
        if (phone.isNotEmpty && !phones.contains(phone)) phones.add(phone);
      case 'EMAIL':
        final email = _unescapeVCard(value)
            .trim()
            .replaceFirst(RegExp(r'^mailto:', caseSensitive: false), '');
        if (email.isNotEmpty && !emails.contains(email)) emails.add(email);
      case 'ADR':
        final parts = _vCardComponents(value);
        final address = parts.where((part) => part.isNotEmpty).join(', ');
        if (address.isNotEmpty && !addresses.contains(address)) {
          addresses.add(address);
        }
        if (city.isEmpty && parts.length > 3) city = parts[3];
    }
  }
  if (active) throw const FormatException('כרטיס איש קשר אינו שלם');
  return cards;
}

String _vCardValue(String header, String value) {
  final upper = header.toUpperCase();
  if (upper.contains('ENCODING=QUOTED-PRINTABLE')) {
    final bytes = <int>[];
    for (var i = 0; i < value.length; i++) {
      if (value[i] == '=' && i + 2 < value.length) {
        final byte = int.tryParse(value.substring(i + 1, i + 3), radix: 16);
        if (byte != null) {
          bytes.add(byte);
          i += 2;
          continue;
        }
      }
      if (value.codeUnitAt(i) >= 0xd800 &&
          value.codeUnitAt(i) <= 0xdbff &&
          i + 1 < value.length &&
          value.codeUnitAt(i + 1) >= 0xdc00 &&
          value.codeUnitAt(i + 1) <= 0xdfff) {
        bytes.addAll(utf8.encode(value.substring(i, i + 2)));
        i++;
      } else {
        bytes.addAll(utf8.encode(value[i]));
      }
    }
    if (upper.contains('CHARSET=ISO-8859-1')) return latin1.decode(bytes);
    return utf8.decode(bytes, allowMalformed: false);
  }
  if (upper.contains('ENCODING=B') || upper.contains('ENCODING=BASE64')) {
    return utf8.decode(base64.decode(value), allowMalformed: false);
  }
  return value;
}

String _unescapeVCard(String value) => value.replaceAllMapped(
    RegExp(r'\\([nN,;\\])'),
    (match) => {'n': '\n', 'N': '\n'}[match.group(1)] ?? match.group(1)!);

List<String> _vCardComponents(String value) {
  final parts = <String>[];
  var start = 0;
  for (var i = 0; i < value.length; i++) {
    if (value[i] == '\\') {
      i++;
      continue;
    }
    if (value[i] == ';') {
      parts.add(_unescapeVCard(value.substring(start, i)));
      start = i + 1;
    }
  }
  parts.add(_unescapeVCard(value.substring(start)));
  return parts;
}

/// Select one phone/email/address explicitly when there are multiple values.
/// Only the name is selected by default; the rest stay local until selected.
Future<String?> selectContactDetails(
    BuildContext context, SharedContactDetails contact,
    {bool isGroup = false}) async {
  final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) =>
          _ContactDetailsSelection(contact: contact, isGroup: isGroup));
  return fields == null ? null : encodeSharedContactCard(fields);
}

class _ContactDetailsSelection extends StatefulWidget {
  final SharedContactDetails contact;
  final bool isGroup;
  const _ContactDetailsSelection(
      {required this.contact, required this.isGroup});
  @override
  State<_ContactDetailsSelection> createState() =>
      _ContactDetailsSelectionState();
}

class _ContactDetailsSelectionState extends State<_ContactDetailsSelection> {
  late bool _name = widget.contact.name.isNotEmpty;
  bool _city = false;
  String? _phone, _email, _address;

  @override
  Widget build(BuildContext context) {
    final contact = widget.contact;
    final selected = <String, String>{
      if (_name) 'name': contact.name,
      if (_phone != null) 'phone': _phone!,
      if (_email != null) 'email': _email!,
      if (_city) 'city': contact.city,
      if (_address != null) 'address': _address!,
    };
    Widget choice(String label, List<String> values, String? current,
            ValueChanged<String?> select) =>
        Column(mainAxisSize: MainAxisSize.min, children: [
          for (final value in values)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('$label: $value', textDirection: TextDirection.rtl),
              value: value == current,
              onChanged: (checked) =>
                  setState(() => select(checked == true ? value : null)),
            )
        ]);
    return Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('בחירת פרטי איש קשר לשיתוף'),
          content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                    const Text(
                        'רק הפרטים שסומנו יישלחו. ניתן לבחור מספר וכתובת אימייל אחד.'),
                    if (widget.isGroup)
                      const Padding(
                          padding: EdgeInsets.only(top: 10),
                          child: Text(
                              'כל חברי הקבוצה יוכלו לראות ולשמור את הפרטים.',
                              style: TextStyle(color: Colors.orange))),
                    if (contact.name.isNotEmpty)
                      CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('שם: ${contact.name}'),
                          value: _name,
                          onChanged: (value) =>
                              setState(() => _name = value ?? false)),
                    choice('טלפון', contact.phones, _phone,
                        (value) => _phone = value),
                    choice('אימייל', contact.emails, _email,
                        (value) => _email = value),
                    if (contact.city.isNotEmpty)
                      CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('עיר: ${contact.city}'),
                          value: _city,
                          onChanged: (value) =>
                              setState(() => _city = value ?? false)),
                    choice('כתובת', contact.addresses, _address,
                        (value) => _address = value),
                  ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('ביטול')),
            FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.pop(context, selected),
                child: const Text('המשך לשיתוף'))
          ],
        ));
  }
}
