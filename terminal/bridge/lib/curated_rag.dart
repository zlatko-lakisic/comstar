import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/config.dart';
import 'package:path/path.dart' as p;

/// Phase 3 curated durable-facts pack (`export_resident_facts_rag.py`).
class CuratedRagPack {
  const CuratedRagPack({
    required this.packId,
    required this.factCount,
    required this.manifestPath,
  });

  final String packId;
  final int factCount;
  final String manifestPath;

  bool get isUsable => packId.isNotEmpty && factCount > 0;
}

/// Resolve pack dir and read manifest when [MemoryConfig.curatedRagEnabled].
CuratedRagPack? loadCuratedRagPack(MemoryConfig memory) {
  if (!memory.curatedRagEnabled) return null;
  final id = memory.curatedRagId.trim();
  if (id.isEmpty) return null;

  final dir = _packDir(memory, id);
  final manifestFile = File(p.join(dir.path, 'manifest.json'));
  if (!manifestFile.existsSync()) return null;
  try {
    final raw = jsonDecode(manifestFile.readAsStringSync());
    if (raw is! Map) return null;
    final packId = (raw['pack_id']?.toString() ?? id).trim();
    final count = (raw['fact_count'] as num?)?.toInt() ?? 0;
    if (count <= 0) return null;
    // Reject packs that somehow include news/greeter markers in fact texts.
    final facts = raw['facts'];
    if (facts is List) {
      for (final item in facts) {
        if (item is! Map) continue;
        final text = (item['text']?.toString() ?? '').toLowerCase();
        if (text.contains('headline') ||
            text.contains('around the world') ||
            text.contains('awaiting your voice') ||
            text.startsWith('good morning')) {
          return null;
        }
      }
    }
    return CuratedRagPack(
      packId: packId.isEmpty ? id : packId,
      factCount: count,
      manifestPath: manifestFile.path,
    );
  } catch (_) {
    return null;
  }
}

Directory _packDir(MemoryConfig memory, String packId) {
  final override = memory.curatedRagPackDir.trim();
  if (override.isNotEmpty) return Directory(override);
  final store = memory.storeDir.trim();
  if (store.isNotEmpty) {
    return Directory(p.join(store, 'rag', packId));
  }
  final env = Platform.environment['COMSTAR_MEMORY_DIR']?.trim() ?? '';
  final base = env.isNotEmpty
      ? env
      : p.join(
          Platform.environment['HOME'] ?? Directory.systemTemp.path,
          '.local',
          'share',
          'comstar',
          'conversation',
        );
  return Directory(p.join(base, 'rag', packId));
}

/// Prompt steer when curated pack is usable (never for news — caller gates).
String curatedRagSteer(CuratedRagPack pack) {
  return 'Curated resident facts pack `${pack.packId}` is available '
      '(${pack.factCount} facts). For preference / identity questions you may '
      'attach rag_ids: ["${pack.packId}"]. Never attach orchestrator_kb. '
      'Never attach this pack for world-news or headline requests — those keep '
      'rag_ids: []. Prefer client.comstar_memory tools when the pack is thin.';
}
