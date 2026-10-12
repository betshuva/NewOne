import 'package:flutter/material.dart';

bool isEducationFormAnnouncement(Map<String, dynamic> message) =>
    (message['educationFormId']?.toString().trim() ?? '').isNotEmpty ||
    (message['text']?.toString().trimLeft() ?? '').startsWith('📋 ');

String educationFormMessageType(Map<String, dynamic> message) {
  final type = message['educationFormType']?.toString();
  if (const {'survey', 'approval', 'signature'}.contains(type)) return type!;
  final text = message['text']?.toString().trimLeft() ?? '';
  final heading = text.split('\n').first.replaceFirst(RegExp(r'^📋\s*'), '');
  if (heading.startsWith('סקר')) return 'survey';
  if (heading.startsWith('מסמך') || heading.startsWith('בקשת חתימה')) {
    return 'signature';
  }
  return 'approval';
}

String educationFormMessageKind(Map<String, dynamic> message) =>
    switch (educationFormMessageType(message)) {
      'survey' => 'סקר',
      'signature' => 'מסמך לחתימה',
      _ => 'אישור',
    };

String educationFormMessageTitle(Map<String, dynamic> message) {
  final title = message['educationFormTitle']?.toString().trim() ?? '';
  if (title.isNotEmpty) return title;
  final heading = (message['text']?.toString() ?? '')
      .trim()
      .split('\n')
      .first
      .replaceFirst(RegExp(r'^📋\s*'), '');
  final separator = heading.indexOf(':');
  if (separator != -1) {
    final legacyTitle = heading.substring(separator + 1).trim();
    if (legacyTitle.isNotEmpty) return legacyTitle;
  }
  return educationFormMessageKind(message);
}

/// A repeated announcement has its own send time, even for the same form.
DateTime? educationFormMessageSentAt(Map<String, dynamic> message) =>
    DateTime.tryParse(message['createdAt']?.toString() ?? '')?.toLocal();

String educationFormMessageSentDate(Map<String, dynamic> message) {
  final date = educationFormMessageSentAt(message);
  if (date == null) return '';
  return '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';
}

class EducationFormMessageCard extends StatelessWidget {
  const EducationFormMessageCard({
    super.key,
    required this.message,
    required this.onOpen,
    this.canManage = false,
  });

  final Map<String, dynamic> message;
  final VoidCallback onOpen;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    final type = educationFormMessageType(message);
    final title = educationFormMessageTitle(message);
    final kind = educationFormMessageKind(message);
    final (accent, icon, openingAction) = switch (type) {
      'survey' => (
          const Color(0xFF216CB1),
          Icons.poll_outlined,
          'פתח סקר',
        ),
      'signature' => (
          const Color(0xFF7250BF),
          Icons.draw_outlined,
          'פתח מסמך',
        ),
      _ => (
          const Color(0xFF147E76),
          Icons.fact_check_outlined,
          'פתח אישור',
        ),
    };
    final canOpen = message['educationIsRecipient'] != false || canManage;
    final action = canOpen ? openingAction : 'לנמענים שנבחרו';
    final response = message['educationResponseStatus']?.toString();
    final closed = message['educationFormStatus'] == 'closed';
    final (status, statusColor, statusIcon) = !canOpen
        ? ('לידיעה', const Color(0xFF617286), Icons.info_outline_rounded)
        : closed
            ? ('סגור', const Color(0xFF546477), Icons.lock_outline_rounded)
            : response == 'declined'
                ? ('לא אושר', const Color(0xFFB64150), Icons.close_rounded)
                : response == 'approved' || response == 'completed'
                    ? ('הושלם', const Color(0xFF287743), Icons.check_rounded)
                    : canManage && message['educationIsRecipient'] != true
                        ? ('לניהול', accent, Icons.tune_rounded)
                        : (
                            'ממתין לתשובתך',
                            const Color(0xFF976017),
                            Icons.hourglass_bottom_rounded,
                          );
    final sentAt = educationFormMessageSentAt(message);
    final date = educationFormMessageSentDate(message);
    final time = sentAt == null
        ? ''
        : '${sentAt.hour.toString().padLeft(2, '0')}:'
            '${sentAt.minute.toString().padLeft(2, '0')}';
    final borderRadius = BorderRadius.circular(18);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SizedBox(
          width: 380,
          child: Semantics(
            key: const ValueKey('education-message-access'),
            button: canOpen,
            enabled: canOpen,
            label: canOpen ? '$action: $title' : '$title, נשלח לנמענים שנבחרו',
            child: Material(
              color: Colors.transparent,
              borderRadius: borderRadius,
              clipBehavior: Clip.antiAlias,
              child: Ink(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: [
                      Color.alphaBlend(
                          accent.withValues(alpha: .1), Colors.white),
                      Colors.white,
                    ],
                  ),
                  borderRadius: borderRadius,
                  border: Border.all(color: accent.withValues(alpha: .18)),
                ),
                child: InkWell(
                  onTap: canOpen ? onOpen : null,
                  borderRadius: borderRadius,
                  child: Padding(
                    padding: const EdgeInsets.all(15),
                    child: LayoutBuilder(
                      builder: (context, constraints) => Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: .12),
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Icon(icon, color: accent, size: 25),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  kind,
                                  style: TextStyle(
                                    color: accent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            title,
                            key: const ValueKey('education-message-title'),
                            style: const TextStyle(
                              color: Color(0xFF23364B),
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              height: 1.4,
                            ),
                          ),
                          if (sentAt != null) ...[
                            const SizedBox(height: 9),
                            Wrap(
                              spacing: 12,
                              runSpacing: 5,
                              children: [
                                _metadata(
                                  Icons.calendar_today_outlined,
                                  'נשלח ב־$date',
                                  constraints.maxWidth,
                                ),
                                _metadata(
                                  Icons.schedule_rounded,
                                  time,
                                  constraints.maxWidth,
                                ),
                              ],
                            ),
                          ],
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Divider(
                              color: accent.withValues(alpha: .12),
                              height: 1,
                            ),
                          ),
                          Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 14,
                            runSpacing: 9,
                            children: [
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                    maxWidth: constraints.maxWidth),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        action,
                                        style: TextStyle(
                                          color: canOpen
                                              ? accent
                                              : const Color(0xFF617286),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    if (canOpen) ...[
                                      const SizedBox(width: 6),
                                      Icon(Icons.arrow_back_rounded,
                                          size: 17, color: accent),
                                    ],
                                  ],
                                ),
                              ),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                    maxWidth: constraints.maxWidth),
                                child: Container(
                                  key: const ValueKey(
                                      'education-message-status'),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 9, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: statusColor.withValues(alpha: .09),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(statusIcon,
                                          size: 14, color: statusColor),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          status,
                                          style: TextStyle(
                                            color: statusColor,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _metadata(IconData icon, String label, double maxWidth) =>
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: const Color(0xFF6C7C8D)),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF617286),
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      );
}
