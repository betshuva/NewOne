import 'remote_card_notice.dart';
import 'package:flutter/material.dart';

const blockedVideoMessage = 'הסירטון נחסם';

/// User-facing result shared by rejected and stopped video scans.
class BlockedVideoNotice extends StatelessWidget {
  const BlockedVideoNotice({super.key, this.fileName});

  final String? fileName;

  @override
  Widget build(BuildContext context) => RemoteCardNotice(
      title: blockedVideoMessage,
      details: blockedVideoMessage,
      fileName: fileName,
      icon: Icons.block,
      compactSetting: 'compactBlockedMedia');
}
