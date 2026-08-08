/// HTTP ingress for bridge → channel announce + QR pairing (M11.6 / ADR 0015).
///
/// Also hosts WhatsApp Cloud API webhook (`/v1/whatsapp/webhook`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:comstar_channel/announce_gate.dart';
import 'package:comstar_channel/channel.dart';
import 'package:comstar_channel/identity_resolver.dart';
import 'package:comstar_channel/mux.dart';
import 'package:comstar_channel/pairing.dart';
import 'package:comstar_channel/signal.dart';
import 'package:comstar_channel/telegram.dart';
import 'package:comstar_channel/whatsapp.dart';

typedef AnnounceLog = void Function(
  String level,
  String evt,
  String msg, [
  Map<String, Object?>? data,
]);

/// Serve announce, pairing, WhatsApp webhook, and health endpoints.
class AnnounceHttpServer {
  AnnounceHttpServer({
    required this.channel,
    required this.identity,
    required this.pairing,
    required this.token,
    this.bindHost = '127.0.0.1',
    this.port = 8782,
    this.telegramBotUsername = '',
    this.whatsappDisplayPhone = '',
    this.signalAccount = '',
    this.whatsapp,
    AnnounceLog? log,
  }) : _log = log ?? ((_, __, ___, [____]) {});

  final Channel channel;
  final IdentityResolver identity;
  final PairingManager pairing;
  final String token;
  final String bindHost;
  final int port;

  /// Telegram @username without @ (for deep links).
  String telegramBotUsername;

  /// Digits for wa.me pairing QR.
  String whatsappDisplayPhone;

  /// E.164 for signal.me pairing QR.
  String signalAccount;

  /// Optional Cloud API channel for webhook ingest.
  WhatsAppChannel? whatsapp;

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
        await _json(req, 200, {
          'ok': true,
          'proc': 'channel',
          'providers': {
            'telegram': true,
            'whatsapp': whatsappConfiguredFromEnv(),
            'signal': signalConfiguredFromEnv(),
          },
        });
        return;
      }
      if (path == '/v1/whatsapp/webhook') {
        await _handleWhatsAppWebhook(req);
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
      if (req.method == 'POST' && path == '/v1/pairing/begin') {
        if (!_authorized(req)) {
          await _json(req, 401, {'ok': false, 'error': 'unauthorized'});
          return;
        }
        await _handlePairingBegin(req);
        return;
      }
      if (req.method == 'GET' && path == '/v1/pairing/status') {
        if (!_authorized(req)) {
          await _json(req, 401, {'ok': false, 'error': 'unauthorized'});
          return;
        }
        await _handlePairingStatus(req);
        return;
      }
      if (req.method == 'POST' && path == '/v1/pairing/cancel') {
        if (!_authorized(req)) {
          await _json(req, 401, {'ok': false, 'error': 'unauthorized'});
          return;
        }
        await _handlePairingCancel(req);
        return;
      }
      if (req.method == 'POST' && path == '/v1/pairing/unlink') {
        if (!_authorized(req)) {
          await _json(req, 401, {'ok': false, 'error': 'unauthorized'});
          return;
        }
        await _handlePairingUnlink(req);
        return;
      }
      if (req.method == 'GET' && path == '/v1/pairing/links') {
        if (!_authorized(req)) {
          await _json(req, 401, {'ok': false, 'error': 'unauthorized'});
          return;
        }
        await _handlePairingLinks(req);
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

  Future<void> _handleWhatsAppWebhook(HttpRequest req) async {
    final wa = whatsapp;
    if (wa == null) {
      await _json(req, 503, {'ok': false, 'error': 'whatsapp_not_configured'});
      return;
    }
    if (req.method == 'GET') {
      final mode = req.uri.queryParameters['hub.mode'] ?? '';
      final token = req.uri.queryParameters['hub.verify_token'] ?? '';
      final challenge = req.uri.queryParameters['hub.challenge'] ?? '';
      final ok = wa.verifyWebhook(
        mode: mode,
        token: token,
        challenge: challenge,
      );
      if (ok == null) {
        req.response.statusCode = 403;
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.text;
      req.response.write(ok);
      await req.response.close();
      return;
    }
    if (req.method == 'POST') {
      final raw = await utf8.decoder.bind(req).join();
      try {
        final decoded = jsonDecode(raw.isEmpty ? '{}' : raw);
        wa.ingestWebhook(decoded);
      } catch (e) {
        _log('warn', 'whatsapp_webhook_parse', '$e');
      }
      // Always 200 quickly so Meta does not retry-storm.
      await _json(req, 200, {'ok': true});
      return;
    }
    await _json(req, 405, {'ok': false, 'error': 'method_not_allowed'});
  }

  Future<Map<String, dynamic>?> _readJson(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    try {
      final decoded = jsonDecode(raw.isEmpty ? '{}' : raw);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> _handlePairingBegin(HttpRequest req) async {
    final body = await _readJson(req);
    if (body == null) {
      await _json(req, 400, {'ok': false, 'error': 'invalid_json'});
      return;
    }
    final userid = '${body['userid'] ?? ''}'.trim();
    final provider = '${body['provider'] ?? ''}'.trim().toLowerCase();
    if (userid.isEmpty || provider.isEmpty) {
      await _json(req, 400, {
        'ok': false,
        'error': 'userid_provider_required',
      });
      return;
    }

    if (provider == 'telegram') {
      final bot = telegramBotUsername.trim().replaceFirst(RegExp(r'^@'), '');
      if (bot.isEmpty) {
        await _json(req, 503, {
          'ok': false,
          'error': 'telegram_bot_username_unknown',
        });
        return;
      }
      final attempt = await pairing.begin(
        userid: userid,
        provider: provider,
        urlBuilder: (token) => PairingManager.telegramPairUrl(
          botUsername: bot,
          token: token,
        ),
      );
      await _json(req, 200, {'ok': true, ...attempt.toPublicJson()});
      return;
    }

    if (provider == 'whatsapp') {
      if (!whatsappConfiguredFromEnv()) {
        await _json(req, 503, {'ok': false, 'error': 'whatsapp_not_configured'});
        return;
      }
      final phone = whatsappDisplayPhone.trim().isNotEmpty
          ? whatsappDisplayPhone
          : (whatsappDisplayPhoneFromEnv() ?? '');
      if (phone.isEmpty) {
        await _json(req, 503, {
          'ok': false,
          'error': 'whatsapp_display_phone_missing',
        });
        return;
      }
      final attempt = await pairing.begin(
        userid: userid,
        provider: provider,
        urlBuilder: (token) => PairingManager.whatsappPairUrl(
          displayPhone: phone,
          token: token,
        ),
      );
      await _json(req, 200, {'ok': true, ...attempt.toPublicJson()});
      return;
    }

    if (provider == 'signal') {
      if (!signalConfiguredFromEnv()) {
        await _json(req, 503, {'ok': false, 'error': 'signal_not_configured'});
        return;
      }
      final acct = signalAccount.trim().isNotEmpty
          ? signalAccount
          : (signalAccountFromEnv() ?? '');
      if (acct.isEmpty) {
        await _json(req, 503, {
          'ok': false,
          'error': 'signal_account_missing',
        });
        return;
      }
      final attempt = await pairing.begin(
        userid: userid,
        provider: provider,
        urlBuilder: (_) => PairingManager.signalPairUrl(accountE164: acct),
      );
      await _json(req, 200, {'ok': true, ...attempt.toPublicJson()});
      return;
    }

    await _json(req, 400, {
      'ok': false,
      'error': 'unknown_provider',
      'provider': provider,
    });
  }

  Future<void> _handlePairingStatus(HttpRequest req) async {
    final id = (req.uri.queryParameters['id'] ?? '').trim();
    if (id.isEmpty) {
      await _json(req, 400, {'ok': false, 'error': 'id_required'});
      return;
    }
    final attempt = pairing.get(id);
    if (attempt == null) {
      await _json(req, 404, {'ok': false, 'error': 'not_found'});
      return;
    }
    await _json(req, 200, {'ok': true, ...attempt.toPublicJson()});
  }

  Future<void> _handlePairingCancel(HttpRequest req) async {
    final body = await _readJson(req);
    if (body == null) {
      await _json(req, 400, {'ok': false, 'error': 'invalid_json'});
      return;
    }
    final id = '${body['id'] ?? ''}'.trim();
    if (id.isEmpty) {
      await _json(req, 400, {'ok': false, 'error': 'id_required'});
      return;
    }
    final ok = await pairing.cancel(id);
    await _json(req, 200, {'ok': true, 'cancelled': ok});
  }

  Future<void> _handlePairingUnlink(HttpRequest req) async {
    final body = await _readJson(req);
    if (body == null) {
      await _json(req, 400, {'ok': false, 'error': 'invalid_json'});
      return;
    }
    final userid = '${body['userid'] ?? ''}'.trim();
    final provider = '${body['provider'] ?? ''}'.trim();
    if (userid.isEmpty) {
      await _json(req, 400, {'ok': false, 'error': 'userid_required'});
      return;
    }
    final removed = await identity.bindings.remove(
      userid: userid,
      provider: provider.isEmpty ? null : provider,
    );
    await _json(req, 200, {'ok': true, 'removed': removed});
  }

  Future<void> _handlePairingLinks(HttpRequest req) async {
    final userid = (req.uri.queryParameters['userid'] ?? '').trim();
    if (userid.isEmpty) {
      await _json(req, 400, {'ok': false, 'error': 'userid_required'});
      return;
    }
    await identity.bindings.load();
    final bindings = identity.bindings.bindingsFor(userid);
    final providers = <String>{
      for (final d in identity.destinationsFor(userid)) d.provider,
    };
    await _json(req, 200, {
      'ok': true,
      'userid': userid,
      'providers': providers.toList()..sort(),
      'bindings': [for (final b in bindings) b.toJson()],
    });
  }

  Future<void> _handleAnnounce(HttpRequest req) async {
    final body = await _readJson(req);
    if (body == null) {
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

    await identity.bindings.load();
    final destinations = identity.destinationsFor(recipient);
    if (destinations.isEmpty) {
      _log('warn', 'announce_no_sender', 'No channel mapping for userid', {
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

    final deliveredTo = <String>[];
    Object? lastErr;
    final mux = channel is ChannelMux ? channel as ChannelMux : null;
    for (final dest in destinations) {
      try {
        if (mux != null) {
          await mux.sendOn(dest.provider, dest.senderId, text);
        } else {
          await channel.send(dest.senderId, text);
        }
        deliveredTo.add('${dest.provider}:${dest.senderId}');
      } catch (e) {
        lastErr = e;
        _log('warn', 'announce_send_fail', '$e', {
          'provider': dest.provider,
          'senderId': dest.senderId,
          'id': id,
        });
      }
    }
    if (deliveredTo.isEmpty) {
      await _json(req, 502, {
        'ok': false,
        'delivered': false,
        'reason': 'send_failed',
        'error': '$lastErr',
      });
      return;
    }
    _log('info', 'announce_channel_sent', 'Announcement delivered on channel', {
      'id': id,
      'userid': recipient,
      'chars': text.length,
      'senders': deliveredTo,
    });
    await _json(req, 200, {
      'ok': true,
      'delivered': true,
      'sender_id': deliveredTo.first,
      'sender_ids': deliveredTo,
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

/// Resolve Telegram bot username for pairing deep links.
Future<String> resolveTelegramBotUsername(TelegramChannel tg) async {
  return (await tg.resolveBotUsername()) ?? '';
}
