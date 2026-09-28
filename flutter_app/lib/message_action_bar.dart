import 'package:flutter/material.dart';
import 'message_reactions.dart';
import 'message_hover.dart';

class MessageActionBar extends StatelessWidget {
  final String api, token;
  final Map<String, dynamic> message;
  final ValueChanged<BuildContext> onOptions;
  const MessageActionBar(
      {super.key,
      required this.api,
      required this.token,
      required this.message,
      required this.onOptions});

  @override
  Widget build(BuildContext context) {
    return Builder(
        builder: (anchorContext) => IconButton(
              tooltip: 'אפשרויות הודעה',
              onPressed: () => onOptions(
                  MessageHover.objectContext(anchorContext) ?? anchorContext),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
              style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              icon: const Icon(Icons.more_vert, size: 18),
            ));
  }
}

class MessageReactionSummary extends StatelessWidget {
  const MessageReactionSummary(
      {super.key,
      required this.api,
      required this.token,
      required this.message});
  final String api, token;
  final Map<String, dynamic> message;
  @override
  Widget build(BuildContext context) => canReactToMessage(message)
      ? MessageReactions(
          api: api,
          token: token,
          messageId: message['id'].toString(),
          showAddButton: false)
      : const SizedBox.shrink();
}

bool canReactToMessage(Map<String, dynamic> message) {
  final id = message['id']?.toString() ?? '';
  return RegExp(
              r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
          .hasMatch(id) &&
      ![
        'uploading',
        'sending',
        'pending_scan',
        'rejected_scan',
        'failed',
        'blocked_content',
        'stopped_scan'
      ].contains(message['status']) &&
      message['outboxId'] == null &&
      message['isDeleted'] != true &&
      message['filterHidden'] != true;
}
