import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ProfilePhotoAudience {
  final String mode;
  final Set<String> userIds;
  final Set<String> groupIds;

  const ProfilePhotoAudience({
    this.mode = 'all',
    this.userIds = const {},
    this.groupIds = const {},
  });

  factory ProfilePhotoAudience.fromJson(Map<String, dynamic> data) =>
      ProfilePhotoAudience(
        mode: data['privacy_pic'] as String? ?? 'all',
        userIds: (data['profile_photo_user_ids'] as List? ?? [])
            .map((id) => id.toString())
            .toSet(),
        groupIds: (data['profile_photo_group_ids'] as List? ?? [])
            .map((id) => id.toString())
            .toSet(),
      );

  String get label => switch (mode) {
        'contacts' => 'אנשי קשר בלבד',
        'nobody' => 'רק אני',
        'selected' => '${userIds.length} משתמשים ו־${groupIds.length} קבוצות',
        _ => 'כל המשתמשים',
      };

  Map<String, dynamic> toJson() => {
        'privacy_pic': mode,
        'profile_photo_user_ids': userIds.toList(),
        'profile_photo_group_ids': groupIds.toList(),
      };
}

Future<ProfilePhotoAudience?> chooseProfilePhotoAudience(
  BuildContext context, {
  required String api,
  required String token,
  ProfilePhotoAudience? initial,
}) =>
    showModalBottomSheet<ProfilePhotoAudience>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _AudienceSheet(api: api, token: token, initial: initial),
    );

class _AudienceSheet extends StatefulWidget {
  final String api;
  final String token;
  final ProfilePhotoAudience? initial;
  const _AudienceSheet({required this.api, required this.token, this.initial});

  @override
  State<_AudienceSheet> createState() => _AudienceSheetState();
}

class _AudienceSheetState extends State<_AudienceSheet> {
  bool _loading = true;
  bool _teen = false;
  String? _error;
  String _mode = 'all';
  String _search = '';
  final _users = <String>{};
  final _groups = <String>{};
  List<Map<String, dynamic>> _userOptions = [];
  List<Map<String, dynamic>> _groupOptions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await http
          .get(Uri.parse('${widget.api}/profile/photo-audience'), headers: {
        'Authorization': 'Bearer ${widget.token}'
      }).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw Exception('load');
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final audience = widget.initial ?? ProfilePhotoAudience.fromJson(data);
      if (!mounted) return;
      setState(() {
        _mode = audience.mode;
        _users.addAll(audience.userIds);
        _groups.addAll(audience.groupIds);
        _teen = data['is_teen'] == true;
        _userOptions = (data['users'] as List).cast<Map<String, dynamic>>();
        _groupOptions = (data['groups'] as List).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'לא ניתן לטעון את בחירת הצופים';
        });
      }
    }
  }

  Widget _option(String value, String title, IconData icon) => ListTile(
        dense: true,
        leading: Icon(icon),
        title: Text(title),
        trailing: Icon(
            _mode == value
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            color:
                _mode == value ? Theme.of(context).colorScheme.primary : null),
        onTap: () => setState(() => _mode = value),
      );

  List<Widget> _choices(
      String title, List<Map<String, dynamic>> options, Set<String> selected) {
    final matches = options
        .where((item) =>
            (item['name']?.toString() ?? '').toLowerCase().contains(_search))
        .toList();
    if (matches.isEmpty) return [];
    return [
      Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child:
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
      ...matches.map((item) => CheckboxListTile(
            dense: true,
            title: Text(item['name']?.toString() ?? ''),
            value: selected.contains(item['id']),
            onChanged: (checked) => setState(() {
              final id = item['id'].toString();
              if (checked == true) {
                selected.add(id);
              } else {
                selected.remove(id);
              }
            }),
          )),
    ];
  }

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.rtl,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .85,
          child: Column(children: [
            ListTile(
              title: const Text('מי יכול לראות את התמונה?',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              trailing: IconButton(
                  tooltip: 'סגור',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context)),
            ),
            const Divider(height: 1),
            Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                Text(_error!),
                                TextButton(
                                    onPressed: _load,
                                    child: const Text('נסה שוב')),
                              ]))
                        : ListView(children: [
                            if (!_teen)
                              _option('all', 'כל המשתמשים', Icons.public),
                            _option('contacts', 'אנשי קשר בלבד',
                                Icons.contacts_outlined),
                            _option('selected', 'משתמשים וקבוצות שאבחר',
                                Icons.people_outline),
                            _option('nobody', 'רק אני', Icons.lock_outline),
                            if (_mode == 'selected') ...[
                              const Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 8),
                                  child: Text(
                                      'הצפייה תתאפשר לאנשים שבחרת ולחברים הפעילים בקבוצות שבחרת. ללא בחירה — רק לך.',
                                      style: TextStyle(fontSize: 12))),
                              Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16),
                                  child: TextField(
                                    decoration: const InputDecoration(
                                        hintText: 'חיפוש משתמש או קבוצה',
                                        prefixIcon: Icon(Icons.search)),
                                    onChanged: (text) => setState(() =>
                                        _search = text.trim().toLowerCase()),
                                  )),
                              ..._choices('משתמשים', _userOptions, _users),
                              ..._choices('קבוצות', _groupOptions, _groups),
                              if (_userOptions.isEmpty && _groupOptions.isEmpty)
                                const Padding(
                                    padding: EdgeInsets.all(16),
                                    child:
                                        Text('אין משתמשים או קבוצות לבחירה')),
                            ],
                          ])),
            SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      16, 8, 16, 12 + MediaQuery.viewInsetsOf(context).bottom),
                  child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _loading || _error != null
                            ? null
                            : () => Navigator.pop(
                                context,
                                ProfilePhotoAudience(
                                    mode: _mode,
                                    userIds: {..._users},
                                    groupIds: {..._groups})),
                        child: const Text('אישור הבחירה'),
                      )),
                )),
          ]),
        ),
      );
}
