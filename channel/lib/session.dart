/// Per-userid SessionBridge for the text channel (M11.5 / M11.0 decision).
///
/// Session id: `comstar-<uid>-channel` — **never** share `comstar-<uid>` with
/// the terminal (same-id stop clears the shared overlay). Continuity across
/// surfaces is via userid / KB, not a shared session overlay.
///
/// When Ada AO requires client certs, set `COMSTAR_AO_MTLS=1` and
/// `COMSTAR_AO_MTLS_DIR` (same material layout as ADR 0013).
library;

import 'dart:async';
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:path/path.dart' as p;

/// Long-lived channel sessions keyed by COMSTAR userid.
class ChannelSessionManager {
  ChannelSessionManager({
    required this.baseUrl,
    required this.overlayRoot,
    this.token = '',
    this.ttlSeconds = 3600,
    this.idleTtl = const Duration(hours: 6),
    this.agentProviderId = 'client.text_responder',
    this.mtlsEnabled = false,
    this.mtlsMaterialDir = '',
  });

  final String baseUrl;
  final String overlayRoot;
  final String token;
  final int ttlSeconds;
  final Duration idleTtl;
  final String agentProviderId;
  final bool mtlsEnabled;
  final String mtlsMaterialDir;

  final Map<String, _Held> _byUser = {};

  static String sessionIdFor(String userid) => 'comstar-$userid-channel';

  String get resolvedMtlsDir {
    final raw = mtlsMaterialDir.trim();
    if (raw.isNotEmpty) {
      if (raw.startsWith('~/')) {
        final home = Platform.environment['HOME'] ?? '';
        return p.normalize(p.join(home, raw.substring(2)));
      }
      return raw;
    }
    final home = Platform.environment['HOME'] ?? '.';
    return p.join(home, '.local', 'share', 'comstar', 'ao-mtls');
  }

  static bool materialPresent(String dir) {
    final cert = File(p.join(dir, 'cert.pem'));
    final key = File(p.join(dir, 'key.pem'));
    final ca = File(p.join(dir, 'ca.pem'));
    return cert.existsSync() &&
        key.existsSync() &&
        ca.existsSync() &&
        cert.lengthSync() > 0 &&
        key.lengthSync() > 0 &&
        ca.lengthSync() > 0;
  }

  ReachMtlsConfig? _mtlsOrThrow() {
    if (!mtlsEnabled) return null;
    if (!baseUrl.trim().toLowerCase().startsWith('https://')) {
      throw StateError(
        'AO mTLS enabled requires https:// AO_BASE_URL (got $baseUrl)',
      );
    }
    final dir = resolvedMtlsDir;
    if (!materialPresent(dir)) {
      throw StateError(
        'AO mTLS enabled but PEMs missing in $dir — enroll on Ada '
        '(same material as bridge ADR 0013)',
      );
    }
    return ReachMtlsConfig(materialDir: dir);
  }

  /// Run a text turn for [userid]; opens / reuses the channel SessionBridge.
  Future<String> turn(String userid, String text) async {
    final held = await _ensure(userid);
    held.lastUsed = DateTime.now();
    final result = await held.bridge.directAgent(
      agentProviderId: agentProviderId,
      text: text,
      timeout: const Duration(seconds: 120),
    );
    final body = '${result['text'] ?? ''}'.trim();
    if (result['ok'] != true || body.isEmpty) {
      throw StateError('text_responder turn failed for $userid');
    }
    return body;
  }

  Future<_Held> _ensure(String userid) async {
    final existing = _byUser[userid];
    if (existing != null &&
        existing.bridge.state == SessionBridgeState.active) {
      return existing;
    }
    if (existing != null) {
      try {
        await existing.bridge.stop(clearRemote: true);
      } catch (_) {}
      _byUser.remove(userid);
    }

    final bridge = SessionBridge();
    final headers = <String, String>{
      'x-agentic-user-name': userid,
      'x-agentic-session-id': sessionIdFor(userid),
    };
    if (token.isNotEmpty) headers['x-warpgate-token'] = token;
    final mtls = _mtlsOrThrow();

    await bridge.start(
      config: ReachConnectionConfig(
        baseUrl: baseUrl,
        headers: headers,
        ttlSeconds: ttlSeconds,
        mtls: mtls,
      ),
      overlayRoot: overlayRoot,
    );
    final held = _Held(bridge: bridge, lastUsed: DateTime.now());
    _byUser[userid] = held;
    return held;
  }

  /// Drop idle sessions (call periodically).
  Future<void> reapIdle() async {
    final now = DateTime.now();
    final stale = <String>[];
    for (final e in _byUser.entries) {
      if (now.difference(e.value.lastUsed) > idleTtl) {
        stale.add(e.key);
      }
    }
    for (final uid in stale) {
      await stopUser(uid);
    }
  }

  Future<void> stopUser(String userid) async {
    final held = _byUser.remove(userid);
    if (held == null) return;
    try {
      await held.bridge.stop(clearRemote: true);
    } catch (_) {}
  }

  /// SIGTERM: stop every session and clear overlays.
  Future<void> stopAll() async {
    final ids = _byUser.keys.toList();
    for (final uid in ids) {
      await stopUser(uid);
    }
  }
}

class _Held {
  _Held({required this.bridge, required this.lastUsed});
  final SessionBridge bridge;
  DateTime lastUsed;
}

/// Convenience: AO base URL from env (Ada co-location).
String aoBaseUrlFromEnv() =>
    Platform.environment['AO_BASE_URL'] ??
    Platform.environment['COMSTAR_AO_BASE_URL'] ??
    'http://127.0.0.1:8765';

bool aoMtlsEnabledFromEnv() {
  final v = (Platform.environment['COMSTAR_AO_MTLS'] ??
          Platform.environment['AO_MTLS_ENABLED'] ??
          '')
      .trim()
      .toLowerCase();
  return v == '1' || v == 'true' || v == 'yes';
}

String aoMtlsDirFromEnv() =>
    Platform.environment['COMSTAR_AO_MTLS_DIR'] ??
    Platform.environment['AO_MTLS_MATERIAL_DIR'] ??
    '';
