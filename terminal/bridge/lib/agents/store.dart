/// Runtime allowlist + provider secrets for Reach dynamic planning.
library;

import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/agents/catalog.dart';
import 'package:comstar_bridge/config.dart';
import 'package:path/path.dart' as p;

String defaultAgentsStateDir() {
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

class AgentsRuntime {
  const AgentsRuntime({
    this.dynamicPlanning,
    this.defaultRunMode,
    this.enabledAgentIds,
    this.enabledMcpIds,
    this.enabledSkillIds,
  });

  final bool? dynamicPlanning;
  final String? defaultRunMode;
  final List<String>? enabledAgentIds;
  final List<String>? enabledMcpIds;
  final List<String>? enabledSkillIds;

  Map<String, dynamic> toJson() => {
        if (dynamicPlanning != null) 'dynamic_planning': dynamicPlanning,
        if (defaultRunMode != null && defaultRunMode!.isNotEmpty)
          'default_run_mode': defaultRunMode,
        if (enabledAgentIds != null) 'enabled_agent_ids': enabledAgentIds,
        if (enabledMcpIds != null) 'enabled_mcp_ids': enabledMcpIds,
        if (enabledSkillIds != null) 'enabled_skill_ids': enabledSkillIds,
      };

  factory AgentsRuntime.fromJson(Map<String, dynamic> map) {
    return AgentsRuntime(
      dynamicPlanning: map['dynamic_planning'] is bool
          ? map['dynamic_planning'] as bool
          : null,
      defaultRunMode: _optionalNonEmpty(map['default_run_mode']),
      enabledAgentIds: _stringList(map['enabled_agent_ids']),
      enabledMcpIds: _stringList(map['enabled_mcp_ids']),
      enabledSkillIds: _stringList(map['enabled_skill_ids']),
    );
  }
}

List<String>? _stringList(Object? raw) {
  if (raw is! List) return null;
  final ids = <String>[
    for (final e in raw)
      if (e != null && e.toString().trim().isNotEmpty) e.toString().trim(),
  ];
  return ids;
}

String? _optionalNonEmpty(Object? raw) {
  final s = raw?.toString().trim();
  if (s == null || s.isEmpty) return null;
  return s;
}

class AgentsSecrets {
  const AgentsSecrets({
    this.openaiApiKey,
    this.anthropicApiKey,
    this.env = const {},
  });

  final String? openaiApiKey;
  final String? anthropicApiKey;

  /// Extra catalog secrets keyed by env name (e.g. `TAVILY_API_KEY`).
  final Map<String, String> env;

  bool get hasOpenai => (openaiApiKey ?? '').trim().isNotEmpty;
  bool get hasAnthropic => (anthropicApiKey ?? '').trim().isNotEmpty;

  Map<String, dynamic> toJson() {
    final out = <String, dynamic>{
      if (hasOpenai) 'openai_api_key': openaiApiKey!.trim(),
      if (hasAnthropic) 'anthropic_api_key': anthropicApiKey!.trim(),
    };
    final cleaned = <String, String>{};
    for (final e in env.entries) {
      final k = e.key.trim();
      final v = e.value.trim();
      if (k.isEmpty || v.isEmpty) continue;
      if (k == 'OPENAI_API_KEY' || k == 'ANTHROPIC_API_KEY') continue;
      if (k == 'openai_api_key' || k == 'anthropic_api_key') continue;
      cleaned[k] = v;
    }
    if (cleaned.isNotEmpty) out['env'] = cleaned;
    return out;
  }

  factory AgentsSecrets.fromJson(Map<String, dynamic> map) {
    final o = map['openai_api_key']?.toString();
    final a = map['anthropic_api_key']?.toString();
    final env = <String, String>{};
    final rawEnv = map['env'];
    if (rawEnv is Map) {
      for (final e in rawEnv.entries) {
        final k = e.key.toString().trim();
        final v = e.value?.toString().trim() ?? '';
        if (k.isNotEmpty && v.isNotEmpty) env[k] = v;
      }
    }
    // Also accept top-level env-style keys (except the known aliases).
    for (final e in map.entries) {
      final k = e.key.toString();
      if (k == 'openai_api_key' ||
          k == 'anthropic_api_key' ||
          k == 'env') {
        continue;
      }
      final v = e.value?.toString().trim() ?? '';
      if (k.isNotEmpty && v.isNotEmpty) env[k] = v;
    }
    return AgentsSecrets(
      openaiApiKey: (o != null && o.trim().isNotEmpty) ? o.trim() : null,
      anthropicApiKey: (a != null && a.trim().isNotEmpty) ? a.trim() : null,
      env: env,
    );
  }

  AgentsSecrets copyWith({
    String? openaiApiKey,
    String? anthropicApiKey,
    Map<String, String>? env,
    bool clearOpenai = false,
    bool clearAnthropic = false,
  }) {
    return AgentsSecrets(
      openaiApiKey: clearOpenai
          ? null
          : (openaiApiKey ?? this.openaiApiKey),
      anthropicApiKey: clearAnthropic
          ? null
          : (anthropicApiKey ?? this.anthropicApiKey),
      env: env ?? this.env,
    );
  }

  String? valueFor(String name) {
    final n = name.trim();
    if (n.isEmpty) return null;
    if (n == 'OPENAI_API_KEY' || n == 'openai_api_key') {
      return hasOpenai ? openaiApiKey!.trim() : null;
    }
    if (n == 'ANTHROPIC_API_KEY' || n == 'anthropic_api_key') {
      return hasAnthropic ? anthropicApiKey!.trim() : null;
    }
    final v = env[n]?.trim();
    return (v != null && v.isNotEmpty) ? v : null;
  }
}

class AgentsStore {
  AgentsStore({String? stateDir}) : stateDir = stateDir ?? defaultAgentsStateDir();

  final String stateDir;

  /// Set when configure/set_secrets/clear_secret write disk; cleared by [apply].
  bool needsSessionRefresh = false;

  /// Last provider key probe in this process (`null` = not tested yet).
  bool? openaiKeyValid;
  bool? anthropicKeyValid;

  String get runtimePath => p.join(stateDir, 'runtime.json');
  String get secretsPath => p.join(stateDir, 'secrets.json');

  Future<void> ensureDir() async {
    await Directory(stateDir).create(recursive: true);
  }

  Future<AgentsRuntime> loadRuntime() async {
    final file = File(runtimePath);
    if (!await file.exists()) return const AgentsRuntime();
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map) {
        return AgentsRuntime.fromJson(Map<String, dynamic>.from(raw));
      }
    } on Object {
      // ignore corrupt overlay
    }
    return const AgentsRuntime();
  }

  Future<void> saveRuntime(AgentsRuntime runtime) async {
    await ensureDir();
    final file = File(runtimePath);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(runtime.toJson()),
      flush: true,
    );
    needsSessionRefresh = true;
  }

  Future<AgentsSecrets> loadSecrets() async {
    final file = File(secretsPath);
    if (!await file.exists()) return const AgentsSecrets();
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map) {
        return AgentsSecrets.fromJson(Map<String, dynamic>.from(raw));
      }
    } on Object {
      // ignore
    }
    return const AgentsSecrets();
  }

  Future<void> saveSecrets(AgentsSecrets secrets) async {
    await ensureDir();
    final file = File(secretsPath);
    await file.writeAsString(jsonEncode(secrets.toJson()), flush: true);
    try {
      await Process.run('chmod', ['600', secretsPath]);
    } on Object {
      // best-effort on Windows / non-posix
    }
    needsSessionRefresh = true;
  }

  /// Probe OpenAI or Anthropic with the stored/env key, or an optional typed value.
  Future<Map<String, dynamic>> testSecret(
    String provider, {
    String? openaiApiKey,
    String? anthropicApiKey,
  }) async {
    final p = provider.trim().toLowerCase();
    if (p != 'openai' && p != 'anthropic') {
      throw ArgumentError('provider must be openai or anthropic');
    }
    final typed = p == 'openai'
        ? openaiApiKey?.trim()
        : anthropicApiKey?.trim();
    final key = (typed != null && typed.isNotEmpty)
        ? typed
        : (p == 'openai'
            ? await resolvedOpenaiKey()
            : await resolvedAnthropicKey());
    if (key == null || key.isEmpty) {
      if (p == 'openai') {
        openaiKeyValid = false;
      } else {
        anthropicKeyValid = false;
      }
      return {
        'ok': true,
        'provider': p,
        'valid': false,
        'error': 'not_configured',
      };
    }
    final result = p == 'openai'
        ? await _probeOpenai(key)
        : await _probeAnthropic(key);
    if (p == 'openai') {
      openaiKeyValid = result['valid'] == true;
    } else {
      anthropicKeyValid = result['valid'] == true;
    }
    return result;
  }

  static Future<Map<String, dynamic>> _probeOpenai(String key) async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse('https://api.openai.com/v1/models'))
          .timeout(const Duration(seconds: 12));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      final res = await req.close().timeout(const Duration(seconds: 12));
      await res.drain<void>();
      final valid = res.statusCode >= 200 && res.statusCode < 300;
      return {
        'ok': true,
        'provider': 'openai',
        'valid': valid,
        if (!valid) 'error': 'http_${res.statusCode}',
      };
    } on Object catch (e) {
      return {
        'ok': true,
        'provider': 'openai',
        'valid': false,
        'error': e.toString(),
      };
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> _probeAnthropic(String key) async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse('https://api.anthropic.com/v1/models'))
          .timeout(const Duration(seconds: 12));
      req.headers.set('x-api-key', key);
      req.headers.set('anthropic-version', '2023-06-01');
      final res = await req.close().timeout(const Duration(seconds: 12));
      await res.drain<void>();
      final valid = res.statusCode >= 200 && res.statusCode < 300;
      return {
        'ok': true,
        'provider': 'anthropic',
        'valid': valid,
        if (!valid) 'error': 'http_${res.statusCode}',
      };
    } on Object catch (e) {
      return {
        'ok': true,
        'provider': 'anthropic',
        'valid': false,
        'error': e.toString(),
      };
    } finally {
      client.close(force: true);
    }
  }

  Future<AgentsRuntime> configure({
    bool? dynamicPlanning,
    String? defaultRunMode,
    List<String>? enabledAgentIds,
    List<String>? enabledMcpIds,
    List<String>? enabledSkillIds,
  }) async {
    final cur = await loadRuntime();
    final next = AgentsRuntime(
      dynamicPlanning: dynamicPlanning ?? cur.dynamicPlanning,
      defaultRunMode: defaultRunMode ?? cur.defaultRunMode,
      enabledAgentIds: enabledAgentIds ?? cur.enabledAgentIds,
      enabledMcpIds: enabledMcpIds ?? cur.enabledMcpIds,
      enabledSkillIds: enabledSkillIds ?? cur.enabledSkillIds,
    );
    await saveRuntime(next);
    return next;
  }

  Future<AgentsSecrets> setSecrets({
    String? openaiApiKey,
    String? anthropicApiKey,
    Map<String, String>? env,
  }) async {
    final cur = await loadSecrets();
    var next = cur;
    final o = openaiApiKey?.trim();
    final a = anthropicApiKey?.trim();
    if (o != null && o.isNotEmpty) {
      next = next.copyWith(openaiApiKey: o);
      openaiKeyValid = null;
    }
    if (a != null && a.isNotEmpty) {
      next = next.copyWith(anthropicApiKey: a);
      anthropicKeyValid = null;
    }
    if (env != null && env.isNotEmpty) {
      final merged = Map<String, String>.from(next.env);
      for (final e in env.entries) {
        final k = e.key.trim();
        final v = e.value.trim();
        if (k.isEmpty) continue;
        if (v.isEmpty) continue;
        if (k == 'OPENAI_API_KEY' || k == 'openai_api_key') {
          next = next.copyWith(openaiApiKey: v);
          openaiKeyValid = null;
          continue;
        }
        if (k == 'ANTHROPIC_API_KEY' || k == 'anthropic_api_key') {
          next = next.copyWith(anthropicApiKey: v);
          anthropicKeyValid = null;
          continue;
        }
        merged[k] = v;
      }
      next = next.copyWith(env: merged);
    }
    await saveSecrets(next);
    return next;
  }

  Future<AgentsSecrets> clearSecret(String provider, {String? name}) async {
    final cur = await loadSecrets();
    final p = provider.trim().toLowerCase();
    final n = name?.trim() ?? '';
    if (n.isNotEmpty && p.isEmpty) {
      if (n == 'OPENAI_API_KEY' || n == 'openai_api_key') {
        openaiKeyValid = null;
        final next = cur.copyWith(clearOpenai: true);
        await saveSecrets(next);
        return next;
      }
      if (n == 'ANTHROPIC_API_KEY' || n == 'anthropic_api_key') {
        anthropicKeyValid = null;
        final next = cur.copyWith(clearAnthropic: true);
        await saveSecrets(next);
        return next;
      }
      final merged = Map<String, String>.from(cur.env)..remove(n);
      final next = cur.copyWith(env: merged);
      await saveSecrets(next);
      return next;
    }
    final next = switch (p) {
      'openai' => cur.copyWith(clearOpenai: true),
      'anthropic' => cur.copyWith(clearAnthropic: true),
      _ => throw ArgumentError('provider must be openai or anthropic (or pass name)'),
    };
    if (p == 'openai') openaiKeyValid = null;
    if (p == 'anthropic') anthropicKeyValid = null;
    await saveSecrets(next);
    return next;
  }

  void markApplied() {
    needsSessionRefresh = false;
  }

  /// Resolved OpenAI key: Admin secret, then env.
  Future<String?> resolvedOpenaiKey([AgentsSecrets? secrets]) async {
    final s = secrets ?? await loadSecrets();
    if (s.hasOpenai) return s.openaiApiKey!.trim();
    return _envFirst(const [
      'COMSTAR_OPENAI_API_KEY',
      'OPENAI_API_KEY',
    ]);
  }

  /// Resolved Anthropic key: Admin secret, then env.
  Future<String?> resolvedAnthropicKey([AgentsSecrets? secrets]) async {
    final s = secrets ?? await loadSecrets();
    if (s.hasAnthropic) return s.anthropicApiKey!.trim();
    return _envFirst(const [
      'COMSTAR_ANTHROPIC_API_KEY',
      'ANTHROPIC_API_KEY',
    ]);
  }

  bool effectiveDynamicPlanning(
    OrchestrationConfig yaml,
    AgentsRuntime runtime,
  ) {
    if (runtime.dynamicPlanning != null) return runtime.dynamicPlanning!;
    return yaml.dynamicPlanning;
  }

  String effectiveDefaultRunMode(
    OrchestrationConfig yaml,
    AgentsRuntime runtime,
  ) {
    final r = runtime.defaultRunMode?.trim();
    if (r != null && r.isNotEmpty) return r;
    return yaml.defaultRunMode;
  }

  /// Catalog from yaml (or curated defaults), intersected with Admin enables,
  /// then filtered to providers that have credentials (Ollama always ok).
  Future<List<String>> effectiveAllowedIds(
    OrchestrationConfig yaml, {
    AgentsRuntime? runtime,
    AgentsSecrets? secrets,
  }) async {
    final r = runtime ?? await loadRuntime();
    final s = secrets ?? await loadSecrets();
    final catalog = yaml.allowedAgentProviderIds.isNotEmpty
        ? yaml.allowedAgentProviderIds
        : kCuratedAgentIds;
    final enabled = r.enabledAgentIds ?? catalog;
    final openai = await resolvedOpenaiKey(s);
    final anthropic = await resolvedAnthropicKey(s);
    final out = <String>[];
    for (final id in enabled) {
      final agent = curatedAgentById(id);
      if (agent == null) {
        // AO catalog / custom id — pass through; secrets via sessionEnv.
        out.add(id);
        continue;
      }
      if (agent.provider == 'openai' && (openai == null || openai.isEmpty)) {
        continue;
      }
      if (agent.provider == 'anthropic' &&
          (anthropic == null || anthropic.isEmpty)) {
        continue;
      }
      out.add(id);
    }
    return out;
  }

  Future<Map<String, String>> sessionEnvMap([AgentsSecrets? secrets]) async {
    final s = secrets ?? await loadSecrets();
    final out = <String, String>{};
    final openai = await resolvedOpenaiKey(s);
    final anthropic = await resolvedAnthropicKey(s);
    if (openai != null && openai.isNotEmpty) {
      out['OPENAI_API_KEY'] = openai;
    }
    if (anthropic != null && anthropic.isNotEmpty) {
      out['ANTHROPIC_API_KEY'] = anthropic;
    }
    for (final e in s.env.entries) {
      final k = e.key.trim();
      final v = e.value.trim();
      if (k.isEmpty || v.isEmpty) continue;
      out.putIfAbsent(k, () => v);
    }
    return out;
  }

  Future<List<String>> effectiveAllowedMcpIds({
    AgentsRuntime? runtime,
  }) async {
    final r = runtime ?? await loadRuntime();
    return List<String>.from(r.enabledMcpIds ?? const []);
  }

  Future<List<String>> effectiveAllowedSkillIds({
    AgentsRuntime? runtime,
  }) async {
    final r = runtime ?? await loadRuntime();
    return List<String>.from(r.enabledSkillIds ?? const []);
  }

  String? secretHint(String? key) {
    final k = key?.trim() ?? '';
    if (k.isEmpty) return null;
    if (k.length <= 8) return '••••';
    return '${k.substring(0, 3)}…${k.substring(k.length - 4)}';
  }

  /// Password-field stand-in (never the raw secret).
  String? secretMasked(String? key) {
    final k = key?.trim() ?? '';
    if (k.isEmpty) return null;
    if (k.length <= 8) return '••••••••';
    return '${k.substring(0, 3)}${'•' * 12}${k.substring(k.length - 4)}';
  }

  Future<Map<String, dynamic>> statusPayload({
    required OrchestrationConfig yaml,
    required bool sessionActive,
    Map<String, dynamic>? catalog,
    Map<String, dynamic>? aoProgress,
  }) async {
    final runtime = await loadRuntime();
    final secrets = await loadSecrets();
    final openai = await resolvedOpenaiKey(secrets);
    final anthropic = await resolvedAnthropicKey(secrets);
    final seedCatalog = yaml.allowedAgentProviderIds.isNotEmpty
        ? yaml.allowedAgentProviderIds
        : kCuratedAgentIds;
    final enabledAgents = runtime.enabledAgentIds ?? seedCatalog;
    final enabledMcps = runtime.enabledMcpIds ?? const <String>[];
    final enabledSkills = runtime.enabledSkillIds ?? const <String>[];
    final enabledSet = {...enabledAgents};

    final agents = <Map<String, dynamic>>[];
    final seen = <String>{};
    void addAgent(String id, {String? label, String? provider}) {
      if (seen.contains(id)) return;
      seen.add(id);
      final meta = curatedAgentById(id);
      final p = provider ?? meta?.provider ?? 'unknown';
      final enabled = enabledSet.contains(id);
      final ready = enabled &&
          (p == 'ollama' ||
              p == 'unknown' ||
              (p == 'openai' && openai != null && openai.isNotEmpty) ||
              (p == 'anthropic' && anthropic != null && anthropic.isNotEmpty) ||
              (p != 'openai' && p != 'anthropic'));
      agents.add({
        'id': id,
        'label': label ?? meta?.label ?? id,
        'provider': p,
        'enabled': enabled,
        'ready': ready,
      });
    }

    for (final id in enabledAgents) {
      addAgent(id);
    }
    for (final id in seedCatalog) {
      addAgent(id);
    }
    final catAgents = catalog?['agents'];
    if (catAgents is List) {
      for (final raw in catAgents) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString() ?? '';
        if (id.isEmpty) continue;
        addAgent(
          id,
          label: raw['label']?.toString() ?? raw['role']?.toString(),
          provider: raw['type']?.toString() ?? raw['provider']?.toString(),
        );
      }
    }

    final secretsOut = <String, dynamic>{
      'openai': {
        'configured': openai != null && openai.isNotEmpty,
        'hint': secretHint(openai),
        'masked': secretMasked(openai),
        'valid': openaiKeyValid,
        'from_env': !secrets.hasOpenai &&
            openai != null &&
            openai.isNotEmpty,
        'label': 'OpenAI API key',
        'name': 'OPENAI_API_KEY',
      },
      'anthropic': {
        'configured': anthropic != null && anthropic.isNotEmpty,
        'hint': secretHint(anthropic),
        'masked': secretMasked(anthropic),
        'valid': anthropicKeyValid,
        'from_env': !secrets.hasAnthropic &&
            anthropic != null &&
            anthropic.isNotEmpty,
        'label': 'Anthropic API key',
        'name': 'ANTHROPIC_API_KEY',
      },
      'OPENAI_API_KEY': {
        'configured': openai != null && openai.isNotEmpty,
        'hint': secretHint(openai),
        'masked': secretMasked(openai),
        'valid': openaiKeyValid,
        'label': 'OpenAI API key',
        'name': 'OPENAI_API_KEY',
      },
      'ANTHROPIC_API_KEY': {
        'configured': anthropic != null && anthropic.isNotEmpty,
        'hint': secretHint(anthropic),
        'masked': secretMasked(anthropic),
        'valid': anthropicKeyValid,
        'label': 'Anthropic API key',
        'name': 'ANTHROPIC_API_KEY',
      },
    };
    final envSecrets = <String, dynamic>{};
    for (final e in secrets.env.entries) {
      final v = e.value;
      final entry = {
        'configured': v.trim().isNotEmpty,
        'present': v.trim().isNotEmpty,
        'hint': secretHint(v),
        'masked': secretMasked(v),
        'valid': null,
        'label': e.key,
        'name': e.key,
      };
      secretsOut[e.key] = entry;
      envSecrets[e.key] = entry;
    }
    // Convenience aliases used by Admin Agents UI.
    for (final k in ['OPENAI_API_KEY', 'ANTHROPIC_API_KEY']) {
      final s = secretsOut[k];
      if (s is Map) {
        envSecrets[k] = {
          ...Map<String, dynamic>.from(s),
          'present': s['configured'] == true,
        };
      }
    }

    final sessionAgents = await effectiveAllowedIds(yaml, runtime: runtime);
    final sessionMcps = await effectiveAllowedMcpIds(runtime: runtime);
    final sessionSkills = await effectiveAllowedSkillIds(runtime: runtime);
    final dyn = effectiveDynamicPlanning(yaml, runtime);

    return {
      'ok': true,
      'enabled': dyn,
      'dynamic_planning': dyn,
      'default_run_mode': effectiveDefaultRunMode(yaml, runtime),
      'voice_backend': yaml.voiceBackend,
      'timeout_seconds': yaml.dynamicTimeoutSeconds,
      'enabled_agent_ids': enabledAgents,
      'enabled_mcp_ids': enabledMcps,
      'enabled_skill_ids': enabledSkills,
      'session_open': sessionActive,
      'session_allowed_agent_ids': sessionAgents,
      'session_allowed_mcp_ids': sessionMcps,
      'session_allowed_skill_ids': sessionSkills,
      'agents': agents,
      'mcps': [
        for (final id in enabledMcps) {'id': id, 'enabled': true},
      ],
      'skills': [
        for (final id in enabledSkills) {'id': id, 'enabled': true},
      ],
      'harnesses': catalog?['harnesses'] is List
          ? catalog!['harnesses']
          : const <Map<String, dynamic>>[],
      if (catalog != null) 'catalog': catalog,
      'secrets': {
        ...secretsOut,
        'env': envSecrets,
      },
      'ao_progress': aoProgress,
      'apply': {
        'needs_session_refresh': needsSessionRefresh,
        'session_active': sessionActive,
      },
    };
  }

  static String? _envFirst(List<String> keys) {
    for (final k in keys) {
      final v = Platform.environment[k]?.trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }
}
