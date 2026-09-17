import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Chooses a Unicode emoji for insertion into the current message draft.
/// This widget does not send a message or create an attachment.
class InlineEmojiPicker extends StatefulWidget {
  const InlineEmojiPicker({
    super.key,
    required this.onSelected,
    this.primaryColor,
    this.header,
  });

  final ValueChanged<String> onSelected;
  final Color? primaryColor;
  final Widget? header;

  @override
  State<InlineEmojiPicker> createState() => _InlineEmojiPickerState();
}

class _EmojiEntry {
  const _EmojiEntry(this.emoji, this.category, this.label, this.code);

  final String emoji;
  final String category;
  final String label;
  final String code;

  bool matches(String query) =>
      '$emoji $category $label'.toLowerCase().contains(query);
}

class _InlineEmojiPickerState extends State<InlineEmojiPicker> {
  final _searchController = TextEditingController();
  AssetBundle? _bundle;
  Object? _loadRequest;
  List<_EmojiEntry>? _entries;
  bool _loadFailed = false;
  String? _category;
  String _query = '';

  Color get _primaryColor => widget.primaryColor ?? const Color(0xFF1E6FA8);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bundle = DefaultAssetBundle.of(context);
    if (identical(bundle, _bundle)) return;
    _bundle = bundle;
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    final request = Object();
    _loadRequest = request;
    try {
      final json = jsonDecode(
        await _bundle!.loadString(
          'assets/twemoji/emoji_allowlist.json',
          cache: false,
        ),
      );
      if (json is! List) throw const FormatException('Invalid emoji catalog');
      final entries = <_EmojiEntry>[];
      final seen = <String>{};
      for (final item in json) {
        if (item is! Map) continue;
        final emoji = item['emoji'];
        final category = item['category'];
        final label = item['label_he'];
        final code = item['twemoji_code'];
        if (emoji is! String ||
            emoji.isEmpty ||
            category is! String ||
            label is! String ||
            code is! String ||
            !RegExp(r'^[0-9a-f]+(?:-[0-9a-f]+)*$').hasMatch(code) ||
            !seen.add(emoji)) {
          continue;
        }
        entries.add(_EmojiEntry(emoji, category, label, code));
      }
      if (entries.isEmpty) throw const FormatException('Empty emoji catalog');
      if (!mounted || !identical(_loadRequest, request)) return;
      setState(() {
        _entries = entries;
        _loadFailed = false;
      });
    } catch (_) {
      if (!mounted || !identical(_loadRequest, request)) return;
      setState(() => _loadFailed = true);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Widget _categoryChip(String? category) => Padding(
        padding: const EdgeInsetsDirectional.only(end: 8),
        child: ChoiceChip(
          label: Text(category ?? 'הכול'),
          selected: _category == category,
          selectedColor: _primaryColor.withValues(alpha: 0.12),
          showCheckmark: false,
          onSelected: (_) => setState(() => _category = category),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final categories = entries?.map((entry) => entry.category).toSet();
    final filtered = entries
        ?.where((entry) =>
            (_category == null || entry.category == _category) &&
            entry.matches(_query))
        .toList();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: CustomScrollView(
        slivers: [
          if (widget.header != null) SliverToBoxAdapter(child: widget.header!),
          if (_loadFailed)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('לא ניתן לטעון את האימוג׳ים כרגע',
                        textAlign: TextAlign.center),
                    TextButton.icon(
                      onPressed: () {
                        setState(() => _loadFailed = false);
                        _loadEntries();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('ניסיון נוסף'),
                    ),
                  ],
                ),
              ),
            )
          else if (entries == null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: CircularProgressIndicator(color: _primaryColor),
                ),
              ),
            )
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) =>
                      setState(() => _query = value.trim().toLowerCase()),
                  decoration: InputDecoration(
                    hintText: 'חיפוש אימוג׳י',
                    prefixIcon: Icon(Icons.search, color: _primaryColor),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'ניקוי החיפוש',
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.close),
                          ),
                    filled: true,
                    fillColor: _primaryColor.withValues(alpha: 0.04),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: _primaryColor.withValues(alpha: 0.20),
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    _categoryChip(null),
                    ...categories!.map(_categoryChip),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            if (filtered!.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'לא נמצאו אימוג׳ים מתאימים',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                sliver: SliverGrid.builder(
                  key: ValueKey((_category, _query)),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 56,
                    mainAxisExtent: 52,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final entry = filtered[index];
                    return Tooltip(
                      message: '${entry.label} ${entry.emoji}',
                      excludeFromSemantics: true,
                      child: Semantics(
                        label: 'הוספת אימוג׳י: ${entry.label} ${entry.emoji}',
                        button: true,
                        child: InkWell(
                          key: ValueKey('inline-emoji-${entry.code}'),
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => widget.onSelected(entry.emoji),
                          child: Center(
                            child: ExcludeSemantics(
                              child: SvgPicture.asset(
                                'assets/twemoji/svg/${entry.code}.svg',
                                width: 28,
                                height: 28,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }
}
