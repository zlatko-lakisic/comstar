/// Spoken intents for Google Workspace pairing / unlink / status.
enum GoogleIntentKind {
  /// Start device-code pairing (skipped if already linked unless reconnect).
  connect,

  /// Force a new pairing even if tokens exist.
  reconnect,

  /// Cancel an in-progress pairing attempt.
  cancel,

  /// Remove stored tokens and deregister tools.
  unlink,

  /// Ask whether Google is linked / tools are ready.
  status,
}

class GoogleIntent {
  const GoogleIntent(this.kind);
  final GoogleIntentKind kind;
}

/// Returns a [GoogleIntent] when [text] clearly asks about Google linking.
GoogleIntent? parseGoogleIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;

  // Cancel in-progress pairing (before connect — "cancel connect").
  if (RegExp(
        r'\b(cancel|stop|abort|never ?mind)\b.*\b'
        r'(connect|connecting|pairing|google|link|linking)\b|'
        r'\b(cancel|stop|abort) (the )?(connection|pairing)\b|'
        r'\bcancel connect\b',
      ).hasMatch(t)) {
    return const GoogleIntent(GoogleIntentKind.cancel);
  }

  // Unlink / revoke (before status/connect).
  if (RegExp(
        r'\b(disconnect|unlink|forget|remove|revoke)(s|ed|ing)?\b.*\bgoog|'
        r'\bgoog\w*\b.*\b(disconnect|unlink|forget|remove|revoke)(s|ed|ing)?\b|'
        r'\bunlink my (google|gmail|calendar|drive)\b|'
        r'\brevoke (my )?google\b',
      ).hasMatch(t)) {
    return const GoogleIntent(GoogleIntentKind.unlink);
  }

  // Status / already-connected questions — must beat "connect(ed)".
  if (RegExp(
        r'\b(are you|am i|is (it|google|gmail)|do you|have you|have i|did you)\b.'
        r'{0,40}\b(connect|connected|link|linked|pair|paired|ready)\b|'
        r'\b(is|am i)\b.*\bgoog\w*\b.*\b(connected|linked|paired|ready)\b|'
        r'\bgoog\w*\b.{0,20}\b(connected|linked|status|ready)\b|'
        r'\b(do i have|have i)\b.*\bgoog|'
        r'\bgoogle status\b|'
        r'\b(check|what.?s) (my )?google\b',
      ).hasMatch(t)) {
    return const GoogleIntent(GoogleIntentKind.status);
  }

  // Explicit re-link.
  if (RegExp(
        r'\b(re ?connect|re ?link|re ?pair|connect again|link again)\b.*\b'
        r'(goog\w*|gmail)|'
        r'\b(goog\w*|gmail)\b.*\b(re ?connect|re ?link|again)\b',
      ).hasMatch(t)) {
    return const GoogleIntent(GoogleIntentKind.reconnect);
  }

  // Fresh connect — do NOT match "connected" / "linked" / "paired".
  if (RegExp(
        r'\b(connect|link|pair|sign ?in|log ?in|authorize|auth)'
        r'(s|ing)?\b.{0,24}\b(goog\w*|gmail|calendar|drive)\b|'
        r'\b(goog\w*|gmail)\b.{0,24}\b(connect|link|pair|sign ?in|log ?in)'
        r'(s|ing)?\b|'
        r'\b(goog\w*|gmail) (account|workspace)\b',
      ).hasMatch(t)) {
    return const GoogleIntent(GoogleIntentKind.connect);
  }

  return null;
}
