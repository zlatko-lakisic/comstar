/// Fan-in multiplexer over one or more [Channel] providers (M11.2).
///
/// M11 ships Telegram only; the mux exists so a second provider is a day of
/// work and so announce delivery can target every mapped sender for a userid.
library;

import 'dart:async';

import 'package:comstar_channel/channel.dart';

/// Merges inbound streams and routes [send] / typing to the provider that
/// last saw [senderId] (or the sole provider when only one is registered).
class ChannelMux implements Channel {
  ChannelMux(List<Channel> channels) : _channels = List.unmodifiable(channels) {
    if (_channels.isEmpty) {
      throw ArgumentError('ChannelMux requires at least one Channel');
    }
  }

  final List<Channel> _channels;
  final _inbound = StreamController<ChannelInbound>.broadcast();
  final _senderHome = <String, Channel>{};
  final _subs = <StreamSubscription<ChannelInbound>>[];
  var _started = false;

  List<Channel> get channels => _channels;

  @override
  Stream<ChannelInbound> get inbound => _inbound.stream;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    for (final ch in _channels) {
      await ch.start();
      _subs.add(ch.inbound.listen((msg) {
        _senderHome[msg.senderId] = ch;
        if (!_inbound.isClosed) _inbound.add(msg);
      }));
    }
  }

  @override
  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final ch in _channels) {
      await ch.stop();
    }
    await _inbound.close();
    _started = false;
  }

  Channel _route(String senderId) {
    final home = _senderHome[senderId];
    if (home != null) return home;
    if (_channels.length == 1) return _channels.single;
    throw StateError('No channel home for senderId=$senderId');
  }

  @override
  Future<void> send(String senderId, String text) =>
      _route(senderId).send(senderId, text);

  @override
  Future<void> setTyping(String senderId, ChannelTyping state) =>
      _route(senderId).setTyping(senderId, state);

  /// Best-effort send on every channel that might own [senderId].
  ///
  /// Used when the sender home is unknown (e.g. announce push): try the
  /// remembered home first, else try all providers until one accepts.
  Future<void> sendEverywhere(String senderId, String text) async {
    final home = _senderHome[senderId];
    if (home != null) {
      await home.send(senderId, text);
      return;
    }
    Object? last;
    for (final ch in _channels) {
      try {
        await ch.send(senderId, text);
        _senderHome[senderId] = ch;
        return;
      } catch (e) {
        last = e;
      }
    }
    if (last != null) throw last;
  }
}
