/// WhatsApp Business Cloud API channel (ADR 0015).
///
/// Official Meta Graph API only — no Baileys/whatsmeow.
///
/// Env:
///   COMSTAR_WHATSAPP_CLOUD_TOKEN     permanent access token
///   COMSTAR_WHATSAPP_PHONE_NUMBER_ID phone number id (Graph)
///   COMSTAR_WHATSAPP_VERIFY_TOKEN    webhook verify challenge
///   COMSTAR_WHATSAPP_DISPLAY_PHONE   E.164 or digits for wa.me QR links
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:comstar_channel/channel.dart';

/// True when Cloud API credentials are present.
bool whatsappConfiguredFromEnv() {
  final token = Platform.environment['COMSTAR_WHATSAPP_CLOUD_TOKEN']?.trim();
  final phoneId =
      Platform.environment['COMSTAR_WHATSAPP_PHONE_NUMBER_ID']?.trim();
  return token != null &&
      token.isNotEmpty &&
      phoneId != null &&
      phoneId.isNotEmpty;
}

String? whatsappDisplayPhoneFromEnv() {
  final raw = Platform.environment['COMSTAR_WHATSAPP_DISPLAY_PHONE']?.trim();
  if (raw == null || raw.isEmpty) return null;
  return normalizeWhatsAppSenderId(raw);
}

/// Digits-only sender id (Cloud API `wa_id` style).
String normalizeWhatsAppSenderId(String raw) {
  return raw.replaceAll(RegExp(r'\D'), '');
}

class WhatsAppChannel implements Channel {
  WhatsAppChannel({
    required this.accessToken,
    required this.phoneNumberId,
    this.verifyToken = '',
    this.apiVersion = 'v21.0',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  factory WhatsAppChannel.fromEnv({http.Client? httpClient}) {
    return WhatsAppChannel(
      accessToken: Platform.environment['COMSTAR_WHATSAPP_CLOUD_TOKEN'] ?? '',
      phoneNumberId:
          Platform.environment['COMSTAR_WHATSAPP_PHONE_NUMBER_ID'] ?? '',
      verifyToken: Platform.environment['COMSTAR_WHATSAPP_VERIFY_TOKEN'] ?? '',
      httpClient: httpClient,
    );
  }

  final String accessToken;
  final String phoneNumberId;
  final String verifyToken;
  final String apiVersion;
  final http.Client _http;

  final _inbound = StreamController<ChannelInbound>.broadcast();

  @override
  String get providerId => 'whatsapp';

  @override
  Stream<ChannelInbound> get inbound => _inbound.stream;

  Uri get _messagesUri => Uri.parse(
        'https://graph.facebook.com/$apiVersion/$phoneNumberId/messages',
      );

  @override
  Future<void> start() async {
    // Inbound arrives via webhook → [ingestWebhook].
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> setTyping(String senderId, ChannelTyping state) async {}

  @override
  Future<void> send(String senderId, String text) async {
    final to = normalizeWhatsAppSenderId(senderId);
    if (to.isEmpty) {
      throw ArgumentError('invalid WhatsApp recipient');
    }
    final res = await _http.post(
      _messagesUri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'messaging_product': 'whatsapp',
        'to': to,
        'type': 'text',
        'text': {'preview_url': false, 'body': text},
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'WhatsApp send failed: ${res.statusCode} ${res.body}',
      );
    }
  }

  /// Meta webhook verification (GET hub.challenge).
  String? verifyWebhook({
    required String mode,
    required String token,
    required String challenge,
  }) {
    if (mode != 'subscribe') return null;
    if (verifyToken.isEmpty || token != verifyToken) return null;
    return challenge;
  }

  /// Parse Cloud API webhook POST and emit inbound text messages.
  void ingestWebhook(Object? decoded) {
    if (decoded is! Map) return;
    final entry = decoded['entry'];
    if (entry is! List) return;
    for (final e in entry) {
      if (e is! Map) continue;
      final changes = e['changes'];
      if (changes is! List) continue;
      for (final c in changes) {
        if (c is! Map) continue;
        final value = c['value'];
        if (value is! Map) continue;
        final messages = value['messages'];
        if (messages is! List) continue;
        for (final m in messages) {
          if (m is! Map) continue;
          if ('${m['type']}' != 'text') continue;
          final from = normalizeWhatsAppSenderId('${m['from'] ?? ''}');
          final body = m['text'];
          final text = body is Map ? '${body['body'] ?? ''}'.trim() : '';
          if (from.isEmpty || text.isEmpty) continue;
          if (!_inbound.isClosed) {
            _inbound.add(ChannelInbound(
              provider: 'whatsapp',
              senderId: from,
              text: text,
              raw: m,
            ));
          }
        }
      }
    }
  }
}
