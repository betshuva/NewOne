import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercises the real GoogleSignIn native method-channel implementation.
class GoogleAuthFixture {
  String idToken = 'selected-google-token';
  String email = 'selected@example.invalid';
  String name = 'Selected Google Account';
  final calls = <String>[];
  TargetPlatform? _previousPlatform;
  WidgetTester? _tester;
  static const _channel = MethodChannel('plugins.flutter.io/google_sign_in');

  int get choiceCount => calls.where((call) => call == 'signIn').length;

  void install(WidgetTester tester) {
    _tester = tester;
    _previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel,
        (call) async {
      calls.add(call.method);
      if (call.method == 'signIn') {
        return {
          'id': 'google-$email',
          'email': email,
          'displayName': name,
          'idToken': idToken,
        };
      }
      if (call.method == 'getTokens') {
        return {'idToken': idToken, 'accessToken': 'fixture-access'};
      }
      return null;
    });
  }

  Future<void> choose(WidgetTester tester, {bool registration = false}) async {
    final button = find
        .text(registration ? 'הרשמה באמצעות Google' : 'המשך עם Google')
        .last;
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
  }

  Future<void> dispose() async {
    _tester?.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = _previousPlatform;
  }
}
