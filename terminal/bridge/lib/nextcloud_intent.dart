/// Spoken intents for Nextcloud pairing / unlink / status.
enum NextcloudIntentKind {
  connect,
  reconnect,
  cancel,
  unlink,
  status,
}

class NextcloudIntent {
  const NextcloudIntent(this.kind);
  final NextcloudIntentKind kind;
}

/// Returns a [NextcloudIntent] when [text] clearly asks about Nextcloud linking.
NextcloudIntent? parseNextcloudIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;
  if (!t.contains('nextcloud') &&
      !t.contains('next cloud') &&
      !RegExp(r'\bmy cloud\b').hasMatch(t)) {
    return null;
  }

  if (RegExp(
        r'\b(cancel|stop|abort|never ?mind)\b.*\b'
        r'(connect|connecting|pairing|nextcloud|link|linking|cloud)\b|'
        r'\b(cancel|stop|abort) (the )?(connection|pairing)\b|'
        r'\bcancel connect\b',
      ).hasMatch(t)) {
    return const NextcloudIntent(NextcloudIntentKind.cancel);
  }

  if (RegExp(
        r'\b(disconnect|unlink|forget|remove|revoke)(s|ed|ing)?\b|'
        r'\bunlink my (nextcloud|cloud)\b',
      ).hasMatch(t)) {
    return const NextcloudIntent(NextcloudIntentKind.unlink);
  }

  if (RegExp(
        r'\b(are you|am i|is (it|nextcloud)|do you|have you|have i|did you)\b.'
        r'{0,40}\b(connect|connected|link|linked|pair|paired|ready)\b|'
        r'\b(nextcloud|cloud)\b.{0,20}\b(connected|linked|status|ready)\b|'
        r'\b(do i have|have i)\b.*\b(nextcloud|cloud)\b|'
        r'\bnextcloud status\b|'
        r'\b(check|what.?s) (my )?(nextcloud|cloud)\b',
      ).hasMatch(t)) {
    return const NextcloudIntent(NextcloudIntentKind.status);
  }

  if (RegExp(
        r'\b(re ?connect|re ?link|re ?pair|connect again|link again)\b|'
        r'\b(nextcloud|cloud)\b.*\b(re ?connect|re ?link|again)\b',
      ).hasMatch(t)) {
    return const NextcloudIntent(NextcloudIntentKind.reconnect);
  }

  if (RegExp(
        r'\b(connect|link|pair|sign ?in|log ?in|authorize|auth)(s|ing)?\b|'
        r'\b(nextcloud|cloud) (account)\b',
      ).hasMatch(t)) {
    return const NextcloudIntent(NextcloudIntentKind.connect);
  }

  return null;
}
