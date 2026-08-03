import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Overlay MCP definition under `overlays/comstar/mcp_providers/*.yaml`.
class OverlayMcpDefinition {
  const OverlayMcpDefinition({
    required this.id,
    required this.description,
    required this.transport,
    required this.alias,
    required this.npxPackage,
    required this.envFrom,
    required this.requiresTokens,
    required this.guestAllowed,
    required this.sourcePath,
  });

  final String id;
  final String description;
  final String transport;
  final String alias;
  final String npxPackage;
  final List<String> envFrom;
  final bool requiresTokens;
  final bool guestAllowed;
  final String sourcePath;

  String get clientId => id.startsWith('client.') ? id : 'client.$id';
}

/// Loads Comstar-owned overlay MCP YAML (Reach packer does not read this dir).
List<OverlayMcpDefinition> loadOverlayMcpProviders(String overlayRoot) {
  final dir = Directory(p.join(overlayRoot, 'mcp_providers'));
  if (!dir.existsSync()) return const [];

  final out = <OverlayMcpDefinition>[];
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.yaml') || f.path.endsWith('.yml'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    final raw = loadYaml(file.readAsStringSync());
    if (raw is! YamlMap) continue;
    final map = Map<String, dynamic>.from(raw);
    final id = map['id']?.toString().trim() ?? '';
    if (id.isEmpty) continue;
    final transport = map['transport']?.toString() ?? 'stdio_tunnel';
    final alias = (map['alias']?.toString().trim().isNotEmpty == true)
        ? map['alias'].toString().trim()
        : id;
    final npx = map['npx_package']?.toString().trim() ?? '';
    if (transport == 'stdio_tunnel' && npx.isEmpty) {
      continue;
    }
    final envFrom = <String>[];
    final rawEnv = map['env_from'];
    if (rawEnv is YamlList) {
      for (final e in rawEnv) {
        final s = e.toString().trim();
        if (s.isNotEmpty) envFrom.add(s);
      }
    }
    out.add(
      OverlayMcpDefinition(
        id: id,
        description: map['description']?.toString() ?? id,
        transport: transport,
        alias: alias,
        npxPackage: npx,
        envFrom: envFrom,
        requiresTokens: map['requires_tokens'] == true,
        guestAllowed: map['guest_allowed'] == true,
        sourcePath: file.path,
      ),
    );
  }
  return out;
}
