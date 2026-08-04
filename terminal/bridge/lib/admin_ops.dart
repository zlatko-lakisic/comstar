import 'dart:io';

/// Whitelisted systemd user units for admin restart.
const adminRestartUnits = <String, String>{
  'bridge': 'comstar-bridge.service',
  'audio': 'comstar-audio.service',
  'kiosk': 'comstar-kiosk.service',
  'stt': 'comstar-stt.service',
  'health': 'comstar-health.service',
};

/// Resolves a short unit key or full unit name to a whitelisted service name.
/// Returns null if not allowed. [key] `all` returns a sentinel handled by caller.
String? resolveAdminUnit(String key) {
  final k = key.trim().toLowerCase();
  if (k == 'all') return 'all';
  if (adminRestartUnits.containsKey(k)) return adminRestartUnits[k];
  // Accept full unit names when they match the whitelist.
  for (final unit in adminRestartUnits.values) {
    if (k == unit.toLowerCase() || k == unit.replaceAll('.service', '')) {
      return unit;
    }
  }
  return null;
}

List<String> allAdminUnits() => adminRestartUnits.values.toList(growable: false);

/// True when LAN binding is active and the request presents a matching token.
bool adminTokenMatches({
  required bool lanBound,
  required String expectedToken,
  required String? headerToken,
  required String? queryToken,
}) {
  if (!lanBound) return true;
  if (expectedToken.isEmpty) return false;
  final presented = (headerToken ?? queryToken ?? '').trim();
  return presented.isNotEmpty && presented == expectedToken;
}

String? adminRequestToken(HttpRequest request) {
  final headers = request.headers;
  final header = headers.value('x-comstar-lan-token') ??
      headers.value('X-Comstar-Lan-Token');
  final query = request.uri.queryParameters['token'];
  if (header != null && header.isNotEmpty) return header;
  if (query != null && query.isNotEmpty) return query;
  return null;
}

bool isAdminInjectEnabled() => Platform.environment['COMSTAR_ENV'] == 'dev';
