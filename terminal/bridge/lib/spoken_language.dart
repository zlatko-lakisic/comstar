/// Spoken / chat reply language guard (qwen sometimes emits Thai/CJK).
library;

final _nonLatinScript = RegExp(
  r'[\u0E00-\u0E7F' // Thai
  r'\u3040-\u30FF' // Hiragana/Katakana
  r'\u3400-\u9FFF' // CJK
  r'\uAC00-\uD7AF' // Hangul
  r'\u0400-\u04FF' // Cyrillic
  r']',
);

/// True when [text] contains scripts COMSTAR must not speak/show as primary reply.
bool containsForbiddenScript(String text) => _nonLatinScript.hasMatch(text);

/// Ratio of forbidden-script code units to total non-whitespace (0–1).
double forbiddenScriptRatio(String text) {
  final chars = text.replaceAll(RegExp(r'\s+'), '');
  if (chars.isEmpty) return 0;
  var bad = 0;
  for (final r in chars.runes) {
    final s = String.fromCharCode(r);
    if (_nonLatinScript.hasMatch(s)) bad++;
  }
  return bad / chars.length;
}

/// True when enough of the reply is Thai/CJK/etc. to reject for hallway TTS.
bool shouldRejectForeignScriptReply(String text, {double threshold = 0.08}) {
  if (!containsForbiddenScript(text)) return false;
  // Any Thai/CJK in a short reply is enough; longer replies use ratio.
  if (text.trim().length < 80) return true;
  return forbiddenScriptRatio(text) >= threshold;
}
