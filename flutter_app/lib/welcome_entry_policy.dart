const welcomeIntroductionVersion = 1;
const welcomeSeenVersionKey = 'welcome_intro_seen_version';

enum WelcomeEntryIntent { automatic, login, register, intro }

WelcomeEntryIntent welcomeEntryIntent(Uri uri) {
  final values = uri.queryParametersAll['entry'];
  if (values == null || values.length != 1) {
    return WelcomeEntryIntent.automatic;
  }
  return switch (values.single) {
    'login' => WelcomeEntryIntent.login,
    'register' => WelcomeEntryIntent.register,
    'intro' => WelcomeEntryIntent.intro,
    _ => WelcomeEntryIntent.automatic,
  };
}

/// Marketing and introductory screens must not consume an application intent.
/// Unknown query parameters are preserved for existing and future integrations.
bool hasDedicatedStartupIntent(Uri uri, {required bool isWeb}) {
  if (uri.fragment.isNotEmpty) return true;
  final query = uri.queryParametersAll;
  if (query.keys.any((key) => key != 'entry' && key != 'app')) return true;
  if (query.containsKey('app') &&
      (query['app']!.length != 1 || query['app']!.single != '1')) {
    return true;
  }
  if (query.containsKey('entry') &&
      (query['entry']!.length != 1 ||
          !{'login', 'register', 'intro'}.contains(query['entry']!.single))) {
    return true;
  }
  if (!isWeb) return false;
  return !{'/', '/index.html', '/betshuva-app/', '/betshuva-app/index.html'}
      .contains(uri.path);
}

bool shouldShowWelcomeIntro({
  required Uri uri,
  required bool isWeb,
  required bool hasToken,
  required int seenVersion,
  bool hasPendingInvite = false,
}) {
  if (hasToken ||
      hasPendingInvite ||
      hasDedicatedStartupIntent(uri, isWeb: isWeb)) {
    return false;
  }
  final intent = welcomeEntryIntent(uri);
  if (intent == WelcomeEntryIntent.login ||
      intent == WelcomeEntryIntent.register) {
    return false;
  }
  if (intent == WelcomeEntryIntent.intro) return true;
  if (seenVersion >= welcomeIntroductionVersion) return false;
  return !isWeb || uri.queryParameters['app'] == '1';
}
