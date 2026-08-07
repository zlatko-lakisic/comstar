/// Spoken intents for messaging-channel QR pairing (ADR 0015).
library;

enum ChannelIntentKind {
  connect,
  reconnect,
  cancel,
  unlink,
  status,
}

class ChannelIntent {
  const ChannelIntent(this.kind, this.provider);
  final ChannelIntentKind kind;

  /// `telegram` | `whatsapp` | `signal` | `any` (status/unlink all).
  final String provider;
}

/// Returns a [ChannelIntent] when [text] clearly asks about messaging links.
ChannelIntent? parseChannelIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;

  String? provider;
  if (RegExp(r'\b(telegram|tg)\b').hasMatch(t)) {
    provider = 'telegram';
  } else if (RegExp(r'\b(whats?app|wa)\b').hasMatch(t)) {
    provider = 'whatsapp';
  } else if (RegExp(r'\b(signal)\b').hasMatch(t)) {
    provider = 'signal';
  } else if (RegExp(
        r'\b(messaging|message channel|text channel|chat channel)\b',
      ).hasMatch(t)) {
    provider = 'any';
  }

  // Need a channel word, or generic "pair my phone to telegram"-style.
  if (provider == null) return null;

  if (RegExp(
        r'\b(cancel|stop|abort|never ?mind)\b.*\b'
        r'(connect|connecting|pairing|link|linking|telegram|whats?app|signal)\b|'
        r'\b(cancel|stop|abort) (the )?(connection|pairing)\b|'
        r'\bcancel (channel |telegram |whats?app |signal )?connect\b',
      ).hasMatch(t)) {
    return ChannelIntent(ChannelIntentKind.cancel, provider);
  }

  if (RegExp(
        r'\b(disconnect|unlink|forget|remove|revoke)(s|ed|ing)?\b|'
        r'\bunlink my (telegram|whats?app|signal|channel)\b',
      ).hasMatch(t)) {
    return ChannelIntent(ChannelIntentKind.unlink, provider);
  }

  if (RegExp(
        r'\b(are you|am i|is (it|my)|do you|have you|have i|did you)\b.'
        r'{0,40}\b(connect|connected|link|linked|pair|paired|ready)\b|'
        r'\b(telegram|whats?app|signal|channel) (status|connected|linked)\b|'
        r'\b(check|what.?s) (my )?(telegram|whats?app|signal|channel)\b',
      ).hasMatch(t)) {
    return ChannelIntent(ChannelIntentKind.status, provider);
  }

  if (RegExp(
        r'\b(re ?connect|re ?link|re ?pair|connect again|link again)\b',
      ).hasMatch(t)) {
    return ChannelIntent(ChannelIntentKind.reconnect, provider);
  }

  if (RegExp(
        r'\b(connect|link|pair|sign ?in|log ?in|authorize|auth)'
        r'(s|ing)?\b|'
        r'\b(telegram|whats?app|signal) (account|bot)\b',
      ).hasMatch(t)) {
    return ChannelIntent(ChannelIntentKind.connect, provider);
  }

  return null;
}
