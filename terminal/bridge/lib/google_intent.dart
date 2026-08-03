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

  if (RegExp(
        r'\b(disconnect|unlink|forget|remove)\b.*\bgoogle\b|'
        r'\bgoogle\b.*\b(disconnect|unlink|forget|remove)\b|'
        r'\bunlink my (google|gmail|calendar|drive)\b',
      ).hasMatch(t)) {
    return const GoogleIntent(GoogleIntentKind.unlink);
  }

  if (RegExp(
        r'\b(is|am i)\b.*\bgoogle\b.*\b(connected|linked|paired)\b|'
        r'\b(google|gmail)\b.*\b(connected|linked|status)\b|'
        r'\b(do i have|have i)\b.*\bgoogle\b',
      ).hasMatch(t)) {
    return const GoogleIntent(GoogleIntentKind.status);
  }

  if (RegExp(
        r'\b(connect|link|pair|sign ?in|log ?in|authorize|auth)\b.*\b'
        r'(google|gmail|calendar|drive)\b|'
        r'\b(google|gmail)\b.*\b(connect|link|pair|sign ?in|log ?in)\b|'
        r'\bconnect my google\b|'
        r'\blink google\b|'
        r'\bgoogle (account|workspace)\b',
      ).hasMatch(t)) {
    return const GoogleIntent(GoogleIntentKind.connect);
  }

  return null;
}
