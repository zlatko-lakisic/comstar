import 'dart:async';
import 'dart:convert';

import 'package:comstar_channel/pairing.dart';
import 'package:comstar_channel/signal.dart';
import 'package:comstar_channel/whatsapp.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('WhatsApp Cloud', () {
    test('normalize strips non-digits', () {
      expect(normalizeWhatsAppSenderId('+1 (555) 123-4567'), '15551234567');
    });

    test('pair URL prefills token', () {
      final url = PairingManager.whatsappPairUrl(
        displayPhone: '+1-555-123-4567',
        token: 'abc12345',
      );
      expect(url, startsWith('https://wa.me/15551234567?text='));
      expect(url, contains(Uri.encodeComponent('pair_abc12345')));
    });

    test('ingestWebhook emits inbound text', () async {
      final ch = WhatsAppChannel(
        accessToken: 't',
        phoneNumberId: '1',
        verifyToken: 'v',
      );
      final done = Completer<void>();
      final sub = ch.inbound.listen((msg) {
        expect(msg.provider, 'whatsapp');
        expect(msg.senderId, '15559876543');
        expect(msg.text, 'pair_xyz');
        done.complete();
      });
      ch.ingestWebhook({
        'entry': [
          {
            'changes': [
              {
                'value': {
                  'messages': [
                    {
                      'from': '15559876543',
                      'type': 'text',
                      'text': {'body': 'pair_xyz'},
                    },
                  ],
                },
              },
            ],
          },
        ],
      });
      await done.future.timeout(const Duration(seconds: 2));
      await sub.cancel();
    });

    test('send posts Graph messages', () async {
      http.Request? seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response('{"messages":[{"id":"wamid.x"}]}', 200);
      });
      final ch = WhatsAppChannel(
        accessToken: 'secret',
        phoneNumberId: '99',
        httpClient: client,
      );
      await ch.send('+15551112222', 'hello');
      expect(seen!.url.path, contains('/99/messages'));
      expect(seen!.headers['Authorization'], 'Bearer secret');
      final body = jsonDecode(seen!.body) as Map;
      expect(body['to'], '15551112222');
      expect(body['text']['body'], 'hello');
    });
  });

  group('Signal', () {
    test('normalize to E.164', () {
      expect(normalizeSignalSenderId('15551234567'), '+15551234567');
      expect(normalizeSignalSenderId('+1-555-123-4567'), '+15551234567');
    });

    test('pair URL opens signal.me', () {
      expect(
        PairingManager.signalPairUrl(accountE164: '15551234567'),
        'https://signal.me/#p/+15551234567',
      );
    });

    test('debugInjectReceive emits inbound', () async {
      final ch = SignalChannel(baseUrl: 'http://127.0.0.1:9');
      final done = Completer<void>();
      final sub = ch.inbound.listen((msg) {
        expect(msg.provider, 'signal');
        expect(msg.senderId, '+15550001111');
        expect(msg.text, 'pair_tok');
        done.complete();
      });
      ch.debugInjectReceive(senderId: '+15550001111', text: 'pair_tok');
      await done.future.timeout(const Duration(seconds: 2));
      await sub.cancel();
    });

    test('send uses json-rpc', () async {
      http.Request? seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'result': {'timestamp': 1},
            'id': 1,
          }),
          200,
        );
      });
      final ch = SignalChannel(
        baseUrl: 'http://127.0.0.1:8080',
        account: '+15550000000',
        httpClient: client,
      );
      await ch.send('+15551112222', 'hi');
      expect(seen!.url.path, endsWith('/api/v1/rpc'));
      final body = jsonDecode(seen!.body) as Map;
      expect(body['method'], 'send');
      expect(body['params']['recipient'], ['+15551112222']);
      expect(body['params']['message'], 'hi');
    });
  });

  test('extractPairPayload across providers', () {
    expect(PairingManager.extractPairPayload('/start pair_abc12xyz'), 'pair_abc12xyz');
    expect(PairingManager.extractPairPayload('pair_abc12xyz'), 'pair_abc12xyz');
    expect(PairingManager.extractPairPayload('hello'), isNull);
  });
}
