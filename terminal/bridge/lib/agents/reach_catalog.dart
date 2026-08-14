import 'package:ao_reach/ao_reach.dart';
import 'package:comstar_bridge/agents/ao_stock_agents.g.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/reach_app.dart';

/// Fetches AO Reach catalog for Admin Agents UI (agents / MCPs / skills / harnesses).
///
/// Live `GET /api/v1/catalog` only returns currently *available* providers on the
/// AO host (Ada may advertise a slim jetson pack). COMSTAR merges the full AO
/// stock agent_providers pack so operators can enable any stock id via
/// `allowedAgentProviderIds` + `sessionEnv` even when AO is not advertising it.
Future<Map<String, dynamic>> fetchReachCatalog(
  ComstarConfig config,
) async {
  final orch = config.orchestration;
  if (orch.baseUrl.trim().isEmpty) {
    return {
      'ok': false,
      'error': 'orchestration_not_configured',
      'agents': _mergedAgents(const []),
      'mcps': <Map<String, dynamic>>[],
      'skills': <Map<String, dynamic>>[],
      'harnesses': <Map<String, dynamic>>[],
      'stock_agent_count': kAoStockAgents.length,
      'live_agent_count': 0,
    };
  }
  try {
    ReachMtlsConfig? mtls;
    final mtlsCfg = orch.mtls;
    if (mtlsCfg.enabled) {
      final dir = mtlsCfg.resolvedMaterialDir();
      final probe = ReachMtlsConfig(materialDir: dir);
      if (probe.isConfigured) {
        mtls = probe;
      }
    }
    final headers = <String, String>{
      if (orch.token.trim().isNotEmpty)
        'Authorization': 'Bearer ${orch.token.trim()}',
    };
    final client = ReachCatalogClient();
    final cat = await client.fetch(
      ReachConnectionConfig(
        baseUrl: orch.baseUrl,
        headers: headers,
        appId: kComstarReachAppId,
        ttlSeconds: orch.ttlSeconds,
        mtls: mtls,
      ),
    );
    final liveAgents = cat.agents.map(_entryJson).toList();
    return {
      'ok': true,
      'agents': _mergedAgents(liveAgents),
      'mcps': cat.mcps.map(_entryJson).toList(),
      'skills': cat.skills.map(_entryJson).toList(),
      'harnesses': cat.harnesses.map(_entryJson).toList(),
      'sessionEnvAllowedKeys': cat.sessionEnvAllowedKeys,
      'stock_agent_count': kAoStockAgents.length,
      'live_agent_count': liveAgents.length,
    };
  } catch (e, st) {
    logWarn(
      'agents.catalog_fetch_failed',
      'Reach catalog fetch failed',
      data: {'error': e.toString()},
    );
    logDebug('agents.catalog_fetch_st', st.toString());
    return {
      'ok': false,
      'error': e.toString(),
      'agents': _mergedAgents(const []),
      'mcps': <Map<String, dynamic>>[],
      'skills': <Map<String, dynamic>>[],
      'harnesses': <Map<String, dynamic>>[],
      'stock_agent_count': kAoStockAgents.length,
      'live_agent_count': 0,
    };
  }
}

/// Live available agents first, then remaining AO stock ids.
List<Map<String, dynamic>> _mergedAgents(
  List<Map<String, dynamic>> live,
) {
  final byId = <String, Map<String, dynamic>>{};
  for (final raw in kAoStockAgents) {
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) continue;
    byId[id] = {
      ...raw,
      'onAo': false,
      'available': false,
      'ready': true,
      'missingSecrets': <String>[],
    };
  }
  for (final liveEntry in live) {
    final id = liveEntry['id']?.toString() ?? '';
    if (id.isEmpty) continue;
    final prev = byId[id] ?? <String, dynamic>{};
    byId[id] = {
      ...prev,
      ...liveEntry,
      'onAo': true,
      'available': true,
      'source': liveEntry['source'] ?? 'ao_live',
      'ready': liveEntry['ready'] ?? true,
    };
  }
  final out = byId.values.toList()
    ..sort((a, b) => (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? ''));
  return out;
}

Map<String, dynamic> _entryJson(ReachCatalogEntry e) {
  final linked = e.raw['agentProviderIds'] ?? e.raw['agent_provider_ids'];
  return {
    'id': e.id,
    'kind': e.kind,
    'label': e.role ?? e.description ?? e.id,
    'description': e.description,
    'role': e.role,
    'provider': e.type,
    'model': e.model,
    'requiredSecrets': [
      for (final s in e.requiredSecrets)
        {
          'name': s.name,
          'label': s.label,
          'required': s.required,
          'secret': s.secret,
        },
    ],
    'ready': true,
    'missingSecrets': <String>[],
    'harnessProfile': e.harnessProfile,
    'agentProviderIds': linked is List
        ? [for (final x in linked) x.toString()]
        : <String>[],
    'source': 'ao_live',
    'onAo': true,
    'available': true,
  };
}
