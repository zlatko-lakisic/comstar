/// Wake-from-sleep phrase gate (CONTRACTS §8 — sleep exits on wake word only).
///
/// With force-wake (no openWakeWord model), energy alone is too loose; require
/// an STT transcript that clearly contains hey/hello comstar.
bool isComstarWakePhrase(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return false;

  // Accept "hey comstar" / "hello comstar" with optional trailing words.
  if (RegExp(r'\b(hey|hello)\s+comstar\b').hasMatch(t)) {
    return true;
  }
  return false;
}
