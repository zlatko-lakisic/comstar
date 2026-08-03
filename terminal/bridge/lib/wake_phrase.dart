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

  // Normalize STT splits: "com star", "come star", "komm star".
  t = t
      .replaceAll(RegExp(r'\bcom\s+star\b'), 'comstar')
      .replaceAll(RegExp(r'\bcome\s+star\b'), 'comstar')
      .replaceAll(RegExp(r'\bkomm\s+star\b'), 'comstar')
      .replaceAll(RegExp(r'\bcom\s*starr?\b'), 'comstar');

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
