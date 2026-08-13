// Helpers for long-turn spoken progress (working ack + result framing).

/// Whether to arm the working-ack timer for this AO voice call.
///
/// When [force] is true (dynamic/research turns), arm even without MCP tools.
/// When [workingAckOnTools] is true and [force] is false, providers must be
/// non-empty **and** the utterance must look like real tool/query work.
/// Casual conversation ("okay that's good to know") must not get a
/// "give me a minute" — HA is often attached by default even when no tools
/// will run.
bool shouldArmWorkingAck({
  required List<String> mcpProviders,
  required bool workingAckOnTools,
  required int workingAckMs,
  String? utterance,
  bool force = false,
}) {
  if (workingAckMs <= 0) return false;
  if (force) return true;
  if (workingAckOnTools && mcpProviders.isEmpty) return false;
  if (!looksLikeLongToolQuery(utterance ?? '')) return false;
  return true;
}

/// True when the resident is asking for tool-backed / long query work.
///
/// Conversation continuity and acknowledgements return false.
bool looksLikeLongToolQuery(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r"['\u2019]"), '')
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return false;

  // Pure conversational follow-ups / acknowledgements — never a "long query".
  if (_conversationalContinuity.hasMatch(t)) return false;

  return _toolHeavy.hasMatch(t) || looksLikeResearch(t);
}

/// Open-ended research / explain intents (dynamic planning / stock research).
bool looksLikeResearch(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r"['\u2019]"), '')
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return false;
  return RegExp(
    r'\b(research|investigate|look (this|that|it) up|look up|'
    r'find out (about|what|how|why)|tell me about|explain|'
    r'what (is|are|was|were)|how (does|do|did|can)|why (is|are|do|does)|'
    r'do some research|dig into|background on)\b',
  ).hasMatch(t);
}

final _conversationalContinuity = RegExp(
  r'^(ok|okay|k|yeah|yep|yup|sure|cool|nice|great|good|alright|all right|'
  r'thanks|thank you|thankyou|got it|sounds good|good to know|'
  r'(ok|okay) (thats|that is) good( to know)?|'
  r'thats good( to know)?|that is good( to know)?|'
  r'thats fine|that is fine|no problem|no worries|'
  r'i see|i understand|makes sense|noted|never ?mind|nm)$|'
  r'^(i )?(couldnt|could not|didnt|did not|dont) hear you\b.*$',
);

final _toolHeavy = RegExp(
  // Home / HA style.
  r'\b(light|lights|lamp|lamps|switch|switches|plug|outlet|climate|'
  r'thermostat|temperature|temp|humid|humidity|lock|unlock|garage|'
  r'blinds?|shades?|curtain|fan|heater|hvac|vacuum|media player|'
  r'turn (on|off)|switch (on|off)|set (the )?(temp|temperature|thermostat)|'
  r'dim|brighten|who s home|whos home|anyone home|who is home|'
  r'where is|wheres|is .+ (at )?home|home assistant|sensor)\b|'
  // Google / workspace.
  r'\b(google|gmail|calendar|g-?cal|drive|workspace|inbox|email|e-?mail|'
  r'meeting|appointments?|schedule|compose)\b|'
  // Nextcloud / home cloud.
  r'\b(nextcloud|next cloud|my cloud|nas (files?|notes?))\b|'
  // Explicit lookup / list / check queries.
  r'\b(look ?up|search|find|list|check|fetch|download|torrent|torrents|'
  r'what( s| is)? (on|in) my|how many|status of|report on)\b|'
  // Vision / directory / visitor history.
  r'\b(front door|camera|driveway|describe (the )?(view|scene)|'
  r'what do you see|who s outside|who is outside|'
  r'who was (in|at|on) (the |my )?(driveway|front door|door|camera)|'
  r'who were (in|at|on) (the |my )?driveway|visitors?( today)?|who came by|'
  r'last (time|seen)|when was .+ last seen|when did you last see|'
  r'ldap|directory|household roster|look up (the )?user)\b',
);

const _resultReadyFallback = 'I have what you asked for.';

/// Prepend a result-ready line when a working ack was spoken for this turn.
///
/// Skips the prefix when [reply] already starts with a similar framing phrase.
String prefixResultReady(String reply, {String? preface}) {
  final text = reply.trim();
  if (text.isEmpty) return text;
  final intro = (preface == null || preface.trim().isEmpty)
      ? _resultReadyFallback
      : preface.trim();

  final lower = text.toLowerCase();
  const alreadyFramed = [
    'i have what you asked',
    'i have the information',
    'i have that for you',
    "here's what i found",
    'here is what i found',
    'i found what you',
  ];
  for (final p in alreadyFramed) {
    if (lower.startsWith(p)) return text;
  }

  // Keep punctuation so TTS breathes between preface and answer.
  final sep = intro.endsWith('.') || intro.endsWith('!') || intro.endsWith('?')
      ? ' '
      : '. ';
  return '$intro$sep$text';
}
