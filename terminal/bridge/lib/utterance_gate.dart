import 'package:comstar_bridge/terminal_intent.dart';
import 'package:comstar_bridge/clock_intent.dart';
import 'package:comstar_bridge/identity_intent.dart';
import 'package:comstar_bridge/social_intent.dart';

/// Whether [text] looks like a real voice prompt worth sending to AO.
///
/// Drops Whisper fragments and ambient bleed while allowing short device
/// commands, clock/social check-ins, conversational replies to COMSTAR
/// questions, and clear questions/imperatives.
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
  if (parseIdentityIntent(collapsed) != null) return true;
  if (parseClockIntent(collapsed) != null) return true;
  if (parseSocialIntent(collapsed) != null) return true;

  final words = lower.split(' ').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return false;

  // Answers to COMSTAR check-ins ("is everything ok?", "how's it going?").
  if (_isConversationalReply(lower, words)) return true;

  // Exact micro-fragments that slip past the junk list (not valid replies).
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
    'i m sorry',
    'im sorry',
    'i am sorry',
    'sorry',
    'what',
    'who',
    'why',
    'how',
  };
  if (fragments.contains(lower)) return false;

  // Clear questions — allow short follow-ups ("which button", "what color").
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
  if (questionStarts.contains(words.first) && words.length >= 2) return true;

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
    'time',
    'date',
    'season',
  };
  final hasCue = words.any(cues.contains);
  if (!hasCue) return false;

  // Reject obvious non-addressed narrative ("and we are going to…").
  if (words.first == 'and' || words.first == 'so' || words.first == 'then') {
    return false;
  }

  return words.length >= 4;
}

bool _isConversationalReply(String lower, List<String> words) {
  const replies = {
    'yes',
    'yeah',
    'yep',
    'yup',
    'no',
    'nope',
    'nah',
    'sure',
    'ok',
    'okay',
    'fine',
    'good',
    'great',
    'alright',
    'all right',
    'maybe',
    'really',
    'right',
    'thanks',
    'thank you',
    'got it',
    'not really',
    'not bad',
    'all good',
    'doing fine',
    'doing good',
    'doing okay',
    'doing ok',
    'im fine',
    'i m fine',
    'i am fine',
    'im good',
    'i m good',
    'i am good',
    'im ok',
    'i m ok',
    'i am ok',
    'im okay',
    'i m okay',
    'i am okay',
    'im alright',
    'i m alright',
    'i am alright',
    'everything s fine',
    'everything is fine',
    'everything s ok',
    'everything is ok',
    'everything s okay',
    'everything is okay',
    'everything s good',
    'everything is good',
    'i m not fine',
    'im not fine',
    'i am not fine',
    'i m not ok',
    'im not ok',
    'no thanks',
    'yes please',
    'no thank you',
  };
  if (replies.contains(lower)) return true;

  // "yes everything is fine", "yeah i'm good", "no i'm not"
  if (words.length >= 2 &&
      const {'yes', 'yeah', 'yep', 'yup', 'no', 'nope', 'nah', 'sure', 'ok', 'okay'}
          .contains(words.first)) {
    return words.length <= 8;
  }

  // "i'm doing fine / okay / great"
  final joined = words.join(' ');
  if (RegExp(
        r'^(i m|im|i am) (doing )?(fine|good|ok|okay|alright|great|well)\b',
      ).hasMatch(joined) ||
      RegExp(
        r'^(i m|im|i am) not (fine|good|ok|okay|alright)\b',
      ).hasMatch(joined)) {
    return true;
  }

  return false;
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
