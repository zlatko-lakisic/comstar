/// WhatsApp channel placeholder (ADR 0015).
///
/// Enable with a real backend later:
/// - Meta Cloud API (official), or
/// - a local whatsmeow/Baileys sidecar with explicit operator opt-in (ban risk).
///
/// Until configured, [start] is a no-op and [send] throws.
library;

import 'dart:async';
import 'dart:io';

import 'package:comstar_channel/channel.dart';

/// Returns true when WhatsApp backend env is present.
bool whatsappConfiguredFromEnv() {
  final cloud = Platform.environment['COMSTAR_WHATSAPP_CLOUD_TOKEN']?.trim();
  final sidecar = Platform.environment['COMSTAR_WHATSAPP_URL']?.trim();
  return (cloud != null && cloud.isNotEmpty) ||
      (sidecar != null && sidecar.isNotEmpty);
}

class WhatsAppChannel implements Channel {
  WhatsAppChannel({this.baseUrl = ''});

  /// Sidecar base URL when using a local bridge (empty = disabled).
  final String baseUrl;

  final _inbound = StreamController<ChannelInbound>.broadcast();

  @override
  Stream<ChannelInbound> get inbound => _inbound.stream;

  @override
  Future<void> start() async {
    // Backend wiring lands with the chosen WhatsApp adapter.
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> setTyping(String senderId, ChannelTyping state) async {}

  @override
  Future<void> send(String senderId, String text) async {
    throw StateError('WhatsApp channel is not configured');
  }
}
