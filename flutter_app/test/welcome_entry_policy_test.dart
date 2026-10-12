import 'package:betshuva/welcome_entry_policy.dart';
import 'package:flutter_test/flutter_test.dart';

bool _show(String url,
        {bool web = true,
        bool token = false,
        int seen = 0,
        bool pending = false}) =>
    shouldShowWelcomeIntro(
        uri: Uri.parse(url),
        isWeb: web,
        hasToken: token,
        seenVersion: seen,
        hasPendingInvite: pending);

void main() {
  test('native first guest sees the optional intro once per content version',
      () {
    expect(_show('file:///app/main', web: false), isTrue);
    expect(
        _show('file:///app/main', web: false, seen: welcomeIntroductionVersion),
        isFalse);
    expect(
        _show('file:///app/main',
            web: false, seen: welcomeIntroductionVersion + 1),
        isFalse);
  });
  test('ordinary web entry goes directly to auth; app entry shows first intro',
      () {
    expect(_show('https://betshuva.com/betshuva-app/'), isFalse);
    expect(_show('https://betshuva.com/betshuva-app/?app=1'), isTrue);
    expect(
        _show('https://betshuva.com/betshuva-app/?app=1',
            seen: welcomeIntroductionVersion),
        isFalse);
  });
  test('explicit login and registration bypass introductory screens', () {
    for (final web in [true, false]) {
      for (final entry in ['login', 'register']) {
        expect(
            _show('https://betshuva.com/betshuva-app/?entry=$entry&app=1',
                web: web),
            isFalse);
      }
    }
    expect(
        welcomeEntryIntent(
            Uri.parse('https://example.org/?entry=register&invite=old')),
        WelcomeEntryIntent.register);
  });
  test('intro preview is explicit and can be reopened by a guest', () {
    expect(
        _show('https://betshuva.com/betshuva-app/?entry=intro',
            seen: welcomeIntroductionVersion),
        isTrue);
    expect(_show('https://betshuva.com/betshuva-app/?entry=intro', token: true),
        isFalse);
  });
  test('returning account also bypasses after an expired original token', () {
    expect(_show('https://betshuva.com/betshuva-app/?app=1', token: true),
        isFalse);
    expect(_show('file:///app/main', web: false, token: true), isFalse);
  });
  test('pending invitations bypass even when the query was removed', () {
    expect(_show('https://betshuva.com/betshuva-app/?app=1', pending: true),
        isFalse);
    expect(_show('file:///app/main', web: false, pending: true), isFalse);
  });
  test('dedicated and unknown query intents are never consumed by intro', () {
    for (final query in [
      'invite=old',
      'groupInvite=token',
      'verifiedEmail=user%40example.org',
      'screen=calendar',
      'screen=classification-stats',
      'backup=connected',
      'resetToken=token',
      'token=reset',
      'futureIntegration=value',
    ]) {
      expect(_show('https://betshuva.com/betshuva-app/?entry=intro&$query'),
          isFalse,
          reason: query);
    }
  });
  test('hash routes and external pages retain priority over preview', () {
    expect(_show('https://betshuva.com/betshuva-app/?entry=intro#/calendar'),
        isFalse);
    for (final path in [
      'reset-password',
      'terms',
      'privacy',
      'group-invite.html',
      'app/'
    ]) {
      expect(
          _show('https://betshuva.com/betshuva-app/$path?entry=intro'), isFalse,
          reason: path);
    }
  });
  test('duplicate or unknown entry values never force a guest tour', () {
    for (final query in [
      'entry=intro&entry=login',
      'entry=unknown&app=1',
      'app=0',
      'app=1&app=1',
    ]) {
      expect(_show('https://betshuva.com/betshuva-app/?$query'), isFalse,
          reason: query);
    }
    expect(
        welcomeEntryIntent(
            Uri.parse('https://example.org/?entry=register&entry=login')),
        WelcomeEntryIntent.automatic);
  });
}
