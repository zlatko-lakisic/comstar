/// Read COMSTAR Agents Admin runtime + secrets for channel sessions.
///
/// Same on-disk layout as the bridge Agents store
/// (`~/.local/share/comstar/agents/`). Kept local so channel does not depend
/// on `comstar_bridge`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const kCuratedAgentIds = <String>[
  'gpt_research',
  'gpt_reason',
  'gpt_write',
  'claude_research',
  'claude_reason',
  'claude_write',
  'ollama_qwen2_5_14b_instruct',
];

String agentsStateDir() {
  final override = Platform.environment['COMSTAR_DATA_DIR']?.trim();
  final base = (override != null && override.isNotEmpty)
      ? override
      : p.join(
          Platform.environment['HOME'] ?? Directory.systemTemp.path,
          '.local',
          'share',
          'comstar',
        );
  return p.join(base, 'agents');
}

Future<Map<String, dynamic>> _readJson(String path) async {
  final file = File(path);
  if (!await file.exists()) return {};
  try {
    final raw = jsonDecode(await file.readAsString());
    if (raw is Map) return Map<String, dynamic>.from(raw);
  } on Object {
    // ignore
  }
  return {};
}

String? _envFirst(List<String> keys) {
  for (final k in keys) {
    final v = Platform.environment[k]?.trim();
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}

class ChannelAgentsPrefs {
  ChannelAgentsPrefs({String? stateDir})
      : stateDir = stateDir ?? agentsStateDir();

  final String stateDir;

  Future<bool> dynamicPlanning({bool yamlDefault = false}) async {
    final runtime = await _readJson(p.join(stateDir, 'runtime.json'));
    if (runtime['dynamic_planning'] is bool) {
      return runtime['dynamic_planning'] as bool;
    }
    final env = Platform.environment['COMSTAR_DYNAMIC_PLANNING']?.trim();
    if (env == '1' || env == 'true') return true;
    if (env == '0' || env == 'false') return false;
    return yamlDefault;
  }

  Future<String> defaultRunMode() async {
    final runtime = await _readJson(p.join(stateDir, 'runtime.json'));
    final mode = runtime['default_run_mode']?.toString().trim();
    if (mode != null && mode.isNotEmpty) return mode;
    return 'dynamic';
  }

  Future<List<String>> allowedAgentIds() async {
    final runtime = await _readJson(p.join(stateDir, 'runtime.json'));
    final secrets = await _readJson(p.join(stateDir, 'secrets.json'));
    final openai = (secrets['openai_api_key']?.toString().trim().isNotEmpty ==
            true)
        ? secrets['openai_api_key'].toString().trim()
        : _envFirst(const ['COMSTAR_OPENAI_API_KEY', 'OPENAI_API_KEY']);
    final anthropic = (secrets['anthropic_api_key']
                ?.toString()
                .trim()
                .isNotEmpty ==
            true)
        ? secrets['anthropic_api_key'].toString().trim()
        : _envFirst(const ['COMSTAR_ANTHROPIC_API_KEY', 'ANTHROPIC_API_KEY']);

    List<String> enabled = kCuratedAgentIds;
    final raw = runtime['enabled_agent_ids'];
    if (raw is List && raw.isNotEmpty) {
      enabled = [
        for (final e in raw)
          if (e != null && e.toString().trim().isNotEmpty) e.toString().trim(),
      ];
    }

    final out = <String>[];
    for (final id in enabled) {
      if (!kCuratedAgentIds.contains(id)) continue;
      if (id.startsWith('gpt_') && (openai == null || openai.isEmpty)) continue;
      if (id.startsWith('claude_') &&
          (anthropic == null || anthropic.isEmpty)) {
        continue;
      }
      out.add(id);
    }
    return out;
  }

  Future<Map<String, String>> sessionEnv() async {
    final secrets = await _readJson(p.join(stateDir, 'secrets.json'));
    final out = <String, String>{};
    final openai = (secrets['openai_api_key']?.toString().trim().isNotEmpty ==
            true)
        ? secrets['openai_api_key'].toString().trim()
        : _envFirst(const ['COMSTAR_OPENAI_API_KEY', 'OPENAI_API_KEY']);
    final anthropic = (secrets['anthropic_api_key']
                ?.toString()
                .trim()
                .isNotEmpty ==
            true)
        ? secrets['anthropic_api_key'].toString().trim()
        : _envFirst(const ['COMSTAR_ANTHROPIC_API_KEY', 'ANTHROPIC_API_KEY']);
    if (openai != null && openai.isNotEmpty) out['OPENAI_API_KEY'] = openai;
    if (anthropic != null && anthropic.isNotEmpty) {
      out['ANTHROPIC_API_KEY'] = anthropic;
    }
    return out;
  }
}

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

bool shouldUseDynamicChatForText({
  required bool dynamicPlanning,
  required String utterance,
}) {
  if (!dynamicPlanning) return false;
  return !looksLikeHomeControl(utterance);
}
