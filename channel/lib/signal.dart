/// Signal channel placeholder (ADR 0015).
///
/// Planned backend: `signal-cli` (or a thin HTTP sidecar wrapping it). Device
/// link uses a QR the bridge shows via `pairing.qr`. Userid↔number bindings
/// use the same PairingManager flow as Telegram once the CLI can send DMs.
library;

import 'dart:async';
import 'dart:io';

import 'package:comstar_channel/channel.dart';

bool signalConfiguredFromEnv() {
  final url = Platform.environment['COMSTAR_SIGNAL_URL']?.trim();
  final home = Platform.environment['SIGNAL_CLI_CONFIG']?.trim();
  return (url != null && url.isNotEmpty) || (home != null && home.isNotEmpty);
}

class SignalChannel implements Channel {
  SignalChannel({this.baseUrl = ''});

  final String baseUrl;
  final _inbound = StreamController<ChannelInbound>.broadcast();

  @override
  Stream<ChannelInbound> get inbound => _inbound.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setTyping(String senderId, ChannelTyping state) async {}

  @override
  Future<void> send(String senderId, String text) async {
    throw StateError('Signal channel is not configured');
  }
}
