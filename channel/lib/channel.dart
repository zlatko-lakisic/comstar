/// Abstract messaging surface for COMSTAR text channels (M11).
///
/// One implementation ships now ([TelegramChannel]); the interface exists so a
/// second channel is a day of work rather than a rewrite.
library;

import 'dart:async';

/// Inbound message from a messaging surface.
class ChannelInbound {
  const ChannelInbound({
    required this.senderId,
    required this.text,
    this.attachments = const [],
    this.raw,
  });

  /// Channel-native sender id (e.g. Telegram numeric user id as string).
  final String senderId;

  /// Message body (may be empty when only attachments).
  final String text;

  /// Optional attachment descriptors (URLs / file ids); opaque to the core.
  final List<String> attachments;

  /// Provider-specific payload for debugging (never logged at info by default).
  final Object? raw;
}

/// Outbound typing / presence hint.
enum ChannelTyping { started, stopped }

/// Messaging surface: inbound stream + send + typing.
abstract class Channel {
  /// Stream of inbound messages from the provider.
  Stream<ChannelInbound> get inbound;

  /// Send a text reply to [senderId]. Returns when the provider accepts it.
  Future<void> send(String senderId, String text);

  /// Optional typing indicator.
  Future<void> setTyping(String senderId, ChannelTyping state) async {}

  /// Start polling / webhook receive loop.
  Future<void> start();

  /// Stop cleanly (SIGTERM path).
  Future<void> stop();
}
