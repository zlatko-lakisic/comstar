import 'dart:io';

import 'package:comstar_bridge/announce/config.dart';
import 'package:comstar_bridge/road/config.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class ConfigError implements Exception {
  ConfigError(this.message);
  final String message;
  @override
  String toString() => message;
}

class ComstarConfig {
  ComstarConfig({
    required this.orchestration,
    required this.vision,
    required this.audio,
    required this.avatar,
    required this.attention,
    required this.directory,
    required this.dev,
    this.admin = const AdminConfig(),
    this.phrases = const PhrasesConfig(),
    this.memory = const MemoryConfig(),
    this.presence = const PresenceConfig(),
    this.announce = const AnnounceConfig(),
    this.road = const RoadConfig(),
    required this.sourcePath,
  });

  final OrchestrationConfig orchestration;
  final VisionConfig vision;
  final AudioConfig audio;
  final AvatarConfig avatar;
  final AttentionConfig attention;
  final DirectoryConfig directory;
  final DevConfig dev;
  final AdminConfig admin;
  final PhrasesConfig phrases;
  final MemoryConfig memory;
  final PresenceConfig presence;
  final AnnounceConfig announce;
  final RoadConfig road;
  final String sourcePath;

  static const _topLevelKeys = {
    'orchestration',
    'vision',
    'audio',
    'avatar',
    'attention',
    'directory',
    'dev',
    'admin',
    'phrases',
    'memory',
    'presence',
    'announce',
    'road',
  };

  static const _orchestrationKeys = {
    'base_url',
    'token',
    'ttl_seconds',
    'timeout_seconds',
    'overlay_root',
    'mtls',
    'dynamic_planning',
    'default_run_mode',
    'allowed_agent_provider_ids',
    'voice_backend',
    'dynamic_timeout_seconds',
  };

  static const _orchestrationMtlsKeys = {
    'enabled',
    'material_dir',
    'client_name',
    'trust_enrollment_ca',
  };

  static const _visionKeys = {
    'codeproject_url',
    'detection_endpoint',
    'recognize_endpoint',
    'ambient_fps',
    'engaged_fps',
    'person_confidence',
    'face_confidence',
    'recognize_votes',
    'identity_ttl_seconds',
  };

  static const _audioKeys = {
    'wakeword_model',
    'wakeword_threshold',
    'vad_silence_ms',
    'max_utterance_seconds',
    'followup_window_seconds',
    'duplex',
  };

  static const _avatarKeys = {
    'render',
    'model',
    'tts',
    'piper_voice',
  };

  static const _attentionKeys = {
    'face_attention_trigger',
    'stranger_mode',
    'timezone',
    'idle_sleep_seconds',
    'working_ack_ms',
    'working_ack_on_tools',
  };

  static const _directoryKeys = {
    'enabled',
    'sidecar_url',
    'require',
    'cache_ttl_seconds',
    'timeout_ms',
  };

  static const _devKeys = {
    'bind_lan',
    'lan_token',
  };

  static const _adminKeys = {
    'bind_lan',
    'token',
  };

  static const _phrasesKeys = {
    'enabled',
    'refresh_hours',
    'bank_size',
  };

  static const _memoryKeys = {
    'enabled',
    'max_turns',
    'max_inject_chars',
    'store_dir',
    'url',
    'durable',
    'max_facts_inject',
    'max_facts_chars',
  };

  static const _presenceKeys = {
    'ha_person_by_uid',
  };

  static const _announceKeys = {
    'enabled',
    'queue_path',
    'schedule_path',
    'ha_rules_path',
    'quiet_start',
    'quiet_end',
    'timezone',
    'channel_url',
    'channel_token',
  };

  static const _roadKeys = {
    'enabled',
    'protocol',
    'home_cidrs',
    'check_interval_seconds',
    'openvpn_connection',
    'l2tp_connection',
    'health_url',
    'heal_backoff_max_seconds',
  };

  static ComstarConfig loadFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ConfigError('Config file not found: $path');
    }
    final raw = loadYaml(file.readAsStringSync());
    if (raw is! YamlMap) {
      throw ConfigError('Config root must be a mapping');
    }
    return loadMap(Map<String, dynamic>.from(raw), sourcePath: path);
  }

  static ComstarConfig loadMap(
    Map<String, dynamic> root, {
    required String sourcePath,
  }) {
    _assertKnownKeys(root.keys, _topLevelKeys, 'root');

    final orchestration = _parseOrchestration(
      _requireSection(root, 'orchestration'),
    );
    final vision = _parseVision(_requireSection(root, 'vision'));
    final audio = _parseAudio(_requireSection(root, 'audio'));
    final avatar = _parseAvatar(_requireSection(root, 'avatar'));
    final attention = _parseAttention(_requireSection(root, 'attention'));
    final directory = _parseDirectory(_requireSection(root, 'directory'));
    final dev = _parseDev(_requireSection(root, 'dev'));
    final adminRaw = root['admin'];
    final admin = adminRaw == null
        ? const AdminConfig()
        : _parseAdmin(
            adminRaw is Map
                ? Map<String, dynamic>.from(adminRaw)
                : (throw ConfigError('Section admin must be a mapping')),
          );
    final phrasesRaw = root['phrases'];
    final phrases = phrasesRaw == null
        ? const PhrasesConfig()
        : _parsePhrases(
            phrasesRaw is Map
                ? Map<String, dynamic>.from(phrasesRaw)
                : (throw ConfigError('Section phrases must be a mapping')),
          );
    final memoryRaw = root['memory'];
    final memory = memoryRaw == null
        ? const MemoryConfig()
        : _parseMemory(
            memoryRaw is Map
                ? Map<String, dynamic>.from(memoryRaw)
                : (throw ConfigError('Section memory must be a mapping')),
          );
    final presenceRaw = root['presence'];
    final presence = presenceRaw == null
        ? const PresenceConfig()
        : _parsePresence(
            presenceRaw is Map
                ? Map<String, dynamic>.from(presenceRaw)
                : (throw ConfigError('Section presence must be a mapping')),
          );
    final announceRaw = root['announce'];
    final announce = announceRaw == null
        ? const AnnounceConfig()
        : _parseAnnounce(
            announceRaw is Map
                ? Map<String, dynamic>.from(announceRaw)
                : (throw ConfigError('Section announce must be a mapping')),
          );
    final roadRaw = root['road'];
    final road = roadRaw == null
        ? const RoadConfig()
        : _parseRoad(
            roadRaw is Map
                ? Map<String, dynamic>.from(roadRaw)
                : (throw ConfigError('Section road must be a mapping')),
          );

    _validateRanges(vision, audio, orchestration, avatar, attention, directory);
    _validatePhrases(phrases);
    _validateMemory(memory);
    _validatePresence(presence);
    _validateRoad(road);

    return ComstarConfig(
      orchestration: orchestration,
      vision: vision,
      audio: audio,
      avatar: avatar,
      attention: attention,
      directory: directory,
      dev: dev,
      admin: admin,
      phrases: phrases,
      memory: memory,
      presence: presence,
      announce: announce,
      road: road,
      sourcePath: sourcePath,
    );
  }

  bool get isDevConfigFile =>
      p.basename(sourcePath) == 'comstar.dev.yaml';

  bool get devLanBindingEnabled {
    final env = Platform.environment['COMSTAR_ENV'] ?? '';
    return env == 'dev' &&
        isDevConfigFile &&
        dev.bindLan &&
        dev.lanToken.isNotEmpty;
  }

  /// Token for admin HTTP auth (env wins, then `admin.token`, then `dev.lan_token`).
  String get adminAuthToken {
    final env = Platform.environment['COMSTAR_ADMIN_TOKEN']?.trim() ?? '';
    if (env.isNotEmpty) return env;
    if (admin.token.trim().isNotEmpty) return admin.token.trim();
    if (dev.lanToken.trim().isNotEmpty) return dev.lanToken.trim();
    return '';
  }

  /// Bind admin :8781 to all interfaces when explicitly enabled + token present.
  ///
  /// Enabled by `admin.bind_lan`, `COMSTAR_ADMIN_BIND_LAN=1`, or the WS
  /// triple-gate (`devLanBindingEnabled`). Never binds LAN without a token.
  bool get adminLanBindingEnabled {
    final token = adminAuthToken;
    if (token.isEmpty) return false;
    final envBind = Platform.environment['COMSTAR_ADMIN_BIND_LAN'] == '1';
    return admin.bindLan || envBind || devLanBindingEnabled;
  }

  static Map<String, dynamic> _requireSection(
    Map<String, dynamic> root,
    String name,
  ) {
    final value = root[name];
    if (value == null) {
      throw ConfigError('Missing required section: $name');
    }
    if (value is! Map) {
      throw ConfigError('Section $name must be a mapping');
    }
    return Map<String, dynamic>.from(value);
  }

  static OrchestrationConfig _parseOrchestration(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _orchestrationKeys, 'orchestration');
    final mtlsRaw = map['mtls'];
    final mtls = mtlsRaw == null
        ? const OrchestrationMtlsConfig()
        : _parseOrchestrationMtls(
            Map<String, dynamic>.from(mtlsRaw as Map),
          );
    final baseUrl = _requireString(map, 'base_url', 'orchestration');
    if (mtls.enabled) {
      final uri = Uri.tryParse(baseUrl.replaceAll(RegExp(r'/+$'), ''));
      if (uri == null || uri.scheme != 'https') {
        throw ConfigError(
          'orchestration.mtls.enabled requires orchestration.base_url '
          'to be https://… (got $baseUrl)',
        );
      }
    }
    final runMode = (_optionalString(map, 'default_run_mode') ?? 'dynamic')
        .trim()
        .toLowerCase();
    const runModes = {'dynamic', 'dynamic-iterative'};
    if (!runModes.contains(runMode)) {
      throw ConfigError(
        'orchestration.default_run_mode must be one of: ${runModes.join(', ')}',
      );
    }
    final voiceBackend =
        (_optionalString(map, 'voice_backend') ?? 'hybrid').trim().toLowerCase();
    const voiceBackends = {'hybrid', 'direct', 'dynamic'};
    if (!voiceBackends.contains(voiceBackend)) {
      throw ConfigError(
        'orchestration.voice_backend must be one of: ${voiceBackends.join(', ')}',
      );
    }
    return OrchestrationConfig(
      baseUrl: baseUrl,
      token: _optionalString(map, 'token') ?? '',
      ttlSeconds: _requireInt(map, 'ttl_seconds', 'orchestration'),
      timeoutSeconds:
          _requireInt(map, 'timeout_seconds', 'orchestration'),
      overlayRoot: _requireString(map, 'overlay_root', 'orchestration'),
      mtls: mtls,
      dynamicPlanning: _optionalBool(map, 'dynamic_planning') ?? false,
      defaultRunMode: runMode,
      allowedAgentProviderIds: _optionalStringList(
            map,
            'allowed_agent_provider_ids',
          ) ??
          const [
            'gpt_research',
            'gpt_reason',
            'gpt_write',
            'claude_research',
            'claude_reason',
            'claude_write',
            'ollama_qwen2_5_14b_instruct',
          ],
      voiceBackend: voiceBackend,
      dynamicTimeoutSeconds: map.containsKey('dynamic_timeout_seconds')
          ? _requireInt(map, 'dynamic_timeout_seconds', 'orchestration')
          : 300,
    );
  }

  static OrchestrationMtlsConfig _parseOrchestrationMtls(
    Map<String, dynamic> map,
  ) {
    _assertKnownKeys(map.keys, _orchestrationMtlsKeys, 'orchestration.mtls');
    return OrchestrationMtlsConfig(
      enabled: _optionalBool(map, 'enabled') ?? false,
      materialDir: _optionalString(map, 'material_dir') ?? '',
      clientName: _optionalString(map, 'client_name') ?? '',
      trustEnrollmentCa: _optionalBool(map, 'trust_enrollment_ca') ?? true,
    );
  }

  static VisionConfig _parseVision(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _visionKeys, 'vision');
    return VisionConfig(
      codeprojectUrl: _requireString(map, 'codeproject_url', 'vision'),
      detectionEndpoint:
          _requireString(map, 'detection_endpoint', 'vision'),
      recognizeEndpoint:
          _requireString(map, 'recognize_endpoint', 'vision'),
      ambientFps: _requireDouble(map, 'ambient_fps', 'vision'),
      engagedFps: _requireDouble(map, 'engaged_fps', 'vision'),
      personConfidence:
          _requireDouble(map, 'person_confidence', 'vision'),
      faceConfidence: _requireDouble(map, 'face_confidence', 'vision'),
      recognizeVotes: _requireInt(map, 'recognize_votes', 'vision'),
      identityTtlSeconds:
          _requireInt(map, 'identity_ttl_seconds', 'vision'),
    );
  }

  static AudioConfig _parseAudio(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _audioKeys, 'audio');
    return AudioConfig(
      wakewordModel: _requireString(map, 'wakeword_model', 'audio'),
      wakewordThreshold:
          _requireDouble(map, 'wakeword_threshold', 'audio'),
      vadSilenceMs: _requireInt(map, 'vad_silence_ms', 'audio'),
      maxUtteranceSeconds:
          _requireInt(map, 'max_utterance_seconds', 'audio'),
      followupWindowSeconds:
          _requireInt(map, 'followup_window_seconds', 'audio'),
      duplex: _requireString(map, 'duplex', 'audio'),
    );
  }

  static AvatarConfig _parseAvatar(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _avatarKeys, 'avatar');
    return AvatarConfig(
      render: _requireString(map, 'render', 'avatar'),
      model: _requireString(map, 'model', 'avatar'),
      tts: _requireString(map, 'tts', 'avatar'),
      piperVoice: _requireString(map, 'piper_voice', 'avatar'),
    );
  }

  static AttentionConfig _parseAttention(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _attentionKeys, 'attention');
    return AttentionConfig(
      faceAttentionTrigger:
          _requireBool(map, 'face_attention_trigger', 'attention'),
      strangerMode: _requireString(map, 'stranger_mode', 'attention'),
      timezone: _optionalString(map, 'timezone') ?? '',
      idleSleepSeconds: map.containsKey('idle_sleep_seconds')
          ? _requireInt(map, 'idle_sleep_seconds', 'attention')
          : 600,
      workingAckMs: map.containsKey('working_ack_ms')
          ? _requireInt(map, 'working_ack_ms', 'attention')
          : 4500,
      workingAckOnTools: map.containsKey('working_ack_on_tools')
          ? _requireBool(map, 'working_ack_on_tools', 'attention')
          : true,
    );
  }

  static DirectoryConfig _parseDirectory(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _directoryKeys, 'directory');
    return DirectoryConfig(
      enabled: _requireBool(map, 'enabled', 'directory'),
      sidecarUrl: _optionalString(map, 'sidecar_url') ?? '',
      require: _requireBool(map, 'require', 'directory'),
      cacheTtlSeconds: _requireInt(map, 'cache_ttl_seconds', 'directory'),
      timeoutMs: _requireInt(map, 'timeout_ms', 'directory'),
    );
  }

  static DevConfig _parseDev(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _devKeys, 'dev');
    return DevConfig(
      bindLan: _requireBool(map, 'bind_lan', 'dev'),
      lanToken: _optionalString(map, 'lan_token') ?? '',
    );
  }

  static AdminConfig _parseAdmin(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _adminKeys, 'admin');
    return AdminConfig(
      bindLan: map.containsKey('bind_lan')
          ? _requireBool(map, 'bind_lan', 'admin')
          : false,
      token: _optionalString(map, 'token') ?? '',
    );
  }

  static PhrasesConfig _parsePhrases(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _phrasesKeys, 'phrases');
    return PhrasesConfig(
      enabled: map.containsKey('enabled')
          ? _requireBool(map, 'enabled', 'phrases')
          : true,
      refreshHours: map.containsKey('refresh_hours')
          ? _requireInt(map, 'refresh_hours', 'phrases')
          : 6,
      bankSize: map.containsKey('bank_size')
          ? _requireInt(map, 'bank_size', 'phrases')
          : 8,
    );
  }

  static void _validatePhrases(PhrasesConfig phrases) {
    _rangeInt('phrases.refresh_hours', phrases.refreshHours, 1, 168);
    _rangeInt('phrases.bank_size', phrases.bankSize, 3, 24);
  }

  static MemoryConfig _parseMemory(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _memoryKeys, 'memory');
    return MemoryConfig(
      enabled: map.containsKey('enabled')
          ? _requireBool(map, 'enabled', 'memory')
          : true,
      maxTurns: map.containsKey('max_turns')
          ? _requireInt(map, 'max_turns', 'memory')
          : 20,
      maxInjectChars: map.containsKey('max_inject_chars')
          ? _requireInt(map, 'max_inject_chars', 'memory')
          : 3500,
      storeDir: _optionalString(map, 'store_dir') ?? '',
      url: _optionalString(map, 'url') ?? '',
      durable: map.containsKey('durable')
          ? _requireBool(map, 'durable', 'memory')
          : true,
      maxFactsInject: map.containsKey('max_facts_inject')
          ? _requireInt(map, 'max_facts_inject', 'memory')
          : 8,
      maxFactsChars: map.containsKey('max_facts_chars')
          ? _requireInt(map, 'max_facts_chars', 'memory')
          : 1200,
    );
  }

  static void _validateMemory(MemoryConfig memory) {
    _rangeInt('memory.max_turns', memory.maxTurns, 2, 100);
    _rangeInt('memory.max_inject_chars', memory.maxInjectChars, 500, 12000);
    _rangeInt('memory.max_facts_inject', memory.maxFactsInject, 1, 32);
    _rangeInt('memory.max_facts_chars', memory.maxFactsChars, 200, 4000);
  }

  static PresenceConfig _parsePresence(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _presenceKeys, 'presence');
    final raw = map['ha_person_by_uid'];
    final byUid = <String, String>{};
    if (raw != null) {
      if (raw is! Map) {
        throw ConfigError('presence.ha_person_by_uid must be a mapping');
      }
      for (final entry in raw.entries) {
        final uid = entry.key.toString().trim();
        final entity = entry.value.toString().trim();
        if (uid.isEmpty || entity.isEmpty) {
          throw ConfigError(
            'presence.ha_person_by_uid entries must be non-empty uid → entity',
          );
        }
        if (!entity.startsWith('person.')) {
          throw ConfigError(
            'presence.ha_person_by_uid.$uid must be a person.* entity_id',
          );
        }
        byUid[uid] = entity;
      }
    }
    return PresenceConfig(haPersonByUid: byUid);
  }

  static AnnounceConfig _parseAnnounce(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _announceKeys, 'announce');
    final envUrl = Platform.environment['COMSTAR_CHANNEL_URL'] ?? '';
    final envToken = Platform.environment['COMSTAR_CHANNEL_TOKEN'] ?? '';
    return AnnounceConfig(
      enabled: map['enabled'] as bool? ?? true,
      queuePath: map['queue_path']?.toString() ?? '',
      schedulePath: map['schedule_path']?.toString() ?? 'announce/schedule.yaml',
      haRulesPath: map['ha_rules_path']?.toString() ?? 'announce/ha_rules.yaml',
      quietStart: map['quiet_start']?.toString() ?? '22:00',
      quietEnd: map['quiet_end']?.toString() ?? '07:00',
      timezone: map['timezone']?.toString() ?? '',
      channelUrl: envUrl.trim().isNotEmpty
          ? envUrl.trim()
          : (map['channel_url']?.toString() ?? '').trim(),
      channelToken: envToken.trim().isNotEmpty
          ? envToken.trim()
          : (map['channel_token']?.toString() ?? '').trim(),
    );
  }

  static RoadConfig _parseRoad(Map<String, dynamic> map) {
    _assertKnownKeys(map.keys, _roadKeys, 'road');
    final cidrsRaw = map['home_cidrs'];
    final cidrs = <String>[];
    if (cidrsRaw == null) {
      cidrs.addAll(defaultHomeCidrs);
    } else if (cidrsRaw is List) {
      for (final e in cidrsRaw) {
        final s = e.toString().trim();
        if (s.isNotEmpty) cidrs.add(s);
      }
    } else {
      throw ConfigError('road.home_cidrs must be a list of CIDR strings');
    }
    return RoadConfig(
      enabled: map['enabled'] as bool? ?? false,
      protocol: map['protocol']?.toString() ?? 'openvpn',
      homeCidrs: cidrs.isEmpty ? defaultHomeCidrs : cidrs,
      checkIntervalSeconds: map['check_interval_seconds'] as int? ?? 30,
      openvpnConnection: map['openvpn_connection']?.toString() ?? 'comstar-ovpn',
      l2tpConnection: map['l2tp_connection']?.toString() ?? 'comstar-l2tp',
      healthUrl: map['health_url']?.toString() ?? '',
      healBackoffMaxSeconds: map['heal_backoff_max_seconds'] as int? ?? 300,
    );
  }

  static void _validateRoad(RoadConfig road) {
    if (!roadProtocols.contains(road.protocol)) {
      throw ConfigError(
        'road.protocol must be one of: ${roadProtocols.join(', ')}',
      );
    }
    _rangeInt(
      'road.check_interval_seconds',
      road.checkIntervalSeconds,
      5,
      3600,
    );
    _rangeInt(
      'road.heal_backoff_max_seconds',
      road.healBackoffMaxSeconds,
      30,
      3600,
    );
    if (road.homeCidrs.isEmpty) {
      throw ConfigError('road.home_cidrs must not be empty');
    }
    for (final c in road.homeCidrs) {
      try {
        // ignore: unused_result — validation only
        // Parse via string split to avoid importing cidr into config cyclically;
        // lightweight check:
        final slash = c.indexOf('/');
        final addr = slash < 0 ? c : c.substring(0, slash);
        final prefix = slash < 0 ? '32' : c.substring(slash + 1);
        if (InternetAddress.tryParse(addr.trim()) == null) {
          throw FormatException('bad addr');
        }
        final p = int.tryParse(prefix.trim());
        if (p == null || p < 0 || p > 32) throw FormatException('bad prefix');
      } on Object {
        throw ConfigError('road.home_cidrs entry invalid: $c');
      }
    }
    if (road.openvpnConnection.trim().isEmpty) {
      throw ConfigError('road.openvpn_connection must not be empty');
    }
    if (road.l2tpConnection.trim().isEmpty) {
      throw ConfigError('road.l2tp_connection must not be empty');
    }
  }

  static void _validatePresence(PresenceConfig presence) {
    // Entity shape checked in _parsePresence.
  }

  static void _validateRanges(
    VisionConfig vision,
    AudioConfig audio,
    OrchestrationConfig orchestration,
    AvatarConfig avatar,
    AttentionConfig attention,
    DirectoryConfig directory,
  ) {
    _range('vision.ambient_fps', vision.ambientFps, 0.2, 5);
    _range('vision.engaged_fps', vision.engagedFps, vision.ambientFps, 10);
    _range('vision.person_confidence', vision.personConfidence, 0.3, 0.95);
    _range('vision.face_confidence', vision.faceConfidence, 0.3, 0.95);
    _rangeInt('vision.recognize_votes', vision.recognizeVotes, 1, 10);
    _range('audio.wakeword_threshold', audio.wakewordThreshold, 0.2, 0.95);
    _rangeInt('audio.vad_silence_ms', audio.vadSilenceMs, 300, 2000);
    _rangeInt(
      'audio.followup_window_seconds',
      audio.followupWindowSeconds,
      0,
      30,
    );
    _rangeInt(
      'orchestration.timeout_seconds',
      orchestration.timeoutSeconds,
      5,
      60,
    );
    _rangeInt(
      'orchestration.dynamic_timeout_seconds',
      orchestration.dynamicTimeoutSeconds,
      15,
      600,
    );

    const strangerModes = {'restricted', 'greet', 'ignore'};
    if (!strangerModes.contains(attention.strangerMode)) {
      throw ConfigError(
        'attention.stranger_mode must be one of: ${strangerModes.join(', ')}',
      );
    }
    _rangeInt(
      'attention.idle_sleep_seconds',
      attention.idleSleepSeconds,
      0,
      86400,
    );
    _rangeInt(
      'attention.working_ack_ms',
      attention.workingAckMs,
      0,
      60000,
    );

    const renderModes = {'local', 'streamed'};
    if (!renderModes.contains(avatar.render)) {
      throw ConfigError(
        'avatar.render must be one of: ${renderModes.join(', ')}',
      );
    }

    const duplexModes = {'half', 'full'};
    if (!duplexModes.contains(audio.duplex)) {
      throw ConfigError(
        'audio.duplex must be one of: ${duplexModes.join(', ')}',
      );
    }

    _rangeInt(
      'directory.cache_ttl_seconds',
      directory.cacheTtlSeconds,
      60,
      3600,
    );
    _rangeInt('directory.timeout_ms', directory.timeoutMs, 200, 10000);
    if (directory.enabled && directory.sidecarUrl.trim().isEmpty) {
      throw ConfigError(
        'directory.sidecar_url must be non-empty when directory.enabled is true',
      );
    }
  }

  static void _range(String key, num value, num min, num max) {
    if (value < min || value > max) {
      throw ConfigError('$key must be between $min and $max (got $value)');
    }
  }

  static void _rangeInt(String key, int value, int min, int max) {
    if (value < min || value > max) {
      throw ConfigError('$key must be between $min and $max (got $value)');
    }
  }

  static void _assertKnownKeys(
    Iterable<dynamic> keys,
    Set<String> allowed,
    String section,
  ) {
    for (final key in keys) {
      final name = key.toString();
      if (!allowed.contains(name)) {
        final suggestion = _nearestKey(name, allowed);
        final hint = suggestion == null
            ? ''
            : ' — did you mean "$suggestion"?';
        throw ConfigError('Unknown key in $section: $name$hint');
      }
    }
  }

  static String? _nearestKey(String key, Set<String> allowed) {
    String? best;
    var bestDistance = 999;
    for (final candidate in allowed) {
      final distance = _editDistance(key, candidate);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }
    return bestDistance <= 3 ? best : null;
  }

  static int _editDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    final previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      var corner = previous[0];
      previous[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final upper = previous[j + 1];
        final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
        previous[j + 1] = [
          previous[j + 1] + 1,
          previous[j] + 1,
          corner + cost,
        ].reduce((x, y) => x < y ? x : y);
        corner = upper;
      }
    }
    return previous[b.length];
  }

  static String _requireString(
    Map<String, dynamic> map,
    String key,
    String section,
  ) {
    final value = map[key];
    if (value == null) {
      throw ConfigError('Missing required key: $section.$key');
    }
    return value.toString();
  }

  static String? _optionalString(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value == null) return null;
    return value.toString();
  }

  static List<String>? _optionalStringList(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is! List) {
      throw ConfigError('$key must be a list of strings');
    }
    return [
      for (final e in value)
        if (e != null && e.toString().trim().isNotEmpty) e.toString().trim(),
    ];
  }

  static int _requireInt(
    Map<String, dynamic> map,
    String key,
    String section,
  ) {
    final value = map[key];
    if (value == null) {
      throw ConfigError('Missing required key: $section.$key');
    }
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw ConfigError('$section.$key must be an integer');
  }

  static double _requireDouble(
    Map<String, dynamic> map,
    String key,
    String section,
  ) {
    final value = map[key];
    if (value == null) {
      throw ConfigError('Missing required key: $section.$key');
    }
    if (value is num) return value.toDouble();
    throw ConfigError('$section.$key must be a number');
  }

  static bool _requireBool(
    Map<String, dynamic> map,
    String key,
    String section,
  ) {
    final value = map[key];
    if (value == null) {
      throw ConfigError('Missing required key: $section.$key');
    }
    if (value is bool) return value;
    throw ConfigError('$section.$key must be a boolean');
  }

  static bool? _optionalBool(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is bool) return value;
    throw ConfigError('$key must be a boolean');
  }
}

class OrchestrationMtlsConfig {
  const OrchestrationMtlsConfig({
    this.enabled = false,
    this.materialDir = '',
    this.clientName = '',
    this.trustEnrollmentCa = true,
  });

  final bool enabled;
  final String materialDir;
  final String clientName;
  final bool trustEnrollmentCa;

  /// Default `~/.local/share/comstar/ao-mtls` when [materialDir] is empty.
  String resolvedMaterialDir() {
    final trimmed = materialDir.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final home = Platform.environment['HOME']?.trim() ?? '';
    if (home.isEmpty) {
      return p.join('.local', 'share', 'comstar', 'ao-mtls');
    }
    return p.join(home, '.local', 'share', 'comstar', 'ao-mtls');
  }
}

class OrchestrationConfig {
  const OrchestrationConfig({
    required this.baseUrl,
    required this.token,
    required this.ttlSeconds,
    required this.timeoutSeconds,
    required this.overlayRoot,
    this.mtls = const OrchestrationMtlsConfig(),
    this.dynamicPlanning = false,
    this.defaultRunMode = 'dynamic',
    this.allowedAgentProviderIds = const [
      'gpt_research',
      'gpt_reason',
      'gpt_write',
      'claude_research',
      'claude_reason',
      'claude_write',
      'ollama_qwen2_5_14b_instruct',
    ],
    this.voiceBackend = 'hybrid',
    this.dynamicTimeoutSeconds = 300,
  });

  final String baseUrl;
  final String token;
  final int ttlSeconds;
  final int timeoutSeconds;
  final String overlayRoot;
  final OrchestrationMtlsConfig mtls;

  /// Yaml default; Admin Agents runtime overlay may override.
  final bool dynamicPlanning;

  /// `dynamic` | `dynamic-iterative`
  final String defaultRunMode;

  /// Curated stock agent ids passed to Reach `allowedAgentProviderIds`.
  final List<String> allowedAgentProviderIds;

  /// `hybrid` | `direct` | `dynamic`
  final String voiceBackend;

  /// Wall-clock budget for Reach `chat` / dynamic planning turns (seconds).
  final int dynamicTimeoutSeconds;

  /// Responding-state Tick deadline for in-flight AO turns (ms).
  ///
  /// Uses the larger of the direct-agent floor (max(configured, 90s) for HA
  /// tools) and [dynamicTimeoutSeconds], so research/chat is not cut off by
  /// the short `timeout_seconds` chat default while the Future is still waiting.
  int get aoRespondingTimeoutMs {
    final directConfigured = timeoutSeconds * 1000;
    final directFloor = directConfigured < 90000 ? 90000 : directConfigured;
    final dynamicMs = dynamicTimeoutSeconds * 1000;
    return directFloor > dynamicMs ? directFloor : dynamicMs;
  }
}

class VisionConfig {
  const VisionConfig({
    required this.codeprojectUrl,
    required this.detectionEndpoint,
    required this.recognizeEndpoint,
    required this.ambientFps,
    required this.engagedFps,
    required this.personConfidence,
    required this.faceConfidence,
    required this.recognizeVotes,
    required this.identityTtlSeconds,
  });

  final String codeprojectUrl;
  final String detectionEndpoint;
  final String recognizeEndpoint;
  final double ambientFps;
  final double engagedFps;
  final double personConfidence;
  final double faceConfidence;
  final int recognizeVotes;
  final int identityTtlSeconds;
}

class AudioConfig {
  const AudioConfig({
    required this.wakewordModel,
    required this.wakewordThreshold,
    required this.vadSilenceMs,
    required this.maxUtteranceSeconds,
    required this.followupWindowSeconds,
    required this.duplex,
  });

  final String wakewordModel;
  final double wakewordThreshold;
  final int vadSilenceMs;
  final int maxUtteranceSeconds;
  final int followupWindowSeconds;
  final String duplex;
}

class AvatarConfig {
  const AvatarConfig({
    required this.render,
    required this.model,
    required this.tts,
    required this.piperVoice,
  });

  final String render;
  final String model;
  final String tts;
  final String piperVoice;
}

class AttentionConfig {
  const AttentionConfig({
    required this.faceAttentionTrigger,
    required this.strangerMode,
    this.timezone = '',
    this.idleSleepSeconds = 600,
    this.workingAckMs = 4500,
    this.workingAckOnTools = true,
  });

  final bool faceAttentionTrigger;
  final String strangerMode;

  /// Optional IANA / human label for spoken TZ answers (e.g. America/New_York).
  /// Clock itself always uses the terminal's system [DateTime.now].
  final String timezone;

  /// Seconds without interaction before silent auto-sleep. `0` disables.
  final int idleSleepSeconds;

  /// After this many ms waiting on AO, speak a one-shot "working on it" line.
  /// `0` disables. Default 4500.
  final int workingAckMs;

  /// When true, only arm when `mcpProvidersForVoice` is non-empty. Either way,
  /// the utterance must look like tool/query work (not conversational acks).
  final bool workingAckOnTools;
}

class DirectoryConfig {
  const DirectoryConfig({
    required this.enabled,
    required this.sidecarUrl,
    required this.require,
    required this.cacheTtlSeconds,
    required this.timeoutMs,
  });

  final bool enabled;
  final String sidecarUrl;
  final bool require;
  final int cacheTtlSeconds;
  final int timeoutMs;
}

class DevConfig {
  const DevConfig({
    required this.bindLan,
    required this.lanToken,
  });

  final bool bindLan;
  final String lanToken;
}

/// Admin HTTP console (:8781/admin). Independent of WS `dev.bind_lan` triple-gate.
class AdminConfig {
  const AdminConfig({
    this.bindLan = false,
    this.token = '',
  });

  final bool bindLan;
  final String token;
}

/// Periodic AO phrase banks for engage / sleep / social lines.
class PhrasesConfig {
  const PhrasesConfig({
    this.enabled = true,
    this.refreshHours = 6,
    this.bankSize = 8,
  });

  final bool enabled;
  final int refreshHours;
  final int bankSize;

  Duration get refreshEvery => Duration(hours: refreshHours);
}

/// Per-userid rolling conversation memory (cross-terminal via [url] or shared dir).
class MemoryConfig {
  const MemoryConfig({
    this.enabled = true,
    this.maxTurns = 20,
    this.maxInjectChars = 3500,
    this.storeDir = '',
    this.url = '',
    this.durable = true,
    this.maxFactsInject = 8,
    this.maxFactsChars = 1200,
  });

  final bool enabled;
  final int maxTurns;
  final int maxInjectChars;

  /// Local/NFS directory for JSON histories when [url] is empty.
  final String storeDir;

  /// Shared HTTP memory server (`scripts/comstar_memory_server.py`).
  /// Env `COMSTAR_MEMORY_URL` overrides when set.
  final String url;

  /// Phase 2: extract + retrieve durable facts (prefs / remember-that).
  final bool durable;
  final int maxFactsInject;
  final int maxFactsChars;
}

/// House-wide presence via HA person entities (ADR 0006). Yaml map first;
/// IPA group / `comstarHaPerson` attribute overlay lands in P2.3+.
class PresenceConfig {
  const PresenceConfig({
    this.haPersonByUid = const {},
  });

  /// COMSTAR / IPA uid → Assist-exposed HA `person.*` entity_id.
  final Map<String, String> haPersonByUid;
}
