/// Hybrid voice/channel routing: home/tools → direct_agent; else dynamic chat.
library;

/// True when the utterance should stay on [client.voice_responder] / direct agent.
///
/// Specialty MCP attachments (Google, Nextcloud, LDAP, vision) always prefer
/// direct. Plain `home_assistant` defaults prefer direct only for home-control
/// phrasing; open-ended Q&A goes to dynamic planning when enabled.
bool preferDirectVoice({
  required String utterance,
  required List<String> mcpProviders,
}) {
  final specialty = mcpProviders.any(
    (id) =>
        id.startsWith('client.') ||
        id == 'ldap_directory' ||
        id == 'vision_comstar',
  );
  if (specialty) return true;
  return looksLikeHomeControl(utterance);
}

/// Home Assistant / premises control and status phrasing.
bool looksLikeHomeControl(String text) {
  final t = text.toLowerCase().trim();
  if (t.isEmpty) return false;
  return RegExp(
    r"\b("
    r"lights?|lamps?|switches?|dim(?:mer|ming)?|brighten|"
    r"locks?|unlock|deadbolt|"
    r"scenes?|scripts?|automations?|"
    r"thermostats?|climate|hvac|heat(?:ing)?|cool(?:ing)?|ac\b|air.?condition|"
    r"temperature|humidity|set (?:the )?temp|"
    r"irrigation|sprinklers?|watering|zones?|"
    r"covers?|blinds?|shades?|curtains?|garage|"
    r"turn (?:on|off|up|down)|switch (?:on|off)|open (?:the |my )?|close (?:the |my )?|"
    r"vacuum|media player|tv\b|volume|"
    r"home assistant|\bha\b|"
    r"who'?s?\s+home|anyone home|who is home|"
    r"front door|back door|alarm|security"
    r")\b",
  ).hasMatch(t);
}

/// Whether this turn should use Reach `chat` (dynamic) vs `direct_agent`.
bool shouldUseDynamicChat({
  required bool dynamicPlanning,
  required String voiceBackend,
  required String utterance,
  required List<String> mcpProviders,
}) {
  final backend = voiceBackend.trim().toLowerCase();
  if (backend == 'direct') return false;
  if (backend == 'dynamic') return dynamicPlanning;
  // hybrid
  if (!dynamicPlanning) return false;
  return !preferDirectVoice(utterance: utterance, mcpProviders: mcpProviders);
}

/// Channel path: home-control → direct text_responder; else dynamic when on.
bool shouldUseDynamicChatForText({
  required bool dynamicPlanning,
  required String voiceBackend,
  required String utterance,
}) {
  return shouldUseDynamicChat(
    dynamicPlanning: dynamicPlanning,
    voiceBackend: voiceBackend,
    utterance: utterance,
    mcpProviders: const [],
  );
}
