import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'inline_custom_emoji.dart';

/// Chooses one immutable library ID. This dialog never writes a reaction.
Future<String?> showMessageReactionEmojiPicker(BuildContext context,
        {String? selectedEmoji}) =>
    showDialog<String>(
      context: context,
      useRootNavigator: false,
      routeSettings: const RouteSettings(name: 'message-reaction-picker'),
      builder: (_) => _MessageReactionEmojiPicker(selectedEmoji: selectedEmoji),
    );

class _ReactionEmoji {
  const _ReactionEmoji(this.id, this.label, this.url);
  final int id;
  final String label, url;
  String get token => '[[bt-emoji:${id.toString().padLeft(3, '0')}]]';
}

class _MessageReactionEmojiPicker extends StatefulWidget {
  const _MessageReactionEmojiPicker({this.selectedEmoji});
  final String? selectedEmoji;

  @override
  State<_MessageReactionEmojiPicker> createState() =>
      _MessageReactionEmojiPickerState();
}

class _MessageReactionEmojiPickerState
    extends State<_MessageReactionEmojiPicker> {
  final _search = TextEditingController();
  List<_ReactionEmoji>? _entries;
  AssetBundle? _bundle;
  Object? _request;
  bool _failed = false;
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bundle = DefaultAssetBundle.of(context);
    if (identical(_bundle, bundle)) return;
    _bundle = bundle;
    _load();
  }

  Future<void> _load() async {
    final request = Object();
    _request = request;
    try {
      final payload = jsonDecode(
          await _bundle!.loadString('assets/stickers/user-catalog.json'));
      if (payload is! Map || payload['categories'] is! List) {
        throw const FormatException('Invalid reaction library');
      }
      final category = (payload['categories'] as List)
          .whereType<Map>()
          .where((category) => category['id'] == 'user-stickers')
          .single;
      final labels = category['labels'];
      if (labels is! List || labels.length != 150) {
        throw const FormatException('Invalid immutable reaction IDs');
      }
      // Reaction IDs retain the original 150 images independently of the
      // live sticker and emoji folders used by the composer.
      final folder = category['coloredPath'] ??
          (category['path'] == 'stickers' ? 'user-20261008-color' : category['path']);
      final entries = <_ReactionEmoji>[];
      for (var index = 0; index < labels.length; index++) {
        final id = index + 1;
        final label = labels[index];
        final url = '/betshuva-app/expression-library/$folder/'
            'sticker-${id.toString().padLeft(2, '0')}.png';
        if (label is! String ||
            label.trim().isEmpty ||
            inlineEmojiIdFromUrl(url) != id) {
          throw const FormatException('Invalid reaction library item');
        }
        entries.add(_ReactionEmoji(id, label, 'https://betshuva.com$url'));
      }
      if (!mounted || !identical(request, _request)) return;
      setState(() {
        _entries = entries;
        _failed = false;
      });
    } catch (_) {
      if (mounted && identical(request, _request)) {
        setState(() => _failed = true);
      }
    }
  }

  @override
  void dispose() {
    _request = null;
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final filtered = entries
        ?.where((entry) => entry.label.toLowerCase().contains(_query))
        .toList();
    final media = MediaQuery.of(context);
    final height = math.min(600.0,
        math.max(180.0, (media.size.height - media.viewInsets.bottom) * .75));
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        key: const ValueKey('message-reaction-library'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: SizedBox(
          width: 620,
          height: height,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: CustomScrollView(
                key: const ValueKey('reaction-library-scroll'),
                slivers: [
                  SliverToBoxAdapter(
                      child: Row(children: [
                    const Expanded(
                        child: Text('כל האימוג׳י',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold))),
                    IconButton(
                        tooltip: 'סגירה',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close)),
                  ])),
                  if (_failed)
                    SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              const Text('לא ניתן לטעון את האימוג׳י כרגע'),
                              TextButton.icon(
                                  onPressed: () {
                                    setState(() => _failed = false);
                                    _load();
                                  },
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('נסה שוב')),
                            ])))
                  else if (entries == null)
                    const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(child: CircularProgressIndicator()))
                  else ...[
                    SliverToBoxAdapter(
                        child: TextField(
                      key: const ValueKey('reaction-library-search'),
                      controller: _search,
                      onChanged: (query) =>
                          setState(() => _query = query.trim().toLowerCase()),
                      decoration: InputDecoration(
                        hintText: 'חיפוש אימוג׳י',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'ניקוי החיפוש',
                                onPressed: () {
                                  _search.clear();
                                  setState(() => _query = '');
                                },
                                icon: const Icon(Icons.close)),
                        border: const OutlineInputBorder(),
                      ),
                    )),
                    const SliverToBoxAdapter(child: SizedBox(height: 8)),
                    if (filtered!.isEmpty)
                      const SliverFillRemaining(
                          hasScrollBody: false,
                          child:
                              Center(child: Text('לא נמצאו אימוג׳י מתאימים')))
                    else
                      SliverGrid.builder(
                        key: const ValueKey('message-reaction-library-grid'),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 52, mainAxisExtent: 52),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final entry = filtered[index];
                          return Tooltip(
                            message: entry.label,
                            excludeFromSemantics: true,
                            child: Semantics(
                              button: true,
                              selected: widget.selectedEmoji == entry.token,
                              label: 'תגובה: ${entry.label}',
                              child: InkWell(
                                key: ValueKey('reaction-library-emoji-'
                                    '${entry.id.toString().padLeft(3, '0')}'),
                                borderRadius: BorderRadius.circular(8),
                                onTap: () =>
                                    Navigator.pop(context, entry.token),
                                child: Center(
                                  child: Image.network(entry.url,
                                      width: 32,
                                      height: 32,
                                      fit: BoxFit.contain,
                                      excludeFromSemantics: true,
                                      errorBuilder: (_, __, ___) => const Icon(
                                          Icons.emoji_emotions,
                                          size: 32)),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ]),
          ),
        ),
      ),
    );
  }
}
