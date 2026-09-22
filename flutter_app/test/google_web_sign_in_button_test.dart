import 'dart:async';

import 'package:betshuva/google_web_sign_in_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

class _Google extends GoogleSignIn {
  final events = StreamController<GoogleSignInAccount?>.broadcast();
  int resets = 0;
  bool failInitialization = false;

  @override
  Stream<GoogleSignInAccount?> get onCurrentUserChanged => events.stream;

  @override
  Future<GoogleSignInAccount?> signOut() async {
    resets++;
    if (failInitialization) throw StateError('SDK failed to load');
    events.add(null);
    return null;
  }

  @override
  Future<GoogleSignInAccount?> signInSilently({
    bool suppressErrors = true,
    bool reAuthenticate = false,
  }) =>
      throw StateError('Interactive login must not use One Tap');
}

class _Account implements GoogleSignInAccount {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Google google;

  setUp(() => google = _Google());
  tearDown(() => google.events.close());

  Widget app(Future<void> Function(GoogleSignInAccount) onSignedIn,
          {bool enabled = true}) =>
      MaterialApp(
        home: Scaffold(
          body: GoogleWebSignInButton(
            googleSignIn: google,
            onSignedIn: onSignedIn,
            enabled: enabled,
          ),
        ),
      );

  testWidgets('signed-out initialization waits for an interactive credential',
      (tester) async {
    final received = <GoogleSignInAccount>[];
    await tester.pumpWidget(app((account) async => received.add(account)));
    await tester.pumpAndSettle();
    expect(google.resets, 1);
    expect(received, isEmpty);
    google.events.add(null);
    await tester.pumpAndSettle();
    expect(received, isEmpty);
    final account = _Account();
    google.events.add(account);
    await tester.pumpAndSettle();
    expect(received, [account]);
    expect(google.resets, 2);
  });

  testWidgets(
      'does not submit duplicate credentials while a request is pending',
      (tester) async {
    final pending = Completer<void>();
    var requests = 0;
    await tester.pumpWidget(app((_) async {
      requests++;
      await pending.future;
    }));
    await tester.pumpAndSettle();
    final account = _Account();
    google.events.add(account);
    await tester.pump();
    google.events.add(account);
    await tester.pump();
    expect(requests, 1);
    pending.complete();
    await tester.pumpAndSettle();
    google.events.add(account);
    await tester.pumpAndSettle();
    expect(requests, 2);
  });

  testWidgets('disabled and disposed buttons do not submit credentials',
      (tester) async {
    var requests = 0;
    await tester.pumpWidget(app((_) async => requests++, enabled: false));
    await tester.pump();
    google.events.add(_Account());
    await tester.pump();
    expect(requests, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    google.events.add(_Account());
    await tester.pump();
    expect(requests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a covered login route ignores Google credentials',
      (tester) async {
    var requests = 0;
    await tester.pumpWidget(app((_) async => requests++));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(GoogleWebSignInButton));
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Another screen')),
    )));
    await tester.pumpAndSettle();
    google.events.add(_Account());
    await tester.pumpAndSettle();
    expect(requests, 0);
  });

  testWidgets('SDK loading failure offers retry without blocking email login',
      (tester) async {
    google.failInitialization = true;
    await tester.pumpWidget(app((_) async {}));
    await tester.pumpAndSettle();
    expect(find.text('טעינת Google נכשלה — נסה שוב'), findsOneWidget);
    google.failInitialization = false;
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(find.text('טעינת Google נכשלה — נסה שוב'), findsNothing);
    expect(google.resets, 2);
  });

  testWidgets('a failed login resets the account and permits another attempt',
      (tester) async {
    await tester.pumpWidget(app((_) async => throw StateError('Rejected')));
    await tester.pumpAndSettle();
    google.events.add(_Account());
    await tester.pumpAndSettle();
    expect(
        find.text('הכניסה עם Google נכשלה. אפשר לנסות שוב.'), findsOneWidget);
    expect(google.resets, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving during login does not update a disposed widget',
      (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(app((_) => pending.future));
    await tester.pumpAndSettle();
    google.events.add(_Account());
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(StateError('late failure'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
