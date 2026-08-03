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

  Future<void> start({
    required ReachConnectionConfig config,
    required String overlayRoot,
    SessionMcpBootstrap mcpBootstrap,
  });

  Future<void> stop({bool clearRemote = true});

  /// Session-overlay MCP ids acknowledged by AO after [start].
  List<String> get registeredMcpIds;

  Future<Map<String, dynamic>> directAgent({
    required String agentProviderId,
    required String text,
    List<String>? mcpProviderIds,
    Duration? timeout,
  });
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
  List<String> get registeredMcpIds => _inner.registeredMcpIds;

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
            continue;
          }
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
        );
        mcps.add(
          sessionTunnelMcpEntry(
            clientId: def.clientId,
            description: def.description,
            alias: def.alias,
          ),
        );
        aliases.add(def.alias);
        logInfo('mcp_overlay_ready', 'Overlay MCP started', data: {
          'id': def.clientId,
          'alias': def.alias,
          'package': def.npxPackage,
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
      ),
      overlayRoot: config.orchestration.overlayRoot,
      mcpBootstrap: _mcpBootstrap,
    );

    if (_bridge.speechClient != null) {
      logInfo('speech_reach', 'Using AO-advertised speech sidecars', data: {
        'stt': _bridge.speechClient!.capabilities.sttBaseUrl,
        'tts': _bridge.speechClient!.capabilities.ttsBaseUrl,
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
  }

  Future<void> close() async {
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

  List<String> mcpProvidersForVoice() {
    if (_guest) return List.unmodifiable(guestMcpProviders);
    final registered = _bridge.registeredMcpIds;
    return [
      for (final id in fullMcpProviders)
        if (!id.startsWith('client.') || registered.contains(id)) id,
    ];
  }

  Future<String> directVoice(String text) async {
    final result = await _bridge.directAgent(
      agentProviderId: voiceAgentId,
      text: text,
      mcpProviderIds: mcpProvidersForVoice(),
      timeout: Duration(seconds: config.orchestration.timeoutSeconds),
    );
    return result['text']?.toString() ?? '';
  }

  Future<String> runGreeter(String userid) async {
    final result = await _bridge.directAgent(
      agentProviderId: greeterAgentId,
      text: 'Greet $userid who just arrived at the terminal.',
      mcpProviderIds: greeterMcpProviders,
      timeout: const Duration(seconds: 15),
    );
    return result['text']?.toString() ?? '';
  }
}
