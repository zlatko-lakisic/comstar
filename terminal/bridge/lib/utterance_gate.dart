import 'package:comstar_bridge/terminal_intent.dart';

/// Whether [text] looks like a real voice prompt worth sending to AO.
///
/// Drops Whisper fragments, ambient bleed, and one-word noise while allowing
/// short device commands (`go to sleep`) and clear questions/imperatives.
bool isActionableUtterance(String text) {
  final raw = text.trim();
  if (raw.isEmpty) return false;

  // Collapse accidental STT doubles before judging.
  final collapsed = collapseRepeatedUtterance(raw);
  final lower = collapsed
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s?]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (lower.isEmpty) return false;

  if (parseTerminalIntent(collapsed) != null) return true;

  final words = lower.split(' ').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return false;

  // Exact micro-fragments that slip past the junk list.
  const fragments = {
    'i m',
    'im',
    'i am',
    'ah',
    'oh',
    'eh',
    'huh',
    'hey',
    'easy',
    'got this',
    'got it',
    'i m sorry',
    'im sorry',
    'i am sorry',
    'sorry',
    'what',
    'who',
    'why',
    'how',
    'really',
    'right',
    'sure',
    'maybe',
    'alright',
    'all right',
  };
  if (fragments.contains(lower)) return false;

  // Clear questions.
  if (collapsed.contains('?')) return words.length >= 2;
  const questionStarts = {
    'what',
    'whats',
    'who',
    'whos',
    'where',
    'wheres',
    'when',
    'why',
    'how',
    'which',
    'can',
    'could',
    'would',
    'will',
    'do',
    'does',
    'did',
    'is',
    'are',
    'am',
    'should',
    'may',
  };
  if (questionStarts.contains(words.first) && words.length >= 3) return true;

  // Imperative / assistant prompts.
  const commandStarts = {
    'check',
    'show',
    'tell',
    'list',
    'open',
    'play',
    'stop',
    'pause',
    'start',
    'set',
    'turn',
    'reconnect',
    'connect',
    'compose',
    'send',
    'read',
    'help',
    'find',
    'get',
    'give',
    'remind',
    'schedule',
    'cancel',
    'delete',
    'add',
    'create',
    'update',
    'please',
    'look',
    'search',
    'summarize',
    'summarise',
  };
  if (commandStarts.contains(words.first) && words.length >= 2) return true;

  // "who am i" / "what am i" style identity prompts.
  if (words.length >= 3 &&
      words[0] == 'who' &&
      words[1] == 'am' &&
      words[2] == 'i') {
    return true;
  }

  // Generic statements that are not prompts (TV bleed, unfinished thoughts).
  if (words.length < 3) return false;

  // Require at least one verb-ish / request cue for longer statements.
  const cues = {
    'my',
    'me',
    'i',
    'you',
    'comstar',
    'please',
    'email',
    'emails',
    'calendar',
    'torrent',
    'torrents',
    'download',
    'downloading',
    'movie',
    'movies',
    'light',
    'lights',
    'temperature',
    'weather',
    'google',
    'sleep',
  };
  final hasCue = words.any(cues.contains);
  if (!hasCue) return false;

  // Reject obvious non-addressed narrative ("and we are going to…").
  if (words.first == 'and' || words.first == 'so' || words.first == 'then') {
    return false;
  }

  return words.length >= 4;
}

/// If the transcript is the same phrase twice, keep one copy.
String collapseRepeatedUtterance(String text) {
  final t = text.trim();
  if (t.isEmpty) return t;

  // Prefer sentence-boundary doubles: "Foo? Foo?"
  final sentences = t
      .split(RegExp(r'(?<=[.?!])\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (sentences.length == 2 &&
      sentences[0].toLowerCase() == sentences[1].toLowerCase()) {
    return sentences[0];
  }

  // Space-separated doubles without relying on punctuation.
  final m = RegExp(r'^(.{12,}?)\s+\1\s*$', caseSensitive: false).firstMatch(t);
  if (m != null) {
    return m.group(1)!.trim();
  }
  return t;
}
