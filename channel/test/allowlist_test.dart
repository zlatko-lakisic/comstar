import 'dart:async';

import 'package:comstar_channel/channel.dart';
import 'package:comstar_channel/identity.dart';
import 'package:test/test.dart';

/// Minimal Channel that records outbound sends.
class RecordingChannel implements Channel {
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
  Future<void> stop() async {}

  void inject(ChannelInbound msg) => _inbound.add(msg);
}

/// Core M11.3 security path: resolve allowlist, send only when known.
Future<void> handleInbound({
  required Channel channel,
  required Allowlist allowlist,
  required ChannelInbound msg,
  Future<String> Function(String userid, String text)? turn,
}) async {
  final userid = allowlist.useridFor(msg.senderId);
  if (userid == null) {
    // ZERO outbound — silence.
    return;
  }
  final reply = turn != null
      ? await turn(userid, msg.text)
      : 'ok:$userid';
  await channel.send(msg.senderId, reply);
}

void main() {
  test('unknown sender produces zero outbound bytes', () async {
    final channel = RecordingChannel();
    final allowlist = Allowlist({'111': 'zlatko'});

    await handleInbound(
      channel: channel,
      allowlist: allowlist,
      msg: const ChannelInbound(senderId: '999', text: 'hello'),
    );

    expect(channel.sent, isEmpty);
  });

  test('allowlisted sender receives a reply', () async {
    final channel = RecordingChannel();
    final allowlist = Allowlist({'111': 'zlatko'});

    await handleInbound(
      channel: channel,
      allowlist: allowlist,
      msg: const ChannelInbound(senderId: '111', text: 'ping'),
    );

    expect(channel.sent, hasLength(1));
    expect(channel.sent.single.senderId, '111');
    expect(channel.sent.single.text, 'ok:zlatko');
  });

  test('removed sender stops working immediately', () async {
    final channel = RecordingChannel();
    var allowlist = Allowlist({'111': 'zlatko'});

    await handleInbound(
      channel: channel,
      allowlist: allowlist,
      msg: const ChannelInbound(senderId: '111', text: 'a'),
    );
    expect(channel.sent, hasLength(1));

    allowlist = Allowlist(const {}); // removed
    await handleInbound(
      channel: channel,
      allowlist: allowlist,
      msg: const ChannelInbound(senderId: '111', text: 'b'),
    );
    expect(channel.sent, hasLength(1)); // no new send
  });

  test('sender ids compared exactly — no normalisation', () {
    final allowlist = Allowlist({'111': 'zlatko'});
    expect(allowlist.useridFor('111'), 'zlatko');
    expect(allowlist.useridFor(' 111'), isNull);
    expect(allowlist.useridFor('0111'), isNull);
    expect(allowlist.useridFor('111 '), isNull);
  });

  test('senderIdFor reverses allowlist', () {
    final allowlist = Allowlist({'111': 'zlatko', '222': 'other'});
    expect(allowlist.senderIdFor('zlatko'), '111');
    expect(allowlist.senderIdFor('other'), '222');
    expect(allowlist.senderIdFor('nobody'), isNull);
  });

  test('Allowlist.fromEnv parses inline JSON', () {
    final a = Allowlist.fromEnv('{"42":"zlatko","99":"other"}');
    expect(a.useridFor('42'), 'zlatko');
    expect(a.useridFor('99'), 'other');
    expect(a.useridFor('1'), isNull);
  });
}
