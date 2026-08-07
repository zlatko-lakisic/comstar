/// Allowlist: channel sender id → COMSTAR userid.
///
/// Unknown senders get **zero** outbound — not an error, not a greeting.
/// Exact string compare; no normalisation.
library;

import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

/// Static map from channel-native sender id to COMSTAR userid.
class Allowlist {
  Allowlist(Map<String, String> entries)
      : _map = Map.unmodifiable(
          Map<String, String>.fromEntries(
            entries.entries.map((e) => MapEntry(e.key, e.value)),
          ),
        );

  final Map<String, String> _map;

  /// Resolve sender → userid, or null if not allowlisted.
  String? useridFor(String senderId) => _map[senderId];

  /// First allowlisted sender id for [userid], or null.
  ///
  /// Used for outbound announcements (bridge → channel). Exact userid match;
  /// if multiple senders map to the same userid, the first map insertion wins.
  String? senderIdFor(String userid) {
    for (final e in _map.entries) {
      if (e.value == userid) return e.key;
    }
    return null;
  }

  /// All allowlisted sender ids for [userid] (stable map order).
  List<String> senderIdsFor(String userid) {
    return [
      for (final e in _map.entries)
        if (e.value == userid) e.key,
    ];
  }

  bool contains(String senderId) => _map.containsKey(senderId);

  int get length => _map.length;

  Map<String, String> get entries => _map;

  /// Load from `COMSTAR_CHANNEL_ALLOWLIST` env: inline JSON object, or a path
  /// to a JSON/YAML file mapping senderId → userid.
  factory Allowlist.fromEnv([String? envValue]) {
    final raw = envValue ?? Platform.environment['COMSTAR_CHANNEL_ALLOWLIST'];
    if (raw == null || raw.trim().isEmpty) {
      return Allowlist(const {});
    }
    final trimmed = raw.trim();
    if (trimmed.startsWith('{')) {
      return Allowlist._fromJsonString(trimmed);
    }
    final file = File(trimmed);
    if (!file.existsSync()) {
      throw StateError('Allowlist path not found: $trimmed');
    }
    final body = file.readAsStringSync();
    if (trimmed.endsWith('.yaml') || trimmed.endsWith('.yml')) {
      return Allowlist._fromYamlString(body);
    }
    return Allowlist._fromJsonString(body);
  }

  factory Allowlist._fromJsonString(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw FormatException('Allowlist JSON must be an object');
    }
    return Allowlist({
      for (final e in decoded.entries) '${e.key}': '${e.value}',
    });
  }

  factory Allowlist._fromYamlString(String body) {
    final decoded = loadYaml(body);
    if (decoded is! Map) {
      throw FormatException('Allowlist YAML must be a map');
    }
    return Allowlist({
      for (final e in decoded.entries) '${e.key}': '${e.value}',
    });
  }
}
