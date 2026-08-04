import 'dart:async';
import 'dart:io';

import 'package:ao_reach/ao_reach.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/google/mcp_yaml.dart';
import 'package:comstar_bridge/google/token_store.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/speech_routing.dart';

/// Thin interface over ao_reach [SessionBridge] for tests and stubs.
abstract class ReachSessionBridge {
  bool get isActive;

  /// Non-null after [start] when AO advertised speech sidecars on `hello`.
  SpeechClient? get speechClient;

  /// Epoch seconds when the session overlay expires (from AO ack), if known.
  double? get expiresAt;

  /// Session-overlay agent ids acknowledged by AO after [start] / refresh.
  List<String> get registeredAgentIds;

  /// Session-overlay MCP ids acknowledged by AO after [start].
  List<String> get registeredMcpIds;

  Future<void> start({
    required ReachConnectionConfig config,
    required String overlayRoot,
    SessionMcpBootstrap mcpBootstrap,
  });

  Future<void> stop({bool clearRemote = true});

  Future<Map<String, dynamic>> directAgent({
    required String agentProviderId,
    required String text,
    List<String>? mcpProviderIds,
    Duration? timeout,
  });

  /// Re-register session overlay agents (extends AO overlay TTL).
  Future<void> refreshOverlay();
}

/// Default adapter wrapping the real ao_reach client.
class AoReachSessionBridge implements ReachSessionBridge {
  AoReachSessionBridge([SessionBridge? inner]) : _inner = inner ?? SessionBridge();

  final SessionBridge _inner;

  @override
  bool get isActive => _inner.isActive;

  @override
  SpeechClient? get speechClient => _inner.speechClient;

  @override
  double? get expiresAt => _inner.expiresAt;

  @override
  List<String> get registeredAgentIds => _inner.registeredAgentIds;

  @override
  List<String> get registeredMcpIds => _inner.registeredMcpIds;

  @override
  Future<void> start({
    required ReachConnectionConfig config,
    required String overlayRoot,
    SessionMcpBootstrap mcpBootstrap = const EmptySessionMcpBootstrap(),
  }) =>
      _inner.start(
        config: config,
        overlayRoot: overlayRoot,
        mcpBootstrap: mcpBootstrap,
      );

  @override
  Future<void> stop({bool clearRemote = true}) =>
      _inner.stop(clearRemote: clearRemote);

  @override
  Future<Map<String, dynamic>> directAgent({
    required String agentProviderId,
    required String text,
    List<String>? mcpProviderIds,
    Duration? timeout,
  }) =>
      _inner.directAgent(
        agentProviderId: agentProviderId,
        text: text,
        mcpProviderIds: mcpProviderIds,
        timeout: timeout ?? const Duration(minutes: 5),
      );

  @override
  Future<void> refreshOverlay() => _inner.refreshOverlay();
}

/// MCP bootstrap for COMSTAR — tunnelled client MCPs (terminal + overlay YAML).
class ComstarMcpBootstrap implements SessionMcpBootstrap {
  ComstarMcpBootstrap(
    this.config, {
    GoogleTokenStore? tokenStore,
  }) : tokenStore = tokenStore ?? GoogleTokenStore();

  final ComstarConfig config;
  final GoogleTokenStore tokenStore;

  /// When true, skip all tunnel MCP registration (CONTRACTS §5 guests).
  bool guest = false;

  /// Active face userid (for per-user Google refresh tokens).
  String? userid;

  @override
  Future<SessionMcpBootstrapResult> prepare(
    LocalMcpHost host, {
    required bool mcpTunnel,
  }) async {
    if (guest) {
      return SessionMcpBootstrapResult.empty;
    }

    final mcps = <Map<String, dynamic>>[];
    final warnings = <String>[];
    final aliases = <String>[];

    if (!mcpTunnel) {
      warnings.add('mcp tunnel disabled; client MCPs not registered');
      return SessionMcpBootstrapResult(warnings: warnings);
    }

    await _maybeStartTerminal(host, mcps, warnings, aliases);
    await _startOverlayNpxMcps(host, mcps, warnings, aliases);

    return SessionMcpBootstrapResult(
      mcps: mcps,
      warnings: warnings,
      activeTunnelBareIds: aliases,
    );
  }

  Future<void> _maybeStartTerminal(
    LocalMcpHost host,
    List<Map<String, dynamic>> mcps,
    List<String> warnings,
    List<String> aliases,
  ) async {
    // Tunnelled client.terminal hangs AO tool loading on current Pi/AO path.
    // Sleep/volume are handled in-bridge via terminal_intent until the tunnel
    // exchange is proven. HTTP server code remains in mcp/terminal_mcp.
    if (Platform.environment['COMSTAR_TERMINAL_MCP'] != '1') {
      warnings.add(
        'terminal MCP overlay skipped (set COMSTAR_TERMINAL_MCP=1 to enable)',
      );
      return;
    }

    try {
      final mcpRoot = _resolveMcpRoot();
      final port = await host.pickFreePort();
      final python = await _resolvePython();
      final process = await Process.start(
        python,
        [
          '-m',
          'terminal_mcp',
          '--http',
          '--host',
          '127.0.0.1',
          '--port',
          '$port',
        ],
        workingDirectory: Directory.systemTemp.path,
        environment: {
          ...Platform.environment,
          'PYTHONPATH': mcpRoot,
          'COMSTAR_CONTROL_URL': 'http://127.0.0.1:8776',
          'COMSTAR_MCP_HTTP': '1',
          'COMSTAR_MCP_HTTP_PORT': '$port',
        },
        runInShell: false,
      );
      await host.attachManagedLoopback(
        alias: 'terminal',
        port: port,
        process: process,
      );
      logInfo('mcp_terminal_ready', 'Terminal MCP HTTP listening', data: {
        'port': port,
      });
      mcps.add(
        sessionTunnelMcpEntry(
          clientId: 'client.terminal',
          description: 'COMSTAR terminal control (sleep, volume, display)',
          alias: 'terminal',
        ),
      );
      aliases.add('terminal');
    } catch (e) {
      logWarn('mcp_terminal_bootstrap', 'Terminal MCP unavailable: $e');
      warnings.add('terminal MCP soft-fail: $e');
    }
  }

  Future<void> _startOverlayNpxMcps(
    LocalMcpHost host,
    List<Map<String, dynamic>> mcps,
    List<String> warnings,
    List<String> aliases,
  ) async {
    final defs = loadOverlayMcpProviders(config.orchestration.overlayRoot);
    for (final def in defs) {
      if (def.transport != 'stdio_tunnel') {
        warnings.add('overlay MCP ${def.id}: unsupported transport');
        continue;
      }
      if (!def.guestAllowed && guest) continue;

      try {
        final extraEnv = <String, String>{};
        var skip = false;
        for (final key in def.envFrom) {
          if (key == 'GOOGLE_REFRESH_TOKEN') {
            final uid = userid;
            if (uid == null || uid.isEmpty) {
              warnings.add('${def.id}: no userid for refresh token');
              skip = true;
              break;
            }
            final token = await tokenStore.readRefreshToken(uid);
            if (token == null) {
              warnings.add(
                '${def.id}: no Google tokens for $uid (say connect my Google)',
              );
              skip = true;
              break;
            }
            extraEnv[key] = token;
            // Desktop-minted tokens must refresh with the Desktop client.
            final kind = await tokenStore.readClientKind(uid);
            if (kind == GoogleOAuthClientKind.desktop) {
              final deskId =
                  Platform.environment['GOOGLE_DESKTOP_CLIENT_ID']?.trim() ?? '';
              final deskSecret =
                  Platform.environment['GOOGLE_DESKTOP_CLIENT_SECRET']?.trim() ??
                      '';
              if (deskId.isNotEmpty && deskSecret.isNotEmpty) {
                extraEnv['GOOGLE_CLIENT_ID'] = deskId;
                extraEnv['GOOGLE_CLIENT_SECRET'] = deskSecret;
              }
            }
            continue;
          }
          if (extraEnv.containsKey(key)) continue;
          final v = Platform.environment[key]?.trim() ?? '';
          if (v.isEmpty) {
            warnings.add('${def.id}: missing env $key');
            skip = true;
            break;
          }
          extraEnv[key] = v;
        }
        if (skip) continue;
        if (def.requiresTokens && !extraEnv.containsKey('GOOGLE_REFRESH_TOKEN')) {
          warnings.add('${def.id}: requires_tokens but no refresh token env');
          continue;
        }

        await host.startNpxPackage(
          alias: def.alias,
          package: def.npxPackage,
          extraEnv: extraEnv,
          readyTimeout: const Duration(seconds: 90),
        );
        mcps.add(
          sessionTunnelMcpEntry(
            clientId: def.clientId,
            description: def.description,
            alias: def.alias,
          ),
        );
        aliases.add(def.alias);
        final localEntry =
            await host.resolveInstalledPackageEntry(def.npxPackage);
        logInfo('mcp_overlay_ready', 'Overlay MCP started', data: {
          'id': def.clientId,
          'alias': def.alias,
          'package': def.npxPackage,
          'entry': localEntry ?? 'npx',
        });
      } catch (e) {
        logWarn('mcp_overlay_bootstrap', 'Overlay MCP ${def.id} unavailable: $e');
        warnings.add('${def.id} soft-fail: $e');
      }
    }
  }

  /// Directory that contains the `terminal_mcp` package (`…/mcp`).
  String _resolveMcpRoot() {
    final overlay = Directory(config.orchestration.overlayRoot).absolute;
    // overlays/comstar → repo root → mcp
    final repoRoot = overlay.parent.parent;
    return '${repoRoot.path}/mcp';
  }

  Future<String> _resolvePython() async {
    for (final c in const ['python3', 'python']) {
      try {
        final r = await Process.run(c, ['--version']);
        if (r.exitCode == 0) return c;
      } catch (_) {}
    }
    throw StateError('python3 not found for terminal MCP');
  }
}

/// COMSTAR session manager per CONTRACTS §4.
class ComstarSession {
  ComstarSession({
    required this.config,
    ReachSessionBridge? bridge,
    SessionMcpBootstrap? mcpBootstrap,
  })  : _bridge = bridge ?? AoReachSessionBridge(),
        _mcpBootstrap = mcpBootstrap ?? ComstarMcpBootstrap(config);

  final ComstarConfig config;
  final ReachSessionBridge _bridge;
  final SessionMcpBootstrap _mcpBootstrap;

  String? _userid;
  bool _guest = false;
  Timer? _keepAliveTimer;
  Future<void>? _ensureInFlight;

  /// Lead time before overlay expiry to refresh (fraction of configured TTL).
  static const double _renewLeadFraction = 0.25;

  /// Minimum keep-alive / renew check interval.
  static const int _minKeepAliveSec = 60;

  bool get isOpen => _bridge.isActive;
  String? get userid => _userid;
  bool get guest => _guest;

  /// Reach STT/TTS client when AO ≥ 1.28 advertised `hello.speech`; else null.
  SpeechClient? get speechClient => _bridge.speechClient;

  static const voiceAgentId = 'client.voice_responder';
  static const greeterAgentId = 'client.greeter';

  /// Hosted / tunnel MCP ids for known-user voice turns.
  ///
  /// Do not list catalog-missing ids (`memory`, `time`, `math`, `vision`).
  /// `client.terminal` is registered on the overlay for tunnel bring-up, but is
  /// not passed here: loading it via AO currently hangs the turn (~15s).
  /// Sleep/volume are handled locally in the bridge (`terminal_intent.dart`).
  /// `client.google_workspace` is included only when Reach acknowledges it.
  static const fullMcpProviders = <String>[
    'home_assistant',
    'client.google_workspace',
  ];

  static const guestMcpProviders = <String>[
    // Restricted: no home_assistant / terminal control.
  ];

  static const greeterMcpProviders = <String>[];

  /// Opens or switches AO session. Identity change closes the prior session first.
  Future<void> open({required String userid, bool guest = false}) async {
    if (_bridge.isActive && _userid == userid && _guest == guest) {
      return;
    }
    if (_bridge.isActive) {
      await close();
    }

    _userid = userid;
    _guest = guest;

    final boot = _mcpBootstrap;
    if (boot is ComstarMcpBootstrap) {
      boot.guest = guest;
      boot.userid = userid;
    }

    final headers = <String, String>{
      'x-agentic-user-name': guest ? 'guest' : userid,
      'x-agentic-session-id': 'comstar-$userid',
    };
    if (config.orchestration.token.isNotEmpty) {
      headers['x-warpgate-token'] = config.orchestration.token;
    }

    logInfo('session_open', 'Opening AO session', data: {
      'userid': userid,
      'guest': guest,
    });

    await _bridge.start(
      config: ReachConnectionConfig(
        baseUrl: config.orchestration.baseUrl,
        headers: headers,
        ttlSeconds: config.orchestration.ttlSeconds,
        questionIdPrefix: 'comstar',
        speechToken: speechTokenFromEnv(),
        speechSttBaseUrlOverride: speechSttOverrideFromEnv(),
        speechTtsBaseUrlOverride: speechTtsOverrideFromEnv(),
      ),
      overlayRoot: config.orchestration.overlayRoot,
      mcpBootstrap: _mcpBootstrap,
    );

    logInfo('session_mcp', 'Session MCP providers', data: {
      'registered': _bridge.registeredMcpIds,
      'agents': _bridge.registeredAgentIds,
      'voice': mcpProvidersForVoice(),
      'expires_at': _bridge.expiresAt,
    });

    if (_bridge.speechClient != null) {
      logInfo('speech_reach', 'Using AO-advertised speech sidecars', data: {
        'stt': _bridge.speechClient!.capabilities.sttBaseUrl,
        'tts': _bridge.speechClient!.capabilities.ttsBaseUrl,
        'stt_override': speechSttOverrideFromEnv(),
        'tts_override': speechTtsOverrideFromEnv(),
      });
    } else {
      logInfo(
        'speech_fallback',
        'No Reach speech; using COMSTAR_STT_URL / COMSTAR_TTS_URL',
        data: {
          'stt_env': Platform.environment['COMSTAR_STT_URL'] != null,
          'tts_env': Platform.environment['COMSTAR_TTS_URL'] != null,
        },
      );
    }
    _armKeepAlive();
  }

  Future<void> close() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    if (!_bridge.isActive) {
      _userid = null;
      _guest = false;
      return;
    }
    logInfo('session_close', 'Closing AO session', data: {
      'userid': _userid,
      'guest': _guest,
    });
    await _bridge.stop(clearRemote: true);
    _userid = null;
    _guest = false;
  }

  /// Ensure the AO WebSocket + session overlay are usable.
  ///
  /// - Dead / disconnected bridge → full reopen with the last identity.
  /// - Overlay near expiry or missing voice agent → refresh overlay.
  /// - Refresh failure → full reopen.
  Future<void> ensureReady({bool quiet = false}) async {
    final userid = _userid;
    if (userid == null) {
      throw StateError('No session identity — call open() first');
    }
    final existing = _ensureInFlight;
    if (existing != null) {
      await existing;
      return;
    }
    final done = _ensureReadyBody(userid: userid, quiet: quiet);
    _ensureInFlight = done;
    try {
      await done;
    } finally {
      if (identical(_ensureInFlight, done)) {
        _ensureInFlight = null;
      }
    }
  }

  Future<void> _ensureReadyBody({
    required String userid,
    required bool quiet,
  }) async {
    final guest = _guest;

    if (!_bridge.isActive) {
      logWarn('session_renew', 'AO session inactive; reopening', data: {
        'userid': userid,
        'guest': guest,
      });
      await _reopen(userid: userid, guest: guest);
      return;
    }

    if (!_overlayNeedsRenewal) return;

    try {
      if (!quiet) {
        logInfo('session_overlay_renew', 'Refreshing session overlay', data: {
          'userid': userid,
          'expires_at': _bridge.expiresAt,
          'agents': _bridge.registeredAgentIds,
        });
      }
      await _bridge.refreshOverlay();
      if (!quiet) {
        logInfo('session_overlay_renewed', 'Session overlay refreshed', data: {
          'expires_at': _bridge.expiresAt,
          'agents': _bridge.registeredAgentIds,
        });
      }
    } catch (e) {
      logWarn('session_overlay_renew_failed', e.toString(), data: {
        'userid': userid,
      });
      await _reopen(userid: userid, guest: guest);
    }
  }

  bool get _overlayNeedsRenewal {
    final exp = _bridge.expiresAt;
    if (exp == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final ttl = config.orchestration.ttlSeconds.clamp(30, 86400);
    final lead = (ttl * _renewLeadFraction).clamp(30.0, 3600.0);
    return nowSec >= (exp - lead);
  }

  Future<void> _reopen({required String userid, required bool guest}) async {
    // Force a fresh start even if the adapter still looks half-alive.
    try {
      await _bridge.stop(clearRemote: true);
    } catch (_) {}
    _userid = null;
    _guest = false;
    await open(userid: userid, guest: guest);
  }

  void _armKeepAlive() {
    _keepAliveTimer?.cancel();
    final ttl = config.orchestration.ttlSeconds.clamp(30, 86400);
    // Check often enough to catch expiry before AO drops the overlay.
    final intervalSec =
        (ttl * _renewLeadFraction).round().clamp(_minKeepAliveSec, 3600);
    _keepAliveTimer = Timer.periodic(Duration(seconds: intervalSec), (_) {
      if (_userid == null) return;
      unawaited(() async {
        try {
          await ensureReady(quiet: true);
        } catch (e) {
          logWarn('session_keepalive_failed', e.toString());
        }
      }());
    });
  }

  List<String> mcpProvidersForVoice({String? utterance}) {
    if (_guest) return List.unmodifiable(guestMcpProviders);
    final registered = _bridge.registeredMcpIds;
    // Workspace questions: Google alone (HA discovery races the tunnel).
    if (utterance != null && _looksLikeGoogleWorkspace(utterance)) {
      if (registered.contains('client.google_workspace')) {
        return const ['client.google_workspace'];
      }
    }
    // Default voice: stock MCP only. Attaching client.google_workspace (tunnel
    // URL host 127.0.0.1) makes CrewAI mint OpenAI function names that start
    // with a digit → every turn fails with the "could not get an answer" sorry
    // line until AO normalizes tunnel URLs to localhost (post-1.28.0).
    return [
      for (final id in fullMcpProviders)
        if (!id.startsWith('client.')) id,
    ];
  }

  static bool _looksLikeGoogleWorkspace(String text) {
    final t = text.toLowerCase();
    return RegExp(
      r'\b(google|gmail|calendar|g-?cal|drive|workspace|inbox|email|e-?mail|'
      r'meeting|appointments?|schedule)\b',
    ).hasMatch(t);
  }

  Future<String> directVoice(String text) async {
    await ensureReady();
    final mcps = mcpProvidersForVoice(utterance: text);
    final googleOnly = mcps.length == 1 && mcps.first == 'client.google_workspace';
    final haOnly = mcps.length == 1 && mcps.first == 'home_assistant';
    final needsTools = googleOnly || haOnly || mcps.length > 1;
    final timeoutSec = needsTools && config.orchestration.timeoutSeconds < 60
        ? 60
        : config.orchestration.timeoutSeconds;
    final prompt = _voicePromptForMcps(text: text, mcps: mcps);
    try {
      final result = await _bridge.directAgent(
        agentProviderId: voiceAgentId,
        text: prompt,
        mcpProviderIds: mcps,
        timeout: Duration(seconds: timeoutSec),
      );
      return result['text']?.toString() ?? '';
    } catch (e) {
      // Overlay can still vanish between ensureReady and the call.
      final msg = e.toString();
      final overlayGone = msg.contains('unknown agent_provider_id') &&
          msg.contains(voiceAgentId);
      final bridgeDead = msg.contains('not active') ||
          msg.contains('session bridge') ||
          msg.contains('disconnected');
      if (!overlayGone && !bridgeDead) rethrow;
      logWarn(
        'session_renew_retry',
        'AO call failed; renewing session and retrying',
        data: {'error': msg},
      );
      await _reopen(userid: _userid!, guest: _guest);
      final result = await _bridge.directAgent(
        agentProviderId: voiceAgentId,
        text: _voicePromptForMcps(
          text: text,
          mcps: mcpProvidersForVoice(utterance: text),
        ),
        mcpProviderIds: mcpProvidersForVoice(utterance: text),
        timeout: Duration(seconds: timeoutSec),
      );
      return result['text']?.toString() ?? '';
    }
  }

  /// Steer qwen tool-use: bare questions often skip MCP and invent "no access".
  static String _voicePromptForMcps({
    required String text,
    required List<String> mcps,
  }) {
    final trimmed = text.trim();
    if (mcps.contains('home_assistant')) {
      return 'Home Assistant tools are attached. Before answering, call '
          'GetLiveContext (or equivalent HA state tools). For irrigation or '
          'watering, use sensor.irrigation_7d_*_minutes and *_zone_history; '
          'if 7-day minutes are 0, say so. For WAN IP use MikroTik ether1 '
          'WAN attributes; for bandwidth use mikrotik_*_rx/_tx (kB/s); for '
          'speedtest use sensor.speedtest_*. Do not claim you lack access '
          'without a tool call.\n\nResident said: $trimmed';
    }
    if (mcps.contains('client.google_workspace')) {
      return 'Google Workspace tools are attached. Call the matching Gmail, '
          'Calendar, or Drive tools before answering. Do not invent data.\n\n'
          'Resident said: $trimmed';
    }
    return trimmed;
  }

  Future<String> runGreeter(String userid) async {
    await ensureReady();
    try {
      final result = await _bridge.directAgent(
        agentProviderId: greeterAgentId,
        text: 'Greet $userid who just arrived at the terminal.',
        mcpProviderIds: greeterMcpProviders,
        timeout: const Duration(seconds: 15),
      );
      return result['text']?.toString() ?? '';
    } catch (e) {
      final msg = e.toString();
      final overlayGone = msg.contains('unknown agent_provider_id');
      final bridgeDead = msg.contains('not active') ||
          msg.contains('session bridge') ||
          msg.contains('disconnected');
      if (!overlayGone && !bridgeDead) rethrow;
      logWarn(
        'session_renew_retry',
        'Greeter failed; renewing session and retrying',
        data: {'error': msg},
      );
      await _reopen(userid: _userid!, guest: _guest);
      final result = await _bridge.directAgent(
        agentProviderId: greeterAgentId,
        text: 'Greet $userid who just arrived at the terminal.',
        mcpProviderIds: greeterMcpProviders,
        timeout: const Duration(seconds: 15),
      );
      return result['text']?.toString() ?? '';
    }
  }
}
