import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:comstar_channel/announce_http.dart';
import 'package:comstar_channel/channel.dart';
import 'package:comstar_channel/identity.dart';
import 'package:test/test.dart';

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
}

void main() {
  late AnnounceHttpServer server;
  late RecordingChannel channel;
  late int port;

  setUp(() async {
    channel = RecordingChannel();
    // Bind ephemeral port.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();
    server = AnnounceHttpServer(
      channel: channel,
      allowlist: Allowlist({'111': 'zlatko'}),
      token: 'secret',
      bindHost: '127.0.0.1',
      port: port,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
  });

  Future<Map<String, dynamic>> post(Map<String, Object?> body) async {
    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/v1/announce'));
    req.headers.set('content-type', 'application/json');
    req.headers.set('x-comstar-channel-token', 'secret');
    req.write(jsonEncode(body));
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    client.close(force: true);
    return Map<String, dynamic>.from(jsonDecode(text) as Map);
  }

  test('delivers urgent when absent', () async {
    final body = await post({
      'id': 'a1',
      'recipient': 'zlatko',
      'text': 'Meeting moved',
      'priority': 'urgent',
      'present_at_terminal': false,
    });
    expect(body['delivered'], isTrue);
    expect(channel.sent, hasLength(1));
    expect(channel.sent.single.senderId, '111');
    expect(channel.sent.single.text, 'Meeting moved');
  });

  test('presence suppresses send', () async {
    final body = await post({
      'id': 'a2',
      'recipient': 'zlatko',
      'text': 'Hi',
      'priority': 'urgent',
      'present_at_terminal': true,
    });
    expect(body['delivered'], isFalse);
    expect(body['reason'], 'skip');
    expect(channel.sent, isEmpty);
  });

  test('unmapped userid does not send', () async {
    final body = await post({
      'id': 'a3',
      'recipient': 'nobody',
      'text': 'Hi',
      'priority': 'urgent',
      'present_at_terminal': false,
    });
    expect(body['delivered'], isFalse);
    expect(body['reason'], 'no_sender');
    expect(channel.sent, isEmpty);
  });

  test('already_delivered skips', () async {
    final body = await post({
      'id': 'a4',
      'recipient': 'zlatko',
      'text': 'Hi',
      'priority': 'urgent',
      'already_delivered': true,
      'present_at_terminal': false,
    });
    expect(body['delivered'], isFalse);
    expect(channel.sent, isEmpty);
  });
}
