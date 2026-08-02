import 'package:ao_reach/ao_reach.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/log.dart';

/// Thin interface over ao_reach [SessionBridge] for tests and stubs.
abstract class ReachSessionBridge {
  bool get isActive;

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
}

/// Default adapter wrapping the real ao_reach client.
class AoReachSessionBridge implements ReachSessionBridge {
  AoReachSessionBridge([SessionBridge? inner]) : _inner = inner ?? SessionBridge();

  final SessionBridge _inner;

  @override
  bool get isActive => _inner.isActive;

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
}

/// MCP bootstrap for COMSTAR — terminal MCP tunnel added in M5.4.
class ComstarMcpBootstrap implements SessionMcpBootstrap {
  const ComstarMcpBootstrap(this.config);

  final ComstarConfig config;

  @override
  Future<SessionMcpBootstrapResult> prepare(
    LocalMcpHost host, {
    required bool mcpTunnel,
  }) async {
    // Terminal MCP tunnel wiring lands in M5.4; agents-only for now.
    return SessionMcpBootstrapResult.empty;
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

  static const voiceAgentId = 'client.voice_responder';
  static const greeterAgentId = 'client.greeter';

  static const fullMcpProviders = [
    'client.terminal',
    'vision',
    'memory',
    'home_assistant',
    'time',
    'math',
  ];

  static const guestMcpProviders = [
    'client.terminal',
    'vision',
    'time',
    'math',
  ];

  static const greeterMcpProviders = [
    'memory',
    'time',
  ];

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
      ),
      overlayRoot: config.orchestration.overlayRoot,
      mcpBootstrap: _mcpBootstrap,
    );
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

  List<String> mcpProvidersForVoice() =>
      _guest ? guestMcpProviders : fullMcpProviders;

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
