/// Local sleep / speaker-volume intents (bridge-owned; no AO MCP required).
///
/// Tunnelled `client.terminal` currently hangs AO tool loading on the Pi path,
/// so these phrases are handled before `directVoice`.
class TerminalIntent {
  const TerminalIntent._(this.kind, {this.delta, this.percent, this.muted});

  final TerminalIntentKind kind;
  final int? delta;
  final int? percent;
  final bool? muted;
}

enum TerminalIntentKind {
  sleepEnter,
  volumeMute,
  volumeUnmute,
  volumeUp,
  volumeDown,
  volumeSet,
  healthStatus,
  restartSelf,
  restartAudio,
  restartKiosk,
  rebootHost,
  healSelf,
}

/// Returns a [TerminalIntent] when [text] clearly asks for device control.
TerminalIntent? parseTerminalIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s%]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;

  if (RegExp(
        r'\b(go to sleep|put yourself to sleep|go sleep|night night|'
        r'sleep mode|enter sleep)\b',
      ).hasMatch(t) ||
      t == 'sleep' ||
      t == 'go to sleep') {
    return const TerminalIntent._(TerminalIntentKind.sleepEnter);
  }

  // Self-care before volume so "restart" is not swallowed by unrelated matches.
  if (RegExp(
        r"\b(heal yourself|fix yourself|run (a )?health check|"
        r'auto[- ]?heal|repair yourself)\b',
      ).hasMatch(t)) {
    return const TerminalIntent._(TerminalIntentKind.healSelf);
  }
  if (RegExp(
        r'\b(restart (the )?audio|restart (the )?mic|restart (the )?speaker)\b',
      ).hasMatch(t)) {
    return const TerminalIntent._(TerminalIntentKind.restartAudio);
  }
  if (RegExp(
        r'\b(restart (the )?kiosk|restart (the )?screen|restart (the )?display)\b',
      ).hasMatch(t)) {
    return const TerminalIntent._(TerminalIntentKind.restartKiosk);
  }
  // Full host reboot — distinct from bridge restart.
  if (RegExp(
        r'\b(full reboot|reboot (the )?(pi|terminal|system|host|computer|machine)|'
        r'reboot yourself|reboot comstar)\b',
      ).hasMatch(t) ||
      t == 'reboot') {
    return const TerminalIntent._(TerminalIntentKind.rebootHost);
  }
  if (RegExp(
        r'\b(restart yourself|restart (the )?bridge|restart comstar)\b',
      ).hasMatch(t)) {
    return const TerminalIntent._(TerminalIntentKind.restartSelf);
  }
  if (RegExp(
        r'\b(what s your health|whats your health|how s your health|'
        r'hows your health|are you healthy|system status|status check|'
        r'how are your systems|(check|report) (your )?health)\b',
      ).hasMatch(t) ||
      t == 'health check' ||
      t == 'your health') {
    return const TerminalIntent._(TerminalIntentKind.healthStatus);
  }

  if (RegExp(r'\b(unmute|un mute)\b').hasMatch(t)) {
    return const TerminalIntent._(TerminalIntentKind.volumeUnmute, muted: false);
  }
  if (RegExp(r'\b(mute yourself|mute the speaker|be quiet|silence)\b')
          .hasMatch(t) ||
      t == 'mute') {
    return const TerminalIntent._(TerminalIntentKind.volumeMute, muted: true);
  }

  final setMatch = RegExp(
    r'\b(?:set|volume)\s+(?:(?:the\s+)?volume\s+)?(?:to\s+)?(\d{1,3})\s*%?',
  ).firstMatch(t);
  if (setMatch != null &&
      RegExp(r'\b(volume|percent|loudness)\b').hasMatch(t)) {
    final p = int.tryParse(setMatch.group(1)!);
    if (p != null) {
      return TerminalIntent._(TerminalIntentKind.volumeSet, percent: p.clamp(0, 100));
    }
  }

  if (RegExp(
        r'\b(volume up|turn( it)? up|louder|increase volume)\b',
      ).hasMatch(t)) {
    return const TerminalIntent._(TerminalIntentKind.volumeUp, delta: 10);
  }
  if (RegExp(
        r'\b(volume down|turn( it)? down|quieter|softer|decrease volume)\b',
      ).hasMatch(t)) {
    return const TerminalIntent._(TerminalIntentKind.volumeDown, delta: -10);
  }

  return null;
}
