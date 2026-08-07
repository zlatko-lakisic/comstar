/// Runtime overlay + secrets paths for road VPN.
library;

import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/road/config.dart';
import 'package:path/path.dart' as p;

String defaultRoadStateDir() {
  final home = Platform.environment['HOME']?.trim();
  if (home != null && home.isNotEmpty) {
    return p.join(home, '.local', 'share', 'comstar', 'road');
  }
  return p.join('/var/tmp', 'comstar-road');
}

class RoadStore {
  RoadStore({String? stateDir}) : stateDir = stateDir ?? defaultRoadStateDir();

  final String stateDir;

  String get runtimePath => p.join(stateDir, 'runtime.json');
  String get secretsPath => p.join(stateDir, 'secrets.json');

  Future<void> ensureDir() async {
    await Directory(stateDir).create(recursive: true);
  }

  Future<RoadConfig> loadEffective(RoadConfig yaml) async {
    final file = File(runtimePath);
    if (!await file.exists()) return yaml;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return yaml;
      return RoadConfig.fromJson(Map<String, dynamic>.from(raw), base: yaml);
    } on Object {
      return yaml;
    }
  }

  Future<void> saveRuntime(RoadConfig cfg) async {
    await ensureDir();
    final file = File(runtimePath);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(cfg.toJson()),
      flush: true,
    );
  }

  Future<Map<String, dynamic>> loadSecrets() async {
    final file = File(secretsPath);
    if (!await file.exists()) return {};
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map) return Map<String, dynamic>.from(raw);
    } on Object {
      // ignore
    }
    return {};
  }

  Future<void> mergeSecrets(Map<String, dynamic> patch) async {
    await ensureDir();
    final cur = await loadSecrets();
    for (final e in patch.entries) {
      final v = e.value;
      if (v is Map && cur[e.key] is Map) {
        cur[e.key] = {
          ...Map<String, dynamic>.from(cur[e.key] as Map),
          ...Map<String, dynamic>.from(v),
        };
      } else {
        cur[e.key] = v;
      }
    }
    final file = File(secretsPath);
    await file.writeAsString(jsonEncode(cur), flush: true);
    try {
      await Process.run('chmod', ['600', secretsPath]);
    } on Object {
      // best-effort
    }
  }

  Future<bool> hasOpenVpnSecrets() async {
    final s = await loadSecrets();
    final o = s['openvpn'];
    if (o is! Map) return false;
    final ovpn = o['ovpn']?.toString() ?? '';
    return ovpn.trim().isNotEmpty;
  }

  Future<bool> hasL2tpSecrets() async {
    final s = await loadSecrets();
    final o = s['l2tp'];
    if (o is! Map) return false;
    final gw = o['gateway']?.toString() ?? '';
    final user = o['user']?.toString() ?? '';
    return gw.trim().isNotEmpty && user.trim().isNotEmpty;
  }
}
