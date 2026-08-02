import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comstar_bridge/stt.dart';
import 'package:test/test.dart';

void main() {
  group('HttpSttClient', () {
    late HttpServer server;
    late String baseUrl;
    var requestCount = 0;

    setUp(() async {
      requestCount = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://${server.address.host}:${server.port}';
      server.listen((request) async {
        if (request.uri.path == '/v1/audio/transcriptions' &&
            request.method == 'POST') {
          requestCount++;
          await request.fold<List<int>>(
            [],
            (prev, chunk) => prev..addAll(chunk),
          );
          request.response
            ..statusCode = 200
            ..write(jsonEncode({'text': 'hello world'}));
          await request.response.close();
          return;
        }
        request.response.statusCode = 404;
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('posts wav to OpenAI-compatible endpoint', () async {
      final client = HttpSttClient(baseUrl: baseUrl);
      final pcm = Uint8List(3200);
      final text = await client.transcribe(pcm);
      client.dispose();

      expect(text, 'hello world');
      expect(requestCount, 1);
    });

    test('returns empty when base URL unset', () async {
      final client = HttpSttClient(baseUrl: '');
      final text = await client.transcribe(Uint8List(100));
      client.dispose();
      expect(text, isEmpty);
    });
  });
}
