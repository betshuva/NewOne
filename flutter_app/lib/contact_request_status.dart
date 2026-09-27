import 'package:flutter/material.dart';

String? contactRequestStatus(dynamic value) {
  if (value == 'awaiting_contact_approval' || value == 'rejected_request') {
    return value as String;
  }
  return null;
}

class ContactRequestStatusBanner extends StatelessWidget {
  final String status;
  final String? reason;
  const ContactRequestStatusBanner({super.key, required this.status, this.reason});

  @override
  Widget build(BuildContext context) {
    final rejected = status == 'rejected_request';
    final label = rejected
        ? 'לא נשלח — ${reason ?? 'הנמען לא אישר את התוכן'}'
        : 'ממתין לאישור חברות — טרם נשלח. יישלח רק אם הנמען יתיר סוג תוכן זה.';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(label, textDirection: TextDirection.rtl,
        style: TextStyle(fontSize: 12, color: rejected ? Colors.red.shade700 : Colors.orange.shade900)),
    );
  }
}
