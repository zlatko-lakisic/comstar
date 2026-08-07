/// HTTP ingress for bridge → channel announcement delivery (M11.6).
///
/// Listens on Ada; Pi bridge POSTs `/v1/announce`. Token required when bound
/// beyond loopback. See CONTRACTS §11.
library;

import 'dart:convert';
import 'dart:io';

import 'package:comstar_channel/announce_gate.dart';
import 'package:comstar_channel/channel.dart';
import 'package:comstar_channel/identity.dart';

typedef AnnounceLog = void Function(
  String level,
  String evt,
  String msg, [
  Map<String, Object?>? data,
]);

/// Serve announce + health endpoints.
class AnnounceHttpServer {
  AnnounceHttpServer({
    required this.channel,
    required this.allowlist,
    required this.token,
    this.bindHost = '127.0.0.1',
    this.port = 8782,
    AnnounceLog? log,
  }) : _log = log ?? ((_, __, ___, [____]) {});

  final Channel channel;
  final Allowlist allowlist;
  final String token;
  final String bindHost;
  final int port;
  final AnnounceLog _log;

  HttpServer? _server;

  bool get _lanBound => bindHost != '127.0.0.1' && bindHost != '::1';

  Future<void> start() async {
    if (_lanBound && token.isEmpty) {
      throw StateError(
        'COMSTAR_CHANNEL_TOKEN required when binding beyond loopback',
      );
    }
    _server = await HttpServer.bind(bindHost, port);
    _log('info', 'announce_http_listen', 'Announce HTTP listening', {
      'bind': bindHost,
      'port': port,
      'lan': _lanBound,
    });
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && (path == '/health' || path == '/')) {
        await _json(req, 200, {'ok': true, 'proc': 'channel'});
        return;
      }
      if (req.method == 'POST' && path == '/v1/announce') {
        if (!_authorized(req)) {
          await _json(req, 401, {'ok': false, 'error': 'unauthorized'});
          return;
        }
        await _handleAnnounce(req);
        return;
      }
      await _json(req, 404, {'ok': false, 'error': 'not_found'});
    } catch (e) {
      _log('error', 'announce_http', '$e');
      try {
        await _json(req, 500, {'ok': false, 'error': 'internal'});
      } catch (_) {}
    }
  }

  bool _authorized(HttpRequest req) {
    if (!_lanBound && token.isEmpty) return true;
    if (token.isEmpty) return false;
    final header = req.headers.value('x-comstar-channel-token') ?? '';
    final q = req.uri.queryParameters['token'] ?? '';
    return header == token || q == token;
  }

  Future<void> _handleAnnounce(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(raw.isEmpty ? '{}' : raw);
      if (decoded is! Map) {
        await _json(req, 400, {'ok': false, 'error': 'body_must_be_object'});
        return;
      }
      body = Map<String, dynamic>.from(decoded);
    } catch (_) {
      await _json(req, 400, {'ok': false, 'error': 'invalid_json'});
      return;
    }

    final id = '${body['id'] ?? ''}'.trim();
    final recipient = '${body['recipient'] ?? ''}'.trim();
    final text = '${body['text'] ?? ''}'.trim();
    if (id.isEmpty || recipient.isEmpty || text.isEmpty) {
      await _json(req, 400, {
        'ok': false,
        'error': 'id_recipient_text_required',
      });
      return;
    }
    if (recipient == 'any') {
      await _json(req, 400, {
        'ok': false,
        'error': 'recipient_any_not_supported',
      });
      return;
    }

    final priority = AnnouncePriority.values.firstWhere(
      (p) => p.name == '${body['priority'] ?? 'urgent'}'.toLowerCase(),
      orElse: () => AnnouncePriority.urgent,
    );
    final present = body['present_at_terminal'] == true;
    final already = body['already_delivered'] == true;

    final decision = shouldDeliverToChannel(
      ChannelAnnounceContext(
        recipientUserid: recipient,
        priority: priority,
        recipientPresentAtTerminal: present,
        alreadyDelivered: already,
      ),
    );
    if (decision != ChannelDeliverDecision.deliver) {
      await _json(req, 200, {
        'ok': true,
        'delivered': false,
        'reason': decision.name,
      });
      return;
    }

    final senderId = allowlist.senderIdFor(recipient);
    if (senderId == null) {
      _log('warn', 'announce_no_sender', 'No Telegram mapping for userid', {
        'userid': recipient,
        'id': id,
      });
      await _json(req, 200, {
        'ok': true,
        'delivered': false,
        'reason': 'no_sender',
      });
      return;
    }

    await channel.send(senderId, text);
    _log('info', 'announce_channel_sent', 'Announcement delivered on channel', {
      'id': id,
      'userid': recipient,
      'chars': text.length,
    });
    await _json(req, 200, {
      'ok': true,
      'delivered': true,
      'sender_id': senderId,
    });
  }

  Future<void> _json(
    HttpRequest req,
    int status,
    Map<String, Object?> body,
  ) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}
