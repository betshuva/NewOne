import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:google_sign_in_web/google_sign_in_web.dart';

/// The real AuthScreen and GoogleWebSignInButton consume this plugin's stream.
/// Only the GIS transport/button is replaced; no production callback is called
/// directly, and no Google SDK/network/One Tap interaction runs in the fixture.
class GoogleAuthFixture {
  String idToken = 'selected-google-token';
  String email = 'selected@example.invalid';
  String name = 'Selected Google Account';
  final calls = <String>[];
  final _events = StreamController<GoogleSignInUserData?>.broadcast();
  GoogleSignInPlatform? _previous;

  int get choiceCount => calls.where((call) => call == 'choose').length;

  void install(WidgetTester tester) {
    _previous = GoogleSignInPlatform.instance;
    GoogleSignInPlatform.instance = _GooglePlugin(this, _events);
  }

  Future<void> choose(WidgetTester tester, {bool registration = false}) async {
    final button = find.byKey(const ValueKey('fixture-google-choice'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
  }

  void _chooseAccount() {
    calls.add('choose');
    _events.add(GoogleSignInUserData(
      id: 'google-$email',
      email: email,
      displayName: name,
      idToken: idToken,
    ));
  }

  Future<void> dispose() async {
    if (_previous != null) GoogleSignInPlatform.instance = _previous!;
    await _events.close();
  }
}

// The actual web_only renderer verifies this exact platform subtype.
class _GooglePlugin extends GoogleSignInPlugin {
  _GooglePlugin(this.fixture, StreamController<GoogleSignInUserData?> events)
      : super(
            debugOverrideLoader: true, debugOverrideUserDataController: events);

  final GoogleAuthFixture fixture;

  @override
  Future<void> initWithParams(SignInInitParameters params) async {
    fixture.calls.add('init');
  }

  @override
  Future<void> signOut() async {
    fixture.calls.add('signOut');
    fixture._events.add(null);
  }

  @override
  Future<GoogleSignInTokenData> getTokens(
      {required String email, bool? shouldRecoverAuth}) async {
    fixture.calls.add('getTokens');
    return GoogleSignInTokenData(
        idToken: fixture.idToken, accessToken: 'fixture-access');
  }

  @override
  Future<GoogleSignInUserData?> signIn() =>
      throw StateError('Web login must use the interactive credential stream');

  @override
  Future<GoogleSignInUserData?> signInSilently() =>
      throw StateError('Interactive login must not prompt One Tap');

  @override
  Widget renderButton({GSIButtonConfiguration? configuration}) => TextButton(
        key: const ValueKey('fixture-google-choice'),
        onPressed: fixture._chooseAccount,
        child: const Text('Choose Google fixture account'),
      );
}
