import 'dart:async';

import 'package:comstar_channel/channel.dart';
import 'package:comstar_channel/mux.dart';
import 'package:test/test.dart';

class _FakeChannel implements Channel {
  _FakeChannel(this.name);
  final String name;
  final sent = <({String senderId, String text})>[];
  final _inbound = StreamController<ChannelInbound>.broadcast();

  @override
  Stream<ChannelInbound> get inbound => _inbound.stream;

  @override
  Future<void> send(String senderId, String text) async {
    sent.add((senderId: senderId, text: text));
  }

  @override
  Future<void> setTyping(String senderId, ChannelTyping state) async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    await _inbound.close();
  }

  void inject(String senderId, String text) {
    _inbound.add(ChannelInbound(senderId: senderId, text: text));
  }
}

void main() {
  test('mux merges inbound from all providers', () async {
    final a = _FakeChannel('a');
    final b = _FakeChannel('b');
    final mux = ChannelMux([a, b]);
    await mux.start();

    final got = <ChannelInbound>[];
    final sub = mux.inbound.listen(got.add);

    a.inject('1', 'from-a');
    b.inject('2', 'from-b');
    await Future<void>.delayed(Duration.zero);

    expect(got.map((m) => m.text), ['from-a', 'from-b']);
    await mux.send('1', 'reply-a');
    expect(a.sent.single.text, 'reply-a');
    expect(b.sent, isEmpty);

    await sub.cancel();
    await mux.stop();
  });

  test('sendEverywhere tries providers when home unknown', () async {
    final a = _FakeChannel('a');
    final b = _FakeChannel('b');
    final mux = ChannelMux([a, b]);
    await mux.start();
    await mux.sendEverywhere('99', 'hello');
    expect(a.sent.single.text, 'hello');
    await mux.stop();
  });
}
