/// Wake-from-sleep phrase gate (CONTRACTS §8 — sleep exits on wake word only).
///
/// With force-wake (no openWakeWord model), energy alone is too loose; require
/// an STT transcript that clearly contains hey/hello comstar (with common
/// Whisper mis-hearings of "comstar").
bool isComstarWakePhrase(String text) {
  var t = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return false;

  // Normalize STT splits and near-miss spellings of "comstar".
  t = t
      .replaceAll(RegExp(r'\bcom\s+star\b'), 'comstar')
      .replaceAll(RegExp(r'\bcome\s+star\b'), 'comstar')
      .replaceAll(RegExp(r'\bcome\s+start\b'), 'comstar')
      .replaceAll(RegExp(r'\bcomes\s+the\s+star\b'), 'comstar')
      .replaceAll(RegExp(r'\bkomm\s+star\b'), 'comstar')
      .replaceAll(RegExp(r'\bcom\s*starr?\b'), 'comstar')
      // Live Pi Whisper: "Comestar", "Comster", "Kommstar", …
      .replaceAll(RegExp(r'\bcomestar\b'), 'comstar')
      .replaceAll(RegExp(r'\bcomester\b'), 'comstar')
      .replaceAll(RegExp(r'\bcomster\b'), 'comstar')
      .replaceAll(RegExp(r'\bcomstore\b'), 'comstar')
      .replaceAll(RegExp(r'\bkomm?starr?\b'), 'comstar')
      .replaceAll(RegExp(r'\bcumstarr?\b'), 'comstar')
      .replaceAll(RegExp(r'\bkomstarr?\b'), 'comstar');

  // "hey/hello … star" when Whisper drops "com" into "comes the star".
  if (RegExp(r'\b(hey|hello|hi)\b').hasMatch(t) &&
      RegExp(r'\b(comstar|star)\b').hasMatch(t) &&
      (t.contains('com') || t.contains('come') || t.contains('star'))) {
    // Narrow: hey + (comstar already normalized OR "come/comes … star")
    if (RegExp(r'\b(hey|hello|hi)\b.*\b(comstar|come|comes|com)\b.*\bstar\b')
            .hasMatch(t) ||
        RegExp(r'\b(hey|hello|hi)\s+comstar\b').hasMatch(t)) {
      return true;
    }
  }

  // Any token that looks like com*star* / com*ter (Whisper mangling).
  t = t.replaceAllMapped(RegExp(r'\b[a-z]+\b'), (m) {
    final w = m.group(0)!;
    if (_tokenLooksLikeComstar(w)) return 'comstar';
    return w;
  });

  if (RegExp(r'\b(hey|hello|hi)\s+comstar\b').hasMatch(t)) {
    return true;
  }
  // Force-wake already gated on speech energy; bare "comstar" is enough when
  // Whisper drops the hey/hello.
  if (RegExp(r'\bcomstar\b').hasMatch(t)) {
    return true;
  }
  return false;
}

bool _tokenLooksLikeComstar(String w) {
  if (w == 'comstar') return true;
  // comstar / comestar / comster / comstarr — start with com, length tight.
  if (w.length < 6 || w.length > 10) return false;
  if (!w.startsWith('com') && !w.startsWith('kom') && !w.startsWith('cum')) {
    return false;
  }
  if (w.contains('star') || w.contains('store')) return true;
  // "comster" — Whisper often drops the 'a'.
  if (w.endsWith('ster') ||
      w.endsWith('star') ||
      w.endsWith('starr') ||
      w.endsWith('store')) {
    return true;
  }
  return false;
}
