import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'calendar_import.dart';
import 'calendar_shared_link.dart';
import 'incoming_share.dart';
import 'incoming_share_destination.dart';
import 'shared_content.dart';

class IncomingDeliveryResult {
  final Set<int> completed;
  final bool cancelled;
  final Map<String, List<String>> deliveredTargets;
  const IncomingDeliveryResult(this.completed,
      {this.cancelled = false, this.deliveredTargets = const {}});
}

class IncomingActionResult {
  final String outcome;
  final List<String> completedPaths;
  final bool clearText;
  final bool clearCalendar;
  final Map<String, List<String>> deliveredTargets;
  const IncomingActionResult(this.outcome,
      {this.completedPaths = const [],
      this.clearText = false,
      this.clearCalendar = false,
      this.deliveredTargets = const {}});
}

String incomingDeliveryKey(Map<String, dynamic> message) => sha256
    .convert(utf8.encode(jsonEncode([
      message['localPath'],
      message['fileName'],
      message['fileType'],
      message['text'],
    ])))
    .toString();

Future<String> readIncomingText(XFile file) async {
  if (await file.length() > 1024 * 1024) {
    throw const FormatException('קובץ האירוע או איש הקשר גדול מדי (עד 1MB)');
  }
  return utf8
      .decode(await file.readAsBytes())
      .replaceFirst(RegExp(r'^\uFEFF'), '');
}

/// Every side effect stays behind a user choice and the originating account.
Future<IncomingActionResult> processIncomingShare(
  BuildContext context, {
  required Map<String, dynamic> share,
  required String api,
  required String token,
  required String accountId,
  required bool Function() canAct,
  required Future<IncomingDeliveryResult> Function(
          List<Map<String, dynamic>> messages, String? recipient)
      deliver,
  required Future<bool> Function(List<XFile> images) createListing,
  required Future<void> Function(String? recipient) openChat,
  required Future<Map<String, dynamic>?> Function() capture,
  Future<void> Function(List<Map<String, dynamic>> messages)? prepareMessages,
}) async {
  if (!context.mounted || !canAct()) return const IncomingActionResult('retry');
  final shortcut = share['targetShortcutId'];
  final recipient = incomingShareRecipient(shortcut, accountId);
  if (shortcut != null && recipient == null) {
    throw const FormatException('יעד השיתוף שייך לחשבון אחר');
  }
  switch (share['action']) {
    case 'newchat':
      await openChat(recipient);
      return IncomingActionResult(canAct() ? 'completed' : 'retry');
    case 'newlisting':
      final saved = await createListing(const []);
      return IncomingActionResult(saved && canAct() ? 'completed' : 'retry');
    case 'capture':
      final file = await capture();
      if (file == null) return const IncomingActionResult('cancelled');
      if (!context.mounted || !canAct()) {
        return const IncomingActionResult('retry');
      }
      final messages = [
        {
          'localPath': file['path'],
          'fileName': file['name'],
          'mimeType': file['mime'] ?? 'image/jpeg',
          'fileType': 'image',
          'sourcePath': file['path'],
        }
      ];
      await prepareMessages?.call(messages);
      if (!context.mounted || !canAct()) {
        return const IncomingActionResult('retry');
      }
      final result = await deliver(messages, recipient);
      if (result.cancelled) return const IncomingActionResult('cancelled');
      return IncomingActionResult(
          result.completed.contains(0) ? 'completed' : 'retry',
          deliveredTargets: result.deliveredTargets);
  }
  if (!context.mounted || !canAct()) return const IncomingActionResult('retry');
  final files = (share['files'] as List? ?? const []).whereType<Map>().toList();
  var destination = IncomingShareDestination.chat;
  if (incomingShareHasCalendar(share) || incomingShareCanCreateListing(share)) {
    final chosen = await chooseIncomingShareDestination(context, share);
    if (chosen == null) return const IncomingActionResult('cancelled');
    destination = chosen;
  }
  if (!context.mounted || !canAct()) return const IncomingActionResult('retry');
  if (destination == IncomingShareDestination.listing) {
    final saved = await createListing(files
        .map((f) => XFile(f['path'].toString(),
            name: f['name']?.toString(), mimeType: f['mime']?.toString()))
        .toList());
    // The listing owns its upload futures until every input file is read.
    return IncomingActionResult(saved && canAct() ? 'completed' : 'retry');
  }
  final completedPaths = <String>[];
  var clearText = false;
  var clearCalendar = false;
  if (destination == IncomingShareDestination.calendar) {
    final text = share['text']?.toString() ?? '';
    final rawCalendar =
        text.trimLeft().toUpperCase().startsWith('BEGIN:VCALENDAR');
    final calendarFiles = files.where(isSharedCalendarFile).toList();
    final calendarLink = parseSharedCalendarLink(text);
    IncomingActionResult partial() => IncomingActionResult('retry',
        completedPaths: completedPaths,
        clearText: clearText,
        clearCalendar: clearCalendar);
    try {
      // Some calendar apps provide both an ICS file and structured extras for
      // the same event. The ICS is the authoritative import in that case.
      if (rawCalendar) {
        if (!await openCalendarImport(context,
            api: api,
            token: token,
            rawText: text,
            canImport: canAct)) {
          return partial();
        }
        clearText = true;
      }
      for (final file in calendarFiles) {
        if (!context.mounted || !canAct()) return partial();
        final raw = await readIncomingText(XFile(file['path'].toString()));
        if (!context.mounted ||
            !canAct() ||
            !await openCalendarImport(context,
                api: api,
                token: token,
                rawText: raw,
                canImport: canAct)) {
          return partial();
        }
        completedPaths.add(file['path'].toString());
      }
      if (!rawCalendar &&
          calendarFiles.isEmpty &&
          (share['calendar'] is Map || calendarLink != null)) {
        if (!context.mounted || !canAct()) return partial();
        final draft = share['calendar'] is Map
            ? Map<String, dynamic>.from(share['calendar'] as Map)
            : calendarLink!;
        if (!await openCalendarDraft(context,
            api: api,
            token: token,
            draft: draft,
            canImport: canAct)) {
          return partial();
        }
        clearCalendar = share['calendar'] is Map;
        if (calendarLink != null) clearText = true;
      } else if (share['calendar'] is Map) {
        clearCalendar = true; // Already represented by the imported ICS.
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'ייבוא האירוע לא הושלם: ${error.toString().replaceFirst('FormatException: ', '')}')));
      }
      return partial(); // Preserve acknowledgements for earlier imports.
    }
    if (!context.mounted || !canAct()) return partial();
    final leftover =
        files.any((f) => !completedPaths.contains(f['path']?.toString())) ||
            (text.trim().isNotEmpty && !clearText) ||
            (share['calendar'] is Map && !clearCalendar);
    return IncomingActionResult(leftover ? 'retry' : 'completed',
        completedPaths: completedPaths,
        clearText: clearText,
        clearCalendar: clearCalendar);
  }
  final messages = <Map<String, dynamic>>[];
  final sourcePaths = <String?>[];
  final prepared = (share['preparedMessages'] as List?)
      ?.whereType<Map>()
      .map(Map<String, dynamic>.from)
      .toList();
  if (prepared != null && prepared.isNotEmpty) {
    for (final message in prepared) {
      messages.add(message);
      sourcePaths.add(message['sourcePath']?.toString());
    }
  } else {
    final originalText = share['text']?.toString().trim() ?? '';
    if (originalText.isNotEmpty &&
        !originalText.toUpperCase().startsWith('BEGIN:VCALENDAR')) {
      var text = originalText;
      final place = parseSharedPlace(text);
      if (place != null) text = place.toMessageText();
      final link = parseSharedLink(text);
      if (link != null && context.mounted) {
        final edited = await _reviewSharedText(
            context, text, share['subject']?.toString());
        if (edited == null) return const IncomingActionResult('cancelled');
        text = edited;
      }
      if (!context.mounted || !canAct()) {
        return const IncomingActionResult('retry');
      }
      messages.add({'text': text});
      sourcePaths.add(null);
    }
    for (final file in files) {
      if (!context.mounted || !canAct()) {
        return const IncomingActionResult('retry');
      }
      if (isSharedCalendarFile(file)) continue;
      if (isSharedContactFile(file)) {
        final contacts = parseSharedVCard(
            await readIncomingText(XFile(file['path'].toString())));
        if (contacts.isEmpty) {
          throw const FormatException('לא נמצאו פרטי איש קשר בקובץ');
        }
        for (final contact in contacts) {
          if (!context.mounted || !canAct()) {
            return const IncomingActionResult('retry');
          }
          final text = await selectContactDetails(context, contact);
          if (text == null) return const IncomingActionResult('retry');
          messages.add({'text': text});
          sourcePaths.add(file['path'].toString());
        }
      } else {
        final item = incomingShareMessages({
          'files': [file]
        }).firstOrNull;
        if (item != null) {
          messages.add(item);
          sourcePaths.add(file['path']?.toString());
        }
      }
    }
    for (var i = 0; i < messages.length; i++) {
      messages[i]['sourcePath'] = sourcePaths[i];
    }
    if (messages.length > 101) {
      throw const FormatException('אפשר לשתף עד 100 פריטים והודעת טקסט אחת. שתף פחות אנשי קשר בכל פעם');
    }
    if (messages.isNotEmpty) await prepareMessages?.call(messages);
  }
  if (!context.mounted || !canAct()) return const IncomingActionResult('retry');
  if (messages.isEmpty) {
    if (recipient != null && canAct()) {
      await openChat(recipient);
      return const IncomingActionResult('completed');
    }
    return const IncomingActionResult('retry');
  }
  if (messages.length > 101) {
    throw const FormatException(
        'אפשר לשתף עד 100 פריטים והודעת טקסט אחת. שתף פחות אנשי קשר בכל פעם');
  }
  final delivered = await deliver(messages, recipient);
  if (!context.mounted || !canAct()) return const IncomingActionResult('retry');
  if (delivered.cancelled) return const IncomingActionResult('cancelled');
  for (final path in sourcePaths.whereType<String>().toSet()) {
    if (sourcePaths
        .asMap()
        .entries
        .where((e) => e.value == path)
        .every((e) => delivered.completed.contains(e.key))) {
      completedPaths.add(path);
    }
  }
  clearText =
      sourcePaths.asMap().entries.where((e) => e.value == null).isNotEmpty &&
          sourcePaths
              .asMap()
              .entries
              .where((e) => e.value == null)
              .every((e) => delivered.completed.contains(e.key));
  final complete = delivered.completed.length == messages.length &&
      !files.any(isSharedCalendarFile) &&
      share['calendar'] is! Map;
  return IncomingActionResult(complete ? 'completed' : 'retry',
      completedPaths: completedPaths,
      clearText: clearText,
      deliveredTargets: delivered.deliveredTargets);
}

Future<String?> _reviewSharedText(
    BuildContext context, String text, String? title) async {
  final controller = TextEditingController(text: text);
  try {
    return await showDialog<String>(
        context: context,
        builder: (dialogContext) => Directionality(
              textDirection: TextDirection.rtl,
              child: AlertDialog(
                title: const Text('שיתוף קישור או מקום'),
                content: SizedBox(
                    width: 360,
                    child: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      if (title?.trim().isNotEmpty == true)
                        Text(title!,
                            maxLines: 3, overflow: TextOverflow.ellipsis),
                      TextField(
                          controller: controller,
                          minLines: 3,
                          maxLines: 6,
                          maxLength: 4000,
                          decoration:
                              const InputDecoration(labelText: 'התוכן שיישלח')),
                    ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('ביטול')),
                  FilledButton(
                      onPressed: () {
                        if (controller.text.trim().isNotEmpty) {
                          Navigator.pop(dialogContext, controller.text.trim());
                        }
                      },
                      child: const Text('בחירת נמענים')),
                ],
              ),
            ));
  } finally {
    controller.dispose();
  }
}
