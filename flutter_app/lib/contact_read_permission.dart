import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:permission_handler/permission_handler.dart';

/// Android's contacts permission group includes WRITE_CONTACTS. Searching and
/// caching the address book only needs READ_CONTACTS, checked without a prompt.
class ContactReadPermission {
  static const _channel = MethodChannel('com.betshuva.app/contacts');
  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<PermissionStatus> get status async {
    if (_android) {
      try {
        final value = await _channel.invokeMethod<int>('readPermissionStatus');
        if (value != null) return PermissionStatus.values[value];
      } on MissingPluginException {
        // Compatibility for a native host without the contacts bridge.
      }
    }
    return Permission.contacts.status;
  }

  static Future<bool> get isGranted async => (await status).isGranted;

  static Future<bool> request() async {
    if (_android) {
      try {
        await _channel.invokeMethod<void>('markReadPermissionRequested');
      } on MissingPluginException {
        // Older hosts still support the existing readonly permission request.
      }
    }
    return FlutterContacts.requestPermission(readonly: true);
  }
}
