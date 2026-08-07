/// Per-userid SessionBridge for the text channel (M11.5 / M11.0 decision).
///
/// Session id: `comstar-<uid>-channel` — **never** share `comstar-<uid>` with
/// the terminal (same-id stop clears the shared overlay). Continuity across
/// surfaces is via userid / KB, not a shared session overlay.
library;

import 'dart:async';
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';

/// Long-lived channel sessions keyed by COMSTAR userid.
class ChannelSessionManager {
  ChannelSessionManager({
    required this.baseUrl,
    required this.overlayRoot,
    this.token = '',
    this.ttlSeconds = 3600,
    this.idleTtl = const Duration(hours: 6),
    this.agentProviderId = 'client.text_responder',
  });

  final String baseUrl;
  final String overlayRoot;
  final String token;
  final int ttlSeconds;
  final Duration idleTtl;
  final String agentProviderId;

  final Map<String, _Held> _byUser = {};

  static String sessionIdFor(String userid) => 'comstar-$userid-channel';

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

    await bridge.start(
      config: ReachConnectionConfig(
        baseUrl: baseUrl,
        headers: headers,
        ttlSeconds: ttlSeconds,
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
