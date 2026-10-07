import 'dart:async';
import 'dart:collection';

/// Reaction activity updates conversation metadata, never message history.
class MessageReactionActivity {
  const MessageReactionActivity({
    required this.eventId,
    required this.messageId,
    required this.kind,
    required this.targetId,
    required this.actorId,
    required this.actorName,
    required this.emoji,
    required this.createdAt,
    required this.removed,
  });

  final String eventId, messageId, kind, targetId, actorId, actorName;
  final String? emoji;
  final DateTime createdAt;
  final bool removed;

  static MessageReactionActivity? tryParse(dynamic value) {
    if (value is! Map) return null;
    String? string(String key) {
      final field = value[key];
      return field is String && field.trim().isNotEmpty ? field : null;
    }

    final eventId = string('eventId');
    final messageId = string('messageId');
    final kind = string('kind');
    final targetId = string('targetId');
    final actorId = string('actorId');
    final createdAt = DateTime.tryParse(string('createdAt') ?? '');
    final removed = value['removed'] == true;
    final emoji = string('emoji');
    if (eventId == null || messageId == null || targetId == null ||
        actorId == null || createdAt == null ||
        (kind != 'chat' && kind != 'group') ||
        (removed ? value['emoji'] != null : emoji == null)) {
      return null;
    }
    return MessageReactionActivity(
      eventId: eventId,
      messageId: messageId,
      kind: kind!,
      targetId: targetId,
      actorId: actorId,
      actorName: string('actorName') ?? '',
      emoji: emoji,
      createdAt: createdAt,
      removed: removed,
    );
  }

  bool shouldMarkRead({
    required String? currentUserId,
    required String conversationKind,
    required String conversationId,
    required bool active,
  }) => active && currentUserId != null && actorId != currentUserId &&
      kind == conversationKind && targetId == conversationId;
}

/// Bounded per-session deduplication also covers socket reconnect deliveries.
class MessageReactionEventDeduplicator {
  MessageReactionEventDeduplicator({this.capacity = 256})
      : assert(capacity > 0);
  final int capacity;
  final _seen = <String>{};
  final _order = Queue<String>();

  bool accept(MessageReactionActivity activity) {
    if (!_seen.add(activity.eventId)) return false;
    _order.addLast(activity.eventId);
    if (_order.length > capacity) _seen.remove(_order.removeFirst());
    return true;
  }
}

/// Keep unread activity pending while the route is covered or the app sleeps.
class MessageReactionReadTracker {
  MessageReactionReadTracker({
    required this.currentUserId,
    required this.kind,
    required this.targetId,
    required this.isActive,
    required this.markRead,
  });

  final String? currentUserId;
  final String kind, targetId;
  final bool Function() isActive;
  final Future<bool> Function() markRead;
  final _events = MessageReactionEventDeduplicator();
  bool _pending = false;
  bool _reading = false;
  bool _disposed = false;

  void handle(MessageReactionActivity activity) {
    if (_disposed || !activity.shouldMarkRead(
      currentUserId: currentUserId,
      conversationKind: kind,
      conversationId: targetId,
      active: true,
    ) || !_events.accept(activity)) return;
    _pending = true;
    unawaited(flush());
  }

  Future<void> flush() async {
    if (_disposed || _reading || !_pending || !isActive()) return;
    _reading = true;
    try {
      while (!_disposed && _pending && isActive()) {
        _pending = false;
        bool success;
        try { success = await markRead(); }
        catch (_) { success = false; }
        if (!success) {
          if (!_disposed) _pending = true;
          break;
        }
      }
    } finally {
      _reading = false;
    }
  }

  void dispose() {
    _disposed = true;
    _pending = false;
  }
}

String conversationReactionPreview(Map<String, dynamic> item,
    {bool includeActor = true}) {
  final emoji = item['last_message']?.toString() ?? '';
  if (!includeActor || emoji.isEmpty) return emoji;
  final actor = item['last_message_is_mine'] == true
      ? 'את/ה'
      : item['last_message_sender_name']?.toString().trim() ?? '';
  return actor.isEmpty ? emoji : '$actor: $emoji';
}
