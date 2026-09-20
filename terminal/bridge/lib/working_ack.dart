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
  final t = _normalizeUtterance(text);
  if (t.isEmpty) return false;
  return RegExp(
    r'\b(research|investigate|look (this|that|it) up|look up|'
    r'find out (about|what|how|why)|tell me about|explain|'
    r'what (is|are|was|were|s going|s happening)|whats going|whats happening|'
    r'how (does|do|did|can)|why (is|are|do|does)|'
    r'do some research|dig into|background on|'
    r'news|headlines|current events|in the world|going on in (the )?world)\b',
  ).hasMatch(t);
}

/// News / current-events phrasing that needs live `fetch_url`, not planner prose.
bool looksLikeNewsResearch(String text) {
  final t = _normalizeUtterance(text);
  if (t.isEmpty) return false;
  return RegExp(
    r'\b(news|headlines|current events|in the world|'
    r'going on in (the )?world|whats going on|whats happening|'
    r'what is going on|what is happening)\b',
  ).hasMatch(t);
}

/// Weather / forecast phrasing — pinned `weather_mcp`, never bolted onto news.
bool looksLikeWeatherResearch(String text) {
  final t = _normalizeUtterance(text);
  if (t.isEmpty) return false;
  if (looksLikeNewsResearch(t)) return false;
  return RegExp(
    r'\b(weather|forecast|temperature outside|how (hot|cold|warm) (is|will)|'
    r'(is it|will it) (going to )?(rain|snow|sunny|cloudy)|'
    r'chance of (rain|snow)|umbrella|humid outside)\b',
  ).hasMatch(t);
}

/// HTTPS sources seeded so AO's ollama+fetch_url fast-path can run.
/// Prefer RSS over HTML homepages — Reuters/AP/BBC HTML often 401/403 or CSS junk.
const kNewsFetchUrls = <String>[
  'https://feeds.bbci.co.uk/news/world/rss.xml',
  'https://feeds.bbci.co.uk/news/rss.xml',
  'https://www.npr.org/rss/rss.php?id=1001',
  'https://rss.nytimes.com/services/xml/rss/nyt/World.xml',
];

/// Direct-agent prompt: concrete URLs + anti-placeholder instructions.
String seedNewsFetchPrompt(String text) {
  final urls = kNewsFetchUrls.join('\n');
  return '${text.trim()}\n\n'
      'Call fetch_url / fetch on each RSS URL below. Read the <title> items from '
      'the feed XML and speak 3–5 real world headlines in short spoken English. '
      'Do not invent stories. Never invent bracket placeholders like '
      '[Description] or [Current temperature]. Do not answer weather unless '
      'asked. If every fetch fails, say you could not fetch the news.\n'
      '$urls';
}

/// Direct-agent prompt for weather_mcp (no news/RSS drift).
String seedWeatherPrompt(String text) {
  return '${text.trim()}\n\n'
      'Weather tools are attached (weather_mcp). Call them before answering. '
      'Speak a short spoken English summary of conditions and/or forecast. '
      'Do not invent temperatures. Do not fetch news or talk about world '
      'headlines unless asked. If tools fail, say you could not get weather.';
}

/// Steer Reach `chat` toward stock research agents + mandatory step MCP.
String steerDynamicResearchChat(String wrapped, String utterance) {
  if (!looksLikeResearch(utterance)) return wrapped;
  final urls = kNewsFetchUrls.map((u) => '  $u').join('\n');
  final steer = 'Planning constraints for this request:\n'
      '- Prefer agent_provider_id ollama_qwen2_5_14b_instruct (or gpt_research / '
      'claude_research only if listed). Never use client.greeter or '
      'client.phrase_bank for research/news.\n'
      '- Exactly one step for news/world questions. Do not add weather steps '
      'unless the user asked about weather.\n'
      '- Set rag_ids to [] on the plan and every step. Do not attach '
      'orchestrator_kb or any RAG source.\n'
      '- Every step MUST set mcp_providers: ["fetch_url"] (non-empty on the '
      'step object). Do not leave step mcps empty. Do not attach weather_mcp '
      'unless the user asked about weather.\n'
      '- Include these HTTPS URLs in the step topic so tools can run:\n'
      '$urls\n'
      '- Final answer: real headlines only; never invent [bracket] placeholders; '
      'if fetch fails, say you could not fetch news.\n'
      '- Produce a factual spoken English answer; do not only acknowledge.';
  if (wrapped.contains('Current request:')) {
    return '$steer\n\n$wrapped';
  }
  return '$steer\n\nCurrent request:\n${wrapped.trim()}';
}

String _normalizeUtterance(String text) {
  return text
      .toLowerCase()
      .replaceAll(RegExp(r"['\u2019]"), '')
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
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
