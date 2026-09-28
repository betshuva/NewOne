import 'moderation_user_reason.dart';
import 'package:flutter/material.dart';

String scanClassificationText(Object? value) {
  if (value is! Map) return 'לא נשמר סיווג';
  const labels = {
    'men': 'גברים',
    'women': 'נשים',
    'children': 'ילדים',
    'people': 'אנשים',
    'nonHumanImages': 'נוף או חפצים',
    'landscape': 'נוף או חפצים',
    'video': 'וידאו'
  };
  final detected = value['detectedCategories'];
  final categories =
      detected is List && detected.isNotEmpty ? detected : [value['category']];
  final names =
      categories.map((v) => labels[v]).whereType<String>().toSet().toList();
  if (value['uncertain'] == true) names.add('הסיווג אינו ודאי');
  return names.isEmpty ? 'לא נשמר סיווג' : names.join(', ');
}

String scanExplanation(Map<String, dynamic> message) {
  final status = message['status'] ?? message['moderation_status'];
  final blocked = ['rejected_scan', 'rejected'].contains(status);
  final pending =
      ['pending_scan', 'pending', 'uploading', 'stopped'].contains(status);
  final approved = ['sent', 'delivered', 'read', 'approved'].contains(status);
  final reason =
      (message['scanReason'] ?? message['scan_reason'] ?? '').toString().trim();
  if (blocked && isModestyBlockReason(reason)) return modestyImageMessage;
  if (blocked && isFilterBlockReason(reason)) {
    return '$filterOnlyMessage\nזוהו: ${scanClassificationText(message['classification'])}\n$reason\n$retainedFilterFileMessage';
  }
  final state = blocked
      ? 'נחסם'
      : pending
          ? 'הסריקה טרם אושרה'
          : approved
              ? 'אושר למסירה'
              : 'סיווג שמור';
  return 'מצב: $state\nזוהו: ${scanClassificationText(message['classification'])}\n'
      '${reason.isNotEmpty ? 'סיבה: $reason' : approved ? 'הקובץ אושר למסירה בהתאם לבדיקות המערכת ולסינון היעד. לא נשמר הסבר מפורט נוסף.' : 'לא נשמר הסבר מפורט נוסף.'}\n'
      'הסיווג אוטומטי ועלול לטעות.';
}

Future<void> showScanExplanation(
        BuildContext context, Map<String, dynamic> message) =>
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text(isFilterBlockReason(
                    (message['scanReason'] ?? message['scan_reason'])
                        ?.toString())
                ? 'פרטי הסינון'
                : 'פרטי הסריקה'),
            content: SingleChildScrollView(
                child: SelectableText(scanExplanation(message))),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('סגור'))
            ],
          )),
    );
