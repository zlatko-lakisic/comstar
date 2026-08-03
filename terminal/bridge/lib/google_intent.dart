/// Spoken intents for Google Workspace pairing / unlink.
enum GoogleIntentKind { connect, unlink, status }

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

  // STT often emits "connects", "google's", etc.
  if (RegExp(
        r'\b(disconnect|unlink|forget|remove)(s|ed|ing)?\b.*\bgoog',
      ).hasMatch(t) ||
      RegExp(
        r'\bgoog\w*\b.*\b(disconnect|unlink|forget|remove)(s|ed|ing)?\b',
      ).hasMatch(t)) {
    return const GoogleIntent(GoogleIntentKind.unlink);
  }

  if (RegExp(
        r'\b(is|am i)\b.*\bgoog\w*\b.*\b(connected|linked|paired)\b|'
        r'\bgoog\w*\b.*\b(connected|linked|status)\b|'
        r'\b(do i have|have i)\b.*\bgoog',
      ).hasMatch(t)) {
    return const GoogleIntent(GoogleIntentKind.status);
  }

  // Match connect/link/pair (+ STT plurals) near google/gmail/calendar/drive.
  if (RegExp(
        r'\b(connect|link|pair|sign ?in|log ?in|authorize|auth)'
        r'(s|ed|ing)?\b.{0,24}\b(goog\w*|gmail|calendar|drive)\b|'
        r'\b(goog\w*|gmail)\b.{0,24}\b(connect|link|pair|sign ?in|log ?in)'
        r'(s|ed|ing)?\b|'
        r'\b(goog\w*|gmail) (account|workspace)\b',
      ).hasMatch(t)) {
    return const GoogleIntent(GoogleIntentKind.connect);
  }

  return null;
}
