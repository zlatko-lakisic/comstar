import 'package:ao_reach/ao_reach.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/reach_app.dart';

/// Fetches AO Reach catalog for Admin Agents UI (agents / MCPs / skills / harnesses).
Future<Map<String, dynamic>> fetchReachCatalog(
  ComstarConfig config,
) async {
  final orch = config.orchestration;
  if (orch.baseUrl.trim().isEmpty) {
    return {
      'ok': false,
      'error': 'orchestration_not_configured',
      'agents': <Map<String, dynamic>>[],
      'mcps': <Map<String, dynamic>>[],
      'skills': <Map<String, dynamic>>[],
      'harnesses': <Map<String, dynamic>>[],
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
    return {
      'ok': true,
      'agents': cat.agents.map(_entryJson).toList(),
      'mcps': cat.mcps.map(_entryJson).toList(),
      'skills': cat.skills.map(_entryJson).toList(),
      'harnesses': cat.harnesses.map(_entryJson).toList(),
      'sessionEnvAllowedKeys': cat.sessionEnvAllowedKeys,
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
      'agents': <Map<String, dynamic>>[],
      'mcps': <Map<String, dynamic>>[],
      'skills': <Map<String, dynamic>>[],
      'harnesses': <Map<String, dynamic>>[],
    };
  }
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
  };
}
