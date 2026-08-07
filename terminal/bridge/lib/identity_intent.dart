/// Local identity / re-recognize intents (bridge-owned; no AO required).

class IdentityIntent {
  const IdentityIntent._(this.kind);

  final IdentityIntentKind kind;
}

enum IdentityIntentKind {
  /// Speak current cached identity (or force a fresh CPAI pass).
  whoAmI,

  /// Clear cache and force re-recognize.
  recognizeMe,
}

/// Returns an [IdentityIntent] for who-am-I / recognize-me phrases.
IdentityIntent? parseIdentityIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r"[^\w\s']"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;

  // who-am-I first so "do you know me" is not treated as a forced re-scan.
  if (RegExp(
        r"\b(who am i|who'?s? this|who do you (think|see) i am|"
        r"who do you see|what(?:'s| is) my name|"
        r'do you (know|recognize) me)\b',
      ).hasMatch(t) ||
      t == 'who am i') {
    return const IdentityIntent._(IdentityIntentKind.whoAmI);
  }

  if (RegExp(
        r'\b(recognize me|re[- ]?identify me|look at me again|'
        r'scan (my )?face)\b',
      ).hasMatch(t) ||
      t == 'recognize me') {
    return const IdentityIntent._(IdentityIntentKind.recognizeMe);
  }

  return null;
}
