import 'dart:async';

import 'package:betshuva/message_reaction_activity.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _payload({
  String eventId = 'event-1',
  String messageId = 'message-1',
  String kind = 'chat',
  String targetId = 'peer-1',
  String actorId = 'peer-1',
  String? emoji = '❤️',
  bool removed = false,
}) =>
    {
      'eventId': eventId,
      'messageId': messageId,
      'kind': kind,
      'targetId': targetId,
      'actorId': actorId,
      'actorName': 'אביב',
      'emoji': emoji,
      'removed': removed,
      'createdAt': '2026-10-07T18:42:10.123Z',
    };

MessageReactionActivity _activity({
  String eventId = 'event-1',
  String kind = 'chat',
  String targetId = 'peer-1',
  String actorId = 'peer-1',
}) =>
    MessageReactionActivity.tryParse(_payload(
        eventId: eventId, kind: kind, targetId: targetId, actorId: actorId))!;

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  for (final kind in ['chat', 'group']) {
    test('parses dedicated $kind reaction activity without altering Unicode',
        () {
      final parsed = MessageReactionActivity.tryParse(_payload(kind: kind))!;
      expect(parsed.eventId, 'event-1');
      expect(parsed.messageId, 'message-1');
      expect(parsed.kind, kind);
      expect(parsed.targetId, 'peer-1');
      expect(parsed.actorId, 'peer-1');
      expect(parsed.actorName, 'אביב');
      expect(parsed.emoji, '❤️');
      expect(parsed.removed, isFalse);
      expect(parsed.createdAt, DateTime.utc(2026, 10, 7, 18, 42, 10, 123));
    });
  }

  test('removal requires null emoji and permits unnamed actors', () {
    final payload = _payload(removed: true, emoji: null)..remove('actorName');
    final parsed = MessageReactionActivity.tryParse(payload)!;
    expect(parsed.removed, isTrue);
    expect(parsed.emoji, isNull);
    expect(parsed.actorName, '');
    expect(MessageReactionActivity.tryParse(_payload(removed: true)), isNull);
    expect(MessageReactionActivity.tryParse(_payload(emoji: null)), isNull);
  });

  test('malformed activity is ignored rather than changing unread state', () {
    final invalid = <dynamic>[
      null,
      'reaction',
      [],
      for (final key in [
        'eventId',
        'messageId',
        'kind',
        'targetId',
        'actorId',
        'createdAt'
      ])
        {..._payload(), key: null},
      {..._payload(), 'kind': 'listing'},
      {..._payload(), 'createdAt': 'not-a-date'},
      {..._payload(), 'targetId': '  '},
      {..._payload(), 'emoji': ''},
    ];
    for (final payload in invalid) {
      expect(MessageReactionActivity.tryParse(payload), isNull,
          reason: '$payload');
    }
  });

  test(
      'only another actor in the active matching conversation should mark read',
      () {
    final activity = _activity();
    bool eligible(
            {String? actor = 'me',
            String kind = 'chat',
            String target = 'peer-1',
            bool active = true}) =>
        activity.shouldMarkRead(
            currentUserId: actor,
            conversationKind: kind,
            conversationId: target,
            active: active);
    expect(eligible(), isTrue);
    expect(eligible(actor: null), isFalse);
    expect(eligible(actor: 'peer-1'), isFalse);
    expect(eligible(kind: 'group'), isFalse);
    expect(eligible(target: 'other-peer'), isFalse);
    expect(eligible(active: false), isFalse);
  });

  test('event deduplication is bounded and keeps reconnect duplicates out', () {
    final events = MessageReactionEventDeduplicator(capacity: 3);
    expect(events.accept(_activity(eventId: 'a')), isTrue);
    expect(events.accept(_activity(eventId: 'b')), isTrue);
    expect(events.accept(_activity(eventId: 'a')), isFalse);
    expect(events.accept(_activity(eventId: 'c')), isTrue);
    expect(events.accept(_activity(eventId: 'd')), isTrue);
    expect(events.accept(_activity(eventId: 'c')), isFalse);
    expect(events.accept(_activity(eventId: 'a')), isTrue);
  });

  test('inactive route keeps activity pending until active flush', () async {
    var active = false;
    var reads = 0;
    final tracker = MessageReactionReadTracker(
        currentUserId: 'me',
        kind: 'chat',
        targetId: 'peer-1',
        isActive: () => active,
        markRead: () async {
          reads++;
          return true;
        });
    tracker.handle(_activity());
    tracker.handle(_activity());
    await _turn();
    expect(reads, 0);
    active = true;
    await tracker.flush();
    expect(reads, 1);
    await tracker.flush();
    tracker.handle(_activity());
    await _turn();
    expect(reads, 1);
    tracker.dispose();
  });

  test('failed and throwing read attempts retain activity for retry', () async {
    var reads = 0;
    final tracker = MessageReactionReadTracker(
        currentUserId: 'me',
        kind: 'chat',
        targetId: 'peer-1',
        isActive: () => true,
        markRead: () async {
          reads++;
          if (reads == 1) return false;
          if (reads == 2) throw StateError('offline');
          return true;
        });
    tracker.handle(_activity());
    await _turn();
    expect(reads, 1);
    await tracker.flush();
    expect(reads, 2);
    await tracker.flush();
    expect(reads, 3);
    await tracker.flush();
    expect(reads, 3);
    tracker.dispose();
  });

  test('new activity during read waits and is marked by a second request',
      () async {
    final first = Completer<bool>();
    var reads = 0;
    final tracker = MessageReactionReadTracker(
        currentUserId: 'me',
        kind: 'chat',
        targetId: 'peer-1',
        isActive: () => true,
        markRead: () {
          reads++;
          return reads == 1 ? first.future : Future.value(true);
        });
    tracker.handle(_activity(eventId: 'first'));
    expect(reads, 1);
    tracker.handle(_activity(eventId: 'second'));
    tracker.handle(_activity(eventId: 'second'));
    await tracker.flush();
    expect(reads, 1);
    first.complete(true);
    await _turn();
    expect(reads, 2);
    await tracker.flush();
    expect(reads, 2);
    tracker.dispose();
  });

  test('covered route does not mark newer activity until returning to it',
      () async {
    final first = Completer<bool>();
    var active = true;
    var reads = 0;
    final tracker = MessageReactionReadTracker(
        currentUserId: 'me',
        kind: 'group',
        targetId: 'group-1',
        isActive: () => active,
        markRead: () {
          reads++;
          return reads == 1 ? first.future : Future.value(true);
        });
    tracker.handle(
        _activity(eventId: 'first', kind: 'group', targetId: 'group-1'));
    active = false;
    tracker.handle(
        _activity(eventId: 'second', kind: 'group', targetId: 'group-1'));
    first.complete(true);
    await _turn();
    expect(reads, 1);
    await tracker.flush();
    expect(reads, 1);
    active = true;
    await tracker.flush();
    expect(reads, 2);
    tracker.dispose();
  });

  test('wrong target, kind and own reactions never enqueue read requests',
      () async {
    var reads = 0;
    final tracker = MessageReactionReadTracker(
        currentUserId: 'me',
        kind: 'chat',
        targetId: 'peer-1',
        isActive: () => true,
        markRead: () async {
          reads++;
          return true;
        });
    tracker.handle(_activity(eventId: 'own', actorId: 'me'));
    tracker.handle(_activity(eventId: 'wrong-peer', targetId: 'peer-2'));
    tracker.handle(_activity(eventId: 'wrong-kind', kind: 'group'));
    await tracker.flush();
    expect(reads, 0);
    tracker.dispose();
  });

  test('dispose drops pending reads and stops a late completion from retrying',
      () async {
    var active = false;
    var reads = 0;
    final first = Completer<bool>();
    final tracker = MessageReactionReadTracker(
        currentUserId: 'me',
        kind: 'chat',
        targetId: 'peer-1',
        isActive: () => active,
        markRead: () {
          reads++;
          return first.future;
        });
    tracker.handle(_activity());
    expect(reads, 0);
    active = true;
    final flushing = tracker.flush();
    expect(reads, 1);
    tracker.handle(_activity(eventId: 'later'));
    tracker.dispose();
    first.complete(false);
    await flushing;
    tracker.handle(_activity(eventId: 'after-dispose'));
    await tracker.flush();
    expect(reads, 1);
  });

  test('reaction preview names actor once and preserves removed/unknown states',
      () {
    final row = {
      'last_message': '❤️',
      'last_message_sender_name': ' אביב ',
      'last_message_is_mine': false
    };
    expect(conversationReactionPreview(row), 'אביב: ❤️');
    expect(conversationReactionPreview(row, includeActor: false), '❤️');
    expect(conversationReactionPreview({...row, 'last_message_is_mine': true}),
        'את/ה: ❤️');
    expect(
        conversationReactionPreview({...row, 'last_message_sender_name': ''}),
        '❤️');
    expect(conversationReactionPreview({...row, 'last_message': ''}), '');
  });
}
