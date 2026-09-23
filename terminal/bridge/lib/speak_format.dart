/// Turn model markdown / markup into text that TTS can read naturally.
library;

import 'package:comstar_bridge/tts.dart';

/// Collapse markdown syntax into speakable prose.
///
/// Idempotent on already-plain text. Keeps meaning; drops decoration the
/// voice would otherwise read aloud (`asterisk`, `hash`, `bracket`, URLs).
String formatForSpeech(String raw) {
  var t = raw.trim();
  if (t.isEmpty) return t;

  // Fenced code: speak a short placeholder (do not read the dump).
  t = t.replaceAllMapped(
    RegExp(r'```[\w+-]*\r?\n[\s\S]*?```', multiLine: true),
    (_) => ' Code omitted. ',
  );
  t = t.replaceAllMapped(
    RegExp(r'~~~[\w+-]*\r?\n[\s\S]*?~~~', multiLine: true),
    (_) => ' Code omitted. ',
  );

  // HTML tags (rare in AO replies).
  t = t.replaceAll(RegExp(r'<[^>]+>'), ' ');

  final lines = t.split(RegExp(r'\r?\n'));
  final out = <String>[];
  for (var line in lines) {
    var s = line.trim();
    if (s.isEmpty) {
      if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
      continue;
    }

    // Horizontal rules / table separators.
    if (RegExp(r'^[-*_]{3,}$').hasMatch(s)) continue;
    if (RegExp(r'^\|?[\s:-]+\|[\s|:-]*$').hasMatch(s)) continue;

    // ATX headings.
    s = s.replaceFirst(RegExp(r'^#{1,6}\s+'), '');

    // Blockquotes.
    s = s.replaceFirst(RegExp(r'^>\s?'), '');

    // Unordered / ordered list markers.
    s = s.replaceFirst(RegExp(r'^[-*+•]\s+'), '');
    s = s.replaceFirst(RegExp(r'^\d+[.)]\s+'), '');

    // Table row pipes → spaces.
    if (s.contains('|')) {
      s = s
          .replaceAll(RegExp(r'^\||\|$'), '')
          .split('|')
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .join(', ');
    }

    s = _inlineMarkdown(s);
    s = s.trim();
    if (s.isEmpty) continue;
    out.add(s);
  }

  var joined = out.join(' ');
  // Soft paragraph breaks (blank lines) → sentence pause.
  joined = joined.replaceAll(RegExp(r' \s+'), ' ');
  joined = joined.replaceAll(RegExp(r'\s{2,}'), ' ');

  // Bare URLs (after link text already extracted).
  joined = joined.replaceAll(
    RegExp(r'https?://[^\s)>\]]+', caseSensitive: false),
    ' ',
  );
  joined = joined.replaceAll(RegExp(r'\bwww\.[^\s)>\]]+', caseSensitive: false), ' ');

  // Leftover emphasis markers / stray backticks.
  joined = joined.replaceAll('`', '');
  joined = joined.replaceAll(RegExp(r'\*{1,3}'), '');
  joined = joined.replaceAll(RegExp(r'_{1,3}'), '');

  // Collapse whitespace; tidy punctuation spacing.
  joined = joined.replaceAll(RegExp(r'\s+'), ' ').trim();
  joined = joined.replaceAll(RegExp(r'\s+([,.;:!?])'), r'$1');
  joined = joined.replaceAll(RegExp(r'([.!?]){2,}'), r'$1');
  // Ensure list-ish fragments ending without punctuation get a pause.
  joined = joined.replaceAllMapped(
    RegExp(r'([a-zA-Z0-9)])\s+([A-Z])'),
    (m) => '${m[1]}. ${m[2]}',
  );

  return joined.trim();
}

String _inlineMarkdown(String s) {
  var t = s;
  // Images: ![alt](url) → alt
  t = t.replaceAllMapped(
    RegExp(r'!\[([^\]]*)\]\([^)]+\)'),
    (m) => (m[1] ?? '').trim(),
  );
  // Links: [text](url) → text
  t = t.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\([^)]+\)'),
    (m) => (m[1] ?? '').trim(),
  );
  // Reference links [text][id] → text
  t = t.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\[[^\]]*\]'),
    (m) => (m[1] ?? '').trim(),
  );
  // Bold / italic (order: *** then ** then * ; same for _).
  t = t.replaceAllMapped(
    RegExp(r'\*\*\*([^*]+)\*\*\*'),
    (m) => m[1] ?? '',
  );
  t = t.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m[1] ?? '');
  t = t.replaceAllMapped(RegExp(r'(?<!\w)\*([^*]+)\*(?!\w)'), (m) => m[1] ?? '');
  t = t.replaceAllMapped(RegExp(r'___([^_]+)___'), (m) => m[1] ?? '');
  t = t.replaceAllMapped(RegExp(r'__([^_]+)__'), (m) => m[1] ?? '');
  t = t.replaceAllMapped(RegExp(r'(?<!\w)_([^_]+)_(?!\w)'), (m) => m[1] ?? '');
  // Inline code
  t = t.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m[1] ?? '');
  // Strikethrough
  t = t.replaceAllMapped(RegExp(r'~~([^~]+)~~'), (m) => m[1] ?? '');
  return t;
}

/// Formats every utterance before the underlying [TtsEngine] synthesizes it.
class SpeakFormatTts implements TtsEngine {
  SpeakFormatTts(this.inner);

  final TtsEngine inner;

  @override
  Stream<TtsChunk> synthesize(String text) =>
      inner.synthesize(formatForSpeech(text));

  @override
  Future<String> synthesizeToFile(String text) =>
      inner.synthesizeToFile(formatForSpeech(text));
}

