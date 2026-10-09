import 'package:flutter/material.dart';
import 'incoming_share.dart';

enum IncomingShareDestination { chat, listing, calendar }

Future<IncomingShareDestination?> chooseIncomingShareDestination(
    BuildContext context, Map<String, dynamic> share) {
  final calendar = incomingShareHasCalendar(share);
  final files = (share['files'] as List? ?? const []).whereType<Map>().toList();
  final text = share['text']?.toString().trim() ?? '';
  final canChat = files.any((file) => !isSharedCalendarFile(file)) ||
      (text.isNotEmpty && !text.toUpperCase().startsWith('BEGIN:VCALENDAR'));
  return showDialog<IncomingShareDestination>(
    context: context,
    builder: (dialogContext) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('מה לעשות עם התוכן ששיתפת?'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (calendar)
              ListTile(
                key: const ValueKey('incoming-share-calendar'),
                leading: const Icon(Icons.event_available_outlined),
                title: const Text('הוספה ליומן בתשובה'),
                subtitle: const Text('בדיקת פרטי האירוע ושמירה ביומן האישי'),
                onTap: () => Navigator.pop(
                    dialogContext, IncomingShareDestination.calendar),
              ),
            if (canChat)
              ListTile(
                key: const ValueKey('incoming-share-chat'),
                leading: const Icon(Icons.chat_outlined),
                title: const Text('שליחה לחבר או לקבוצה'),
                subtitle: const Text('בחירת נמענים ואישור שליחה'),
                onTap: () =>
                    Navigator.pop(dialogContext, IncomingShareDestination.chat),
              ),
            if (incomingShareCanCreateListing(share))
              ListTile(
                key: const ValueKey('incoming-share-listing'),
                leading: const Icon(Icons.post_add_outlined),
                title: const Text('מודעה חדשה עם התמונות'),
                subtitle:
                    Text('${files.length} תמונות בטיוטה, עם סריקה והעלאה ברקע'),
                onTap: () => Navigator.pop(
                    dialogContext, IncomingShareDestination.listing),
              ),
            if (!canChat && !calendar) const Text('לא נמצא תוכן נתמך לשיתוף'),
          ])),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('ביטול'))
        ],
      ),
    ),
  );
}
