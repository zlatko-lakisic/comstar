import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/vision/cpai_client.dart';
import 'package:test/test.dart';

import 'mocks/fake_cpai.dart';

VisionConfig _visionConfig(String baseUrl) => VisionConfig(
      codeprojectUrl: baseUrl,
      detectionEndpoint: '/v1/vision/detection',
      recognizeEndpoint: '/v1/vision/face/recognize',
      ambientFps: 1,
      engagedFps: 3,
      personConfidence: 0.6,
      faceConfidence: 0.55,
      recognizeVotes: 3,
      identityTtlSeconds: 300,
    );

void main() {
  group('CpaiClient', () {
    late FakeCpaiServer server;
    late CpaiClient client;

    setUp(() async {
      server = FakeCpaiServer(
        detectionFixture: loadFixture('../../docs/fixtures/cpai_detection.json'),
        recognizeFixture: loadFixture('../../docs/fixtures/cpai_recognize_hit.json'),
      );
      await server.start();
      client = CpaiClient(config: _visionConfig(server.baseUri.toString()));
    });

    tearDown(() async {
      client.dispose();
      await server.stop();
    });

    test('parses detection fixture', () async {
      final detections = await client.detectPerson(fakeJpegFrame());
      expect(detections, isNotEmpty);
      expect(detections.first.label, 'person');
      expect(detections.first.confidence, closeTo(0.926, 0.001));
    });

    test('parses recognize hit fixture', () async {
      final matches = await client.recognizeFace(fakeJpegFrame());
      expect(matches, isNotEmpty);
      expect(matches.first.userid, '_probe');
      expect(matches.first.isKnown, isTrue);
    });

    test('parses recognize miss with unknown userid', () {
      final json = loadFixture('../../docs/fixtures/cpai_recognize_miss_person.json');
      final matches = client.parseRecognizeResponse(json);
      expect(matches.single.userid, 'unknown');
      expect(matches.single.isKnown, isFalse);
    });

    test('parses recognize miss with success false', () {
      final json = loadFixture('../../docs/fixtures/cpai_recognize_miss.json');
      final matches = client.parseRecognizeResponse(json);
      expect(matches, isEmpty);
    });

    test('500 returns empty not throw', () async {
      await server.stop();
      server = FakeCpaiServer(
        detectionFixture: const {'success': true, 'predictions': []},
        detectionStatusCode: 500,
      );
      await server.start();
      client.dispose();
      client = CpaiClient(config: _visionConfig(server.baseUri.toString()));

      final result = await client.detectPerson(fakeJpegFrame());
      expect(result, isEmpty);
    });

    test('timeout returns empty not throw', () async {
      await server.stop();
      server = FakeCpaiServer(
        detectionFixture: loadFixture('../../docs/fixtures/cpai_detection.json'),
        detectionLatency: const Duration(milliseconds: 3000),
      );
      await server.start();
      client.dispose();
      client = CpaiClient(
        config: _visionConfig(server.baseUri.toString()),
        detectionTimeout: const Duration(milliseconds: 50),
      );

      final result = await client.detectPerson(fakeJpegFrame());
      expect(result, isEmpty);
    });

    test('3 failures emits degraded and recovery resets counter', () async {
      await server.stop();
      server = FakeCpaiServer(
        detectionFixture: const <String, dynamic>{'success': false},
        detectionStatusCode: 500,
      );
      await server.start();
      client.dispose();
      client = CpaiClient(config: _visionConfig(server.baseUri.toString()));

      final degradedEvents = <bool>[];
      client.degradedStream.listen(degradedEvents.add);

      await client.detectPerson(fakeJpegFrame());
      await client.detectPerson(fakeJpegFrame());
      expect(client.isDegraded, isFalse);

      await client.detectPerson(fakeJpegFrame());
      expect(client.isDegraded, isTrue);
      expect(degradedEvents, [true]);

      server = FakeCpaiServer(
        detectionFixture: loadFixture('../../docs/fixtures/cpai_detection.json'),
      );
      await server.start();
      client.dispose();
      client = CpaiClient(config: _visionConfig(server.baseUri.toString()));
      final recovered = <bool>[];
      client.degradedStream.listen(recovered.add);

      await client.detectPerson(fakeJpegFrame());
      expect(client.consecutiveFailures, 0);
      expect(client.isDegraded, isFalse);
      expect(recovered, [false]);
    });
  });
}
