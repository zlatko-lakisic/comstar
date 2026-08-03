import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ao_reach/ao_reach.dart';
import 'package:comstar_bridge/speech_routing.dart';
import 'package:comstar_bridge/stt.dart';
import 'package:comstar_bridge/tts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('PreferReachSttClient', () {
    test('uses Reach SpeechClient when present', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/v1/audio/transcriptions');
        expect(request.method, 'POST');
        return http.Response(jsonEncode({'text': 'from reach'}), 200);
      });
      final speech = SpeechClient(
        capabilities: const SpeechCapabilities(
          sttBaseUrl: 'http://speech.test:8090',
          ttsBaseUrl: 'http://speech.test:8091',
        ),
        httpClient: mock,
      );
      final client = PreferReachSttClient(
        speechClientOf: () => speech,
        fallback: HttpSttClient(baseUrl: ''),
      );

      final text = await client.transcribe(Uint8List(3200));
      expect(text, 'from reach');
      speech.close();
    });

    test('falls back when speechClient is null', () async {
      late HttpServer server;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final baseUrl = 'http://${server.address.host}:${server.port}';
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 200
          ..write(jsonEncode({'text': 'from env'}));
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final client = PreferReachSttClient(
        speechClientOf: () => null,
        fallback: HttpSttClient(baseUrl: baseUrl),
      );
      final text = await client.transcribe(Uint8List(100));
      expect(text, 'from env');
    });

    test('falls back when Reach STT fails', () async {
      late HttpServer server;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final baseUrl = 'http://${server.address.host}:${server.port}';
      server.listen((request) async {
        await request.drain();
        request.response
          ..statusCode = 200
          ..write(jsonEncode({'text': 'fallback ok'}));
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));

      final mock = MockClient((_) async => http.Response('boom', 500));
      final speech = SpeechClient(
        capabilities: const SpeechCapabilities(
          sttBaseUrl: 'http://speech.test:8090',
          ttsBaseUrl: 'http://speech.test:8091',
        ),
        httpClient: mock,
      );
      final client = PreferReachSttClient(
        speechClientOf: () => speech,
        fallback: HttpSttClient(baseUrl: baseUrl),
      );

      final text = await client.transcribe(Uint8List(100));
      expect(text, 'fallback ok');
      speech.close();
    });
  });

  group('PreferReachTts', () {
    test('uses Reach SpeechClient when present', () async {
      final wavBytes = List<int>.generate(64, (i) => i);
      final mock = MockClient((request) async {
        expect(request.url.path, '/v1/audio/speech');
        return http.Response.bytes(wavBytes, 200, headers: {
          'content-type': 'audio/wav',
        });
      });
      final speech = SpeechClient(
        capabilities: const SpeechCapabilities(
          sttBaseUrl: 'http://speech.test:8090',
          ttsBaseUrl: 'http://speech.test:8091',
        ),
        httpClient: mock,
      );
      final dir = Directory.systemTemp.createTempSync('comstar-tts-test');
      addTearDown(() => dir.deleteSync(recursive: true));

      final tts = PreferReachTts(
        speechClientOf: () => speech,
        fallback: FakeTts(outputDir: dir.path),
        outputDir: dir.path,
      );
      final path = await tts.synthesizeToFile('hello');
      expect(File(path).readAsBytesSync(), wavBytes);
      speech.close();
    });

    test('falls back when speechClient is null', () async {
      final dir = Directory.systemTemp.createTempSync('comstar-tts-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final tts = PreferReachTts(
        speechClientOf: () => null,
        fallback: FakeTts(outputDir: dir.path),
        outputDir: dir.path,
      );
      final path = await tts.synthesizeToFile('hello');
      expect(File(path).existsSync(), isTrue);
    });
  });
}
