import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'config.dart';
import 'envelope.dart';
import 'log.dart';

typedef MessageHandler = void Function(
  String clientRole,
  Envelope envelope,
  WebSocketChannel channel,
);

typedef BinaryHandler = void Function(
  String clientRole,
  List<int> data,
  WebSocketChannel channel,
);

class LocalWs {
  LocalWs({
    required this.config,
    this.kioskPort = 8777,
    this.audioPort = 8778,
    this.onMessage,
    this.onBinary,
  });

  final ComstarConfig config;
  final int kioskPort;
  final int audioPort;
  final MessageHandler? onMessage;
  final BinaryHandler? onBinary;

  HttpServer? _kioskServer;
  HttpServer? _audioServer;
  final _clients = <WebSocketChannel>[];
  final _clientsByRole = <String, List<WebSocketChannel>>{
    'kiosk': [],
    'audio': [],
  };
  bool _stopping = false;

  InternetAddress get bindAddress =>
      config.devLanBindingEnabled ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;

  Future<void> start() async {
    if (config.devLanBindingEnabled) {
      logWarn(
        'dev_lan_bind',
        'Dev mode: binding local WS to all interfaces (LAN)',
        data: {
          'kiosk_port': kioskPort,
          'audio_port': audioPort,
          'config': config.sourcePath,
        },
      );
    }

    _kioskServer = await _serve(
      port: kioskPort,
      role: 'kiosk',
      path: '/kiosk',
    );
    _audioServer = await _serve(
      port: audioPort,
      role: 'audio',
      path: '/audio',
    );

    logInfo(
      'ws_started',
      'Local WebSocket servers listening',
      data: {
        'bind': bindAddress.address,
        'kiosk_port': kioskPort,
        'audio_port': audioPort,
        'dev_lan': config.devLanBindingEnabled,
      },
    );
  }

  Future<HttpServer> _serve({
    required int port,
    required String role,
    required String path,
  }) async {
    final handler = Pipeline()
        .addMiddleware(_lanAuthMiddleware(role))
        .addHandler(
          (Request request) {
            if (request.url.path != path.substring(1)) {
              return Response.notFound('Not found');
            }
            return webSocketHandler((WebSocketChannel channel) {
              _handleConnection(channel, role);
            })(request);
          },
        );

    return shelf_io.serve(
      handler,
      bindAddress,
      port,
      shared: true,
    );
  }

  Middleware _lanAuthMiddleware(String role) {
    return (Handler inner) {
      return (Request request) {
        if (!config.devLanBindingEnabled) {
          return inner(request);
        }
        final headerToken =
            request.headers['x-comstar-lan-token'] ??
            request.headers['X-COMSTAR-LAN-Token'];
        if (headerToken == config.dev.lanToken) {
          return inner(request);
        }
        // Defer to first-message auth inside the connection handler.
        request.context['comstar_deferred_auth'] = true;
        return inner(request);
      };
    };
  }

  void sendToRole(String role, Envelope envelope) {
    for (final channel in List<WebSocketChannel>.from(
      _clientsByRole[role] ?? const [],
    )) {
      try {
        channel.sink.add(envelope.encode());
      } on Object catch (e) {
        logWarn('ws_send_failed', e.toString(), data: {'role': role});
      }
    }
  }

  bool hasRole(String role) => (_clientsByRole[role] ?? const []).isNotEmpty;

  void _handleConnection(WebSocketChannel channel, String role) {
    _clients.add(channel);
    _clientsByRole.putIfAbsent(role, () => []).add(channel);
    var authenticated = !config.devLanBindingEnabled;
    Timer? heartbeat;

    logInfo('ws_connect', 'Client connected', data: {'role': role});

    heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_stopping) return;
      try {
        channel.sink.add(
          Envelope.create(type: 'ping').encode(),
        );
      } on Object catch (e) {
        logWarn('ws_ping_failed', e.toString(), data: {'role': role});
      }
    });

    channel.stream.listen(
      (raw) {
        if (raw is List<int>) {
          onBinary?.call(role, raw, channel);
          return;
        }
        if (raw is! String) return;

        final envelope = Envelope.decode(raw);
        if (envelope == null) {
          logWarn(
            'ws_malformed',
            'Dropped malformed message',
            data: {'role': role},
          );
          return;
        }

        if (!authenticated) {
          final token = envelope.data['lan_token']?.toString();
          if (token == config.dev.lanToken) {
            authenticated = true;
            logInfo('ws_auth', 'LAN token accepted', data: {'role': role});
          } else {
            logWarn(
              'ws_auth_failed',
              'LAN auth required; closing connection',
              data: {'role': role},
            );
            channel.sink.close();
            return;
          }
        }

        if (envelope.type == 'pong') {
          return;
        }
        if (envelope.type == 'ping') {
          channel.sink.add(
            Envelope.create(type: 'pong', turnId: envelope.turnId).encode(),
          );
          return;
        }

        if (!_isKnownType(envelope.type, role)) {
          logWarn(
            'ws_unknown_type',
            'Unknown message type ignored',
            data: {'role': role, 'type': envelope.type},
          );
          return;
        }

        onMessage?.call(role, envelope, channel);
        _dispatchDefault(role, envelope, channel);
      },
      onDone: () {
        heartbeat?.cancel();
        _clients.remove(channel);
        _clientsByRole[role]?.remove(channel);
        logInfo('ws_disconnect', 'Client disconnected', data: {'role': role});
      },
      onError: (Object error) {
        heartbeat?.cancel();
        _clients.remove(channel);
        _clientsByRole[role]?.remove(channel);
        logWarn('ws_error', error.toString(), data: {'role': role});
      },
      cancelOnError: true,
    );
  }

  void _dispatchDefault(
    String role,
    Envelope envelope,
    WebSocketChannel channel,
  ) {
    switch (envelope.type) {
      case 'ready':
        logInfo(
          'client_ready',
          '$role client ready',
          data: envelope.data,
        );
        if (role == 'kiosk') {
          channel.sink.add(
            Envelope.create(
              type: 'config',
              data: {
                'avatarUrl': config.avatar.model,
                'mood': 'neutral',
                'cameraPose': 'front',
              },
            ).encode(),
          );
        }
      default:
        break;
    }
  }

  bool _isKnownType(String type, String role) {
    const kioskTypes = {
      'ready',
      'speak.started',
      'speak.ended',
      'span',
      'error',
      'ping',
      'pong',
    };
    const audioTypes = {
      'ready',
      'wake',
      'vad.speech_start',
      'vad.speech_end',
      'audio.begin',
      'audio.end',
      'level',
      'error',
      'ping',
      'pong',
    };
    const bridgeTypes = {
      'state',
      'speak',
      'speak.cancel',
      'listening',
      'thinking',
      'phase',
      'error',
      'config',
      'avatar.options',
      'health',
      'listen.start',
      'listen.stop',
      'wake.enable',
      'play',
      'mute',
      'ping',
      'pong',
    };

    if (bridgeTypes.contains(type)) return true;
    if (role == 'kiosk') return kioskTypes.contains(type);
    if (role == 'audio') return audioTypes.contains(type);
    return false;
  }

  /// Handles an inbound message and returns whether it was accepted.
  bool handleInbound(String role, Envelope envelope) {
    if (!_isKnownType(envelope.type, role)) {
      logWarn(
        'ws_unknown_type',
        'Unknown message type ignored',
        data: {'role': role, 'type': envelope.type},
      );
      return false;
    }
    return true;
  }

  Future<void> stop() async {
    _stopping = true;
    for (final client in List<WebSocketChannel>.from(_clients)) {
      await client.sink.close();
    }
    _clients.clear();
    await _kioskServer?.close(force: true);
    await _audioServer?.close(force: true);
    _kioskServer = null;
    _audioServer = null;
    logInfo('ws_stopped', 'Local WebSocket servers stopped');
  }
}
