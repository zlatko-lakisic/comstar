import 'dart:io';

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
    required this.sourcePath,
  });

  final OrchestrationConfig orchestration;
  final VisionConfig vision;
  final AudioConfig audio;
  final AvatarConfig avatar;
  final AttentionConfig attention;
  final DirectoryConfig directory;
  final DevConfig dev;
  final String sourcePath;

  static const _topLevelKeys = {
    'orchestration',
    'vision',
    'audio',
    'avatar',
    'attention',
    'directory',
    'dev',
  };

  static const _orchestrationKeys = {
    'base_url',
    'token',
    'ttl_seconds',
    'timeout_seconds',
    'overlay_root',
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

    _validateRanges(vision, audio, orchestration, avatar, attention, directory);

    return ComstarConfig(
      orchestration: orchestration,
      vision: vision,
      audio: audio,
      avatar: avatar,
      attention: attention,
      directory: directory,
      dev: dev,
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
    return OrchestrationConfig(
      baseUrl: _requireString(map, 'base_url', 'orchestration'),
      token: _optionalString(map, 'token') ?? '',
      ttlSeconds: _requireInt(map, 'ttl_seconds', 'orchestration'),
      timeoutSeconds:
          _requireInt(map, 'timeout_seconds', 'orchestration'),
      overlayRoot: _requireString(map, 'overlay_root', 'orchestration'),
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

    const strangerModes = {'restricted', 'greet', 'ignore'};
    if (!strangerModes.contains(attention.strangerMode)) {
      throw ConfigError(
        'attention.stranger_mode must be one of: ${strangerModes.join(', ')}',
      );
    }

    const renderModes = {'local', 'streamed'};
    if (!renderModes.contains(avatar.render)) {
      throw ConfigError(
        'avatar.render must be one of: ${renderModes.join(', ')}',
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
}

class OrchestrationConfig {
  const OrchestrationConfig({
    required this.baseUrl,
    required this.token,
    required this.ttlSeconds,
    required this.timeoutSeconds,
    required this.overlayRoot,
  });

  final String baseUrl;
  final String token;
  final int ttlSeconds;
  final int timeoutSeconds;
  final String overlayRoot;
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
  });

  final bool faceAttentionTrigger;
  final String strangerMode;
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
