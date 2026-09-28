import 'package:flutter/material.dart';

/// Keeps the opening unread boundary stable after read receipts are refreshed.
class ChatHistoryController extends ScrollController {
  ChatHistoryController() : super(keepScrollOffset: false);

  bool _initialHistoryCaptured = false;
  String? _firstUnreadId;
  String? _historySince;
  String? _searchMessageId;

  void openSearchMessage(String? id, String? createdAt) {
    if (id == null || createdAt == null) return;
    _searchMessageId = id;
    _historySince = createdAt;
  }

  Map<String, String> get queryParameters =>
      _searchMessageId != null && _historySince != null
          ? {'historySince': _historySince!}
          : !_initialHistoryCaptured
              ? const {'initialUnread': '1'}
              : _historySince == null
                  ? const {}
                  : {'historySince': _historySince!};

  bool captureInitialHistory(List<Map<String, dynamic>> messages) {
    if (_initialHistoryCaptured) return false;
    _initialHistoryCaptured = true;
    if (messages.isNotEmpty) {
      _historySince = messages.first['createdAt']?.toString();
    }
    for (final message in messages) {
      if (message['isUnread'] == true && message['id'] != null) {
        _firstUnreadId = message['id'].toString();
        break;
      }
    }
    return true;
  }

  int anchorIndex(List<Map<String, dynamic>> messages) {
    final targetId = _searchMessageId ?? _firstUnreadId;
    final index = targetId == null
        ? -1
        : messages
            .indexWhere((message) => message['id']?.toString() == targetId);
    return index < 0 ? messages.length : index;
  }

  Key get viewportKey =>
      ValueKey(_searchMessageId ?? _firstUnreadId ?? 'latest-message');

  void scrollToLatest({bool force = false}) {
    if (!hasClients) return;
    if (!force && position.maxScrollExtent - position.pixels > 80) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (hasClients) {
        animateTo(position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }
}

/// Two lazy slivers grow above and below the opening message. This positions
/// variable-height messages without estimating offsets or loading every item.
class ChatHistoryList extends StatelessWidget {
  final ChatHistoryController controller;
  final int itemCount;
  final int anchorIndex;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsets padding;

  const ChatHistoryList(
      {super.key,
      required this.controller,
      required this.itemCount,
      required this.anchorIndex,
      required this.itemBuilder,
      this.padding = const EdgeInsets.all(10)});

  @override
  Widget build(BuildContext context) {
    const center = ValueKey('chat-history-center');
    final atLatest = anchorIndex == itemCount;
    return CustomScrollView(
      key: controller.viewportKey,
      controller: controller,
      center: center,
      anchor: atLatest ? 1 : 0,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding.left, padding.top, padding.right,
              atLatest ? padding.bottom : 0),
          sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
            (context, index) => itemBuilder(context, anchorIndex - 1 - index),
            childCount: anchorIndex,
          )),
        ),
        SliverPadding(
          key: center,
          padding: EdgeInsets.fromLTRB(
              padding.left, 0, padding.right, atLatest ? 0 : padding.bottom),
          sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
            (context, index) => itemBuilder(context, anchorIndex + index),
            childCount: itemCount - anchorIndex,
          )),
        ),
      ],
    );
  }
}
