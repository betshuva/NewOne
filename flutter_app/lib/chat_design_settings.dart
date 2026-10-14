import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ChatDesign {
  const ChatDesign({this.revision = 'initial', this.values = const {}});
  final String revision;
  final Map<String, dynamic> values;
  static const choices = <String, List<String>>{
    'composerToolsVisibility': ['always', 'focused', 'withText'],
    'messageMenuPresentation': ['auto', 'sheet', 'dialog'],
    'cardDetailsPresentation': ['dialog', 'sheet'],
    'cardTapAction': ['details', 'none'],
    'cardLongPressAction': ['menu', 'details', 'none'],
    'autoScrollMode': ['nearBottom', 'always', 'manual'],
    'listingLayout': ['list', 'cards'],
    'listingSearchSide': ['left', 'right'],
  };
  static const ranges = <String, List<double>>{
    'autoScrollDistance': [0, 240],
    'autoScrollDurationMs': [0, 800],
    'listingSearchDebounceMs': [0, 1500],
    'mediaMaxWidth': [140, 330],
    'mediaMaxHeight': [160, 480],
    'gifMaxHeight': [120, 360],
    'scanCardWidth': [220, 330],
    'noticeFontSize': [11, 16],
    'voiceWaveformHeight': [24, 64],
    'pollOptionSpacing': [0, 16],
    'listingImageSize': [64, 160],
    'listingCardPadding': [6, 20],
    'listingCardGap': [4, 24],
    'listingCornerRadius': [0, 24],
    'listingTitleSize': [13, 20],
    'listingResultsWidth': [320, 560],
    'listingSearchWidth': [320, 900],
    'listingFieldGap': [6, 24],
    'composerMinHeight': [36, 60],
    'composerVerticalPadding': [4, 12],
    'composerFontSize': [12, 18],
    'composerIconSize': [16, 28],
    'composerActionSize': [36, 56],
    'composerIconGap': [0, 12],
    'composerShortcutHeight': [24, 48],
    'messageHorizontalPadding': [4, 16],
    'messageVerticalPadding': [2, 12],
    'messageGap': [0, 16],
    'privateBubbleWidth': [.55, .9],
    'groupBubbleWidth': [.55, .9],
    'voicePlayerWidth': [220, 330],
    'textScale': [.9, 1.25],
  };
  static ChatDesign? parse(dynamic document) {
    if (document is! Map ||
        document['schemaVersion'] != 1 ||
        document['revision'] is! String ||
        document['settings'] is! Map) return null;
    final input = document['settings'] as Map;
    final clean = <String, dynamic>{};
    for (final entry in input.entries) {
      final key = entry.key;
      final value = entry.value;
      if (ranges.containsKey(key)) {
        final range = ranges[key]!;
        if (value is! num ||
            !value.isFinite ||
            value < range[0] ||
            value > range[1]) return null;
        clean[key as String] = value;
      } else if (const [
        'dismissComposerOnOutsideTap',
        'dismissKeyboardOnSend',
        'dismissKeyboardOnPicker',
        'restoreKeyboardAfterPicker',
        'closePickerAfterSelection',
        'closePickerOnOutsideTap',
        'messageMenuDismissOnOutsideTap',
        'listingSearchAsYouType',
        'listingSearchOnEnter',
        'compactBlockedMedia',
        'compactScanCards',
        'compactErrorCards',
        'compactWaitingCards',
        'compactVoicePlayer',
        'compactPolls',
        'showMessageTime',
        'timeBesideName',
        'showDeliveryStatus',
        'showComposerEmoji',
        'showComposerStickers',
        'showTypingIndicator',
        'showMediaMetadata',
        'showVoiceWaveform',
        'listingShowPrice',
        'listingShowLocation',
        'listingShowDate',
        'listingShowPublisher',
        'listingShowImages',
        'listingShowAi',
        'listingShowSale',
        'listingShowFree',
        'listingShowPost',
        'listingSingleFieldRows',
        'listingShowClearButtons',
        'showFileNames',
        'showScanMetadata',
        'showGroupDeliverySummary'
      ].contains(key)) {
        if (value is! bool) return null;
        clean[key as String] = value;
      } else if (const [
        'listingBackground',
        'listingCardBackground',
        'accentColor',
        'chatBackground',
        'incomingBubble',
        'outgoingBubble',
        'composerBackground',
        'composerBorderColor',
        'composerIconColor'
      ].contains(key)) {
        if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value))
          return null;
        final color = Color(int.parse('FF${value.substring(1)}', radix: 16));
        final luminance = color.computeLuminance();
        if (const ['accentColor', 'composerIconColor'].contains(key)
            ? 1.05 / (luminance + .05) < 4.5
            : luminance < .6) return null;
        clean[key as String] = value;
      } else if (choices.containsKey(key)) {
        if (!choices[key]!.contains(value)) return null;
        clean[key as String] = value;
      } else if (key == 'listingCategoryOrder' ||
          key == 'listingSearchFieldOrder' ||
          key == 'messageMenuOrder' ||
          key == 'listingSearchSectionOrder') {
        if (value is! List ||
            value.length > 50 ||
            value.toSet().length != value.length ||
            value.any((v) => v is! String || v.trim().isEmpty || v.length > 80))
          return null;
        clean[key as String] = List<String>.unmodifiable(value);
      }
      // New server fields can safely be ignored by older clients.
    }
    return ChatDesign(
        revision: document['revision'] as String,
        values: Map.unmodifiable(clean));
  }

  Map<String, dynamic> toJson() =>
      {'schemaVersion': 1, 'revision': revision, 'settings': values};
  double number(String key, double fallback) =>
      (values[key] as num?)?.toDouble() ?? fallback;
  bool flag(String key) => values[key] as bool? ?? true;
  String choice(String key, String fallback) =>
      values[key] as String? ?? fallback;
  List<String> orderedCategories(Iterable<String> categories) {
    final available = categories.toSet();
    final preferred =
        (values['listingCategoryOrder'] as List?)?.cast<String>() ??
            const <String>[];
    return [
      ...preferred.where(available.contains),
      ...available.where((c) => !preferred.contains(c))
    ];
  }

  List<T> orderedItems<T>(String key, List<T> fields, String Function(T) id) {
    final preferred =
        (values[key] as List?)?.cast<String>() ?? const <String>[];
    final result = List<T>.of(fields);
    int priority(T field) {
      final i = preferred.indexOf(id(field));
      return i < 0 ? preferred.length + fields.indexOf(field) : i;
    }

    result.sort((a, b) => priority(a).compareTo(priority(b)));
    return result;
  }

  List<T> orderedFields<T>(List<T> fields, String Function(T) id) {
    final preferred =
        (values['listingSearchFieldOrder'] as List?)?.cast<String>() ??
            const <String>[];
    final result = List<T>.of(fields);
    int priority(T field) {
      final i = preferred.indexOf(id(field));
      return i < 0 ? preferred.length + fields.indexOf(field) : i;
    }

    result.sort((a, b) => priority(a).compareTo(priority(b)));
    return result;
  }

  Color color(String key, Color fallback) => values[key] is String
      ? Color(int.parse('FF${(values[key] as String).substring(1)}', radix: 16))
      : fallback;
  EdgeInsets get bubblePadding => EdgeInsets.symmetric(
      horizontal: number('messageHorizontalPadding', 8),
      vertical: number('messageVerticalPadding', 5));
}

class ChatDesignStore extends ValueNotifier<ChatDesign>
    with WidgetsBindingObserver {
  ChatDesignStore(
      {http.Client? client,
      Future<SharedPreferences> Function()? preferences,
      this.pollInterval = const Duration(seconds: 30)})
      : _client = client,
        _preferences = preferences ?? SharedPreferences.getInstance,
        super(const ChatDesign());
  static final shared = ChatDesignStore();
  final http.Client? _client;
  final Future<SharedPreferences> Function() _preferences;
  final Duration pollInterval;
  String? _api;
  Timer? _timer;
  int _users = 0;
  bool _refreshing = false, _disposed = false, _paused = false;
  Future<void>? _initializing;
  String get _cacheKey => 'chat_design_v1:${_api ?? ''}';

  void attach(String api) {
    if (_disposed) return;
    _users++;
    if (_users > 1) return;
    _api = api;
    WidgetsBinding.instance.addObserver(this);
    _initializing = _loadAndRefresh();
    _schedule();
  }

  void detach() {
    if (_users == 0) return;
    if (--_users > 0) return;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }

  Future<void> _loadAndRefresh() async {
    try {
      final stored = (await _preferences()).getString(_cacheKey);
      final cached =
          stored == null ? null : ChatDesign.parse(jsonDecode(stored));
      if (!_disposed && cached != null) value = cached;
    } catch (_) {}
    if (!_disposed) await refresh();
  }

  Future<void> get ready => _initializing ?? Future<void>.value();
  void _schedule() {
    _timer?.cancel();
    if (_users > 0 && !_paused)
      _timer = Timer.periodic(pollInterval, (_) => refresh());
  }

  Future<void> refresh() async {
    if (_disposed || _refreshing || _api == null || _paused) return;
    _refreshing = true;
    try {
      final uri = Uri.parse('$_api/chat-design');
      final response = await (_client?.get(uri) ?? http.get(uri))
          .timeout(const Duration(seconds: 8));
      if (_disposed || response.statusCode != 200) return;
      final next = ChatDesign.parse(jsonDecode(response.body));
      if (next == null) return;
      if (jsonEncode(next.toJson()) != jsonEncode(value.toJson())) value = next;
      try {
        await (await _preferences())
            .setString(_cacheKey, jsonEncode(next.toJson()));
      } catch (_) {}
    } catch (_) {
      // A visual setting fetch never blocks chat or replaces the cached design.
    } finally {
      _refreshing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    _schedule();
    if (!_paused && _users > 0) refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class ChatDesignTextScaler extends TextScaler {
  const ChatDesignTextScaler(this.base, this.factor);
  final TextScaler base;
  final double factor;
  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;
  @override
  double get textScaleFactor => base.textScaleFactor * factor;
}

class _AppliedChatDesign extends InheritedWidget {
  const _AppliedChatDesign({required super.child});
  @override
  bool updateShouldNotify(_AppliedChatDesign oldWidget) => false;
}

mixin RemoteChatDesignState<T extends StatefulWidget> on State<T> {
  String get chatDesignApi;
  void _designChanged() {
    if (mounted) setState(() {});
  }

  void onRemoteChatDesignChanged(dynamic _) {
    ChatDesignStore.shared.refresh();
  }

  @override
  void initState() {
    super.initState();
    ChatDesignStore.shared.addListener(_designChanged);
    ChatDesignStore.shared.attach(chatDesignApi);
  }

  @override
  void dispose() {
    ChatDesignStore.shared.removeListener(_designChanged);
    ChatDesignStore.shared.detach();
    super.dispose();
  }

  Widget applyChatDesign(BuildContext context, WidgetBuilder builder) {
    if (context.dependOnInheritedWidgetOfExactType<_AppliedChatDesign>() !=
        null) {
      return Builder(builder: builder);
    }
    final media = MediaQuery.of(context);
    return MediaQuery(
        data: media.copyWith(
            textScaler: ChatDesignTextScaler(media.textScaler,
                ChatDesignStore.shared.value.number('textScale', 1))),
        child: _AppliedChatDesign(child: Builder(builder: builder)));
  }
}
