/// Signal channel via signal-cli JSON-RPC HTTP daemon (ADR 0015).
///
/// Operator runs `signal-cli -a +E164 daemon --http 127.0.0.1:8080` (linked
/// once with `signal-cli link`). COMSTAR talks to `/api/v1/rpc` + SSE events.
///
/// Env:
///   COMSTAR_SIGNAL_URL       e.g. http://127.0.0.1:8080
///   COMSTAR_SIGNAL_ACCOUNT   E.164 account (optional if daemon is single-acct)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:comstar_channel/channel.dart';

bool signalConfiguredFromEnv() {
  final url = Platform.environment['COMSTAR_SIGNAL_URL']?.trim();
  return url != null && url.isNotEmpty;
}

String? signalAccountFromEnv() {
  final a = Platform.environment['COMSTAR_SIGNAL_ACCOUNT']?.trim();
  if (a == null || a.isEmpty) return null;
  return normalizeSignalSenderId(a);
}

/// Prefer E.164 with leading +.
String normalizeSignalSenderId(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return t;
  if (t.startsWith('+')) {
    return '+${t.substring(1).replaceAll(RegExp(r'\D'), '')}';
  }
  // UUID-style Signal recipients stay as-is.
  if (RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(t)) return t;
  return '+${t.replaceAll(RegExp(r'\D'), '')}';
}

class SignalChannel implements Channel {
  SignalChannel({
    required this.baseUrl,
    this.account = '',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  factory SignalChannel.fromEnv({http.Client? httpClient}) {
    return SignalChannel(
      baseUrl: Platform.environment['COMSTAR_SIGNAL_URL'] ?? '',
      account: Platform.environment['COMSTAR_SIGNAL_ACCOUNT'] ?? '',
      httpClient: httpClient,
    );
  }

  final String baseUrl;
  final String account;
  final http.Client _http;

  final _inbound = StreamController<ChannelInbound>.broadcast();
  StreamSubscription<String>? _sseSub;
  http.Client? _sseClient;
  var _running = false;
  var _rpcId = 1;

  @override
  String get providerId => 'signal';

  @override
  Stream<ChannelInbound> get inbound => _inbound.stream;

  String get _root => baseUrl.replaceAll(RegExp(r'/+$'), '');

  Uri get _rpcUri => Uri.parse('$_root/api/v1/rpc');
  Uri get _eventsUri => Uri.parse('$_root/api/v1/events');

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    unawaited(_listenEvents());
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _sseSub?.cancel();
    _sseSub = null;
    _sseClient?.close();
    _sseClient = null;
  }

  @override
  Future<void> setTyping(String senderId, ChannelTyping state) async {}

  Future<Map<String, dynamic>> _rpc(
    String method,
    Map<String, Object?> params,
  ) async {
    final id = _rpcId++;
    final body = <String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      'params': {
        if (account.trim().isNotEmpty)
          'account': normalizeSignalSenderId(account),
        ...params,
      },
      'id': id,
    };
    final res = await _http
        .post(
          _rpcUri,
          headers: {'Content-Type': 'application/json; charset=UTF-8'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('signal-cli rpc HTTP ${res.statusCode}: ${res.body}');
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) {
      throw StateError('signal-cli rpc: non-object response');
    }
    final map = Map<String, dynamic>.from(decoded);
    if (map['error'] != null) {
      throw StateError('signal-cli rpc error: ${map['error']}');
    }
    return map;
  }

  @override
  Future<void> send(String senderId, String text) async {
    final to = normalizeSignalSenderId(senderId);
    await _rpc('send', {
      'recipient': [to],
      'message': text,
    });
  }

  Future<void> _listenEvents() async {
    while (_running) {
      try {
        _sseClient?.close();
        final client = http.Client();
        _sseClient = client;
        final req = http.Request('GET', _eventsUri);
        req.headers['Accept'] = 'text/event-stream';
        final res = await client.send(req).timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) {
          await Future<void>.delayed(const Duration(seconds: 3));
          continue;
        }
        final lines = res.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        await for (final line in lines) {
          if (!_running) break;
          if (!line.startsWith('data:')) continue;
          final payload = line.substring(5).trim();
          if (payload.isEmpty || payload == ':') continue;
          try {
            final decoded = jsonDecode(payload);
            _ingestEvent(decoded);
          } catch (_) {}
        }
      } catch (_) {
        if (!_running) break;
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
  }

  void _ingestEvent(Object? decoded) {
    if (decoded is! Map) return;
    // Notification: {method: receive, params: {envelope: {...}}}
    final method = '${decoded['method'] ?? ''}';
    Map? params = decoded['params'] is Map
        ? Map<String, dynamic>.from(decoded['params'] as Map)
        : null;
    if (method != 'receive' && params == null) {
      // Some gateways wrap result.
      final result = decoded['result'];
      if (result is Map) params = Map<String, dynamic>.from(result);
    }
    if (params == null) return;
    final envelope = params['envelope'];
    if (envelope is! Map) return;
    final env = Map<String, dynamic>.from(envelope);
    final data = env['dataMessage'];
    if (data is! Map) return;
    final text = '${data['message'] ?? ''}'.trim();
    if (text.isEmpty) return;
    var source = '${env['sourceNumber'] ?? env['source'] ?? ''}'.trim();
    if (source.isEmpty) {
      source = '${env['sourceUuid'] ?? ''}'.trim();
    }
    if (source.isEmpty) return;
    final senderId = normalizeSignalSenderId(source);
    if (!_inbound.isClosed) {
      _inbound.add(ChannelInbound(
        provider: 'signal',
        senderId: senderId,
        text: text,
        raw: decoded,
      ));
    }
  }

  /// Test helper: inject a receive notification.
  void debugInjectReceive({
    required String senderId,
    required String text,
  }) {
    _ingestEvent({
      'jsonrpc': '2.0',
      'method': 'receive',
      'params': {
        'envelope': {
          'sourceNumber': senderId,
          'dataMessage': {'message': text},
        },
      },
    });
  }
}
