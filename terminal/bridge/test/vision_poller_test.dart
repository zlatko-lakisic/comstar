import 'dart:async';

import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/vision/camera.dart';
import 'package:comstar_bridge/vision/cpai_client.dart';
import 'package:comstar_bridge/vision/identity.dart';
import 'package:comstar_bridge/vision/vision_poller.dart';
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
      recognizeVotes: 1,
      identityTtlSeconds: 300,
    );

void main() {
  group('VisionPoller', () {
    late FakeCpaiServer server;
    late CpaiClient client;
    late FakeClock clock;
    late IdentityResolver identity;

    setUp(() async {
      server = FakeCpaiServer(
        detectionFixture: loadFixture('../../docs/fixtures/cpai_detection.json'),
        recognizeFixture: loadFixture('../../docs/fixtures/cpai_recognize_hit.json'),
      );
      await server.start();
      clock = FakeClock();
      identity = IdentityResolver(
        config: _visionConfig(server.baseUri.toString()),
        clock: clock,
      );
      client = CpaiClient(
        config: _visionConfig(server.baseUri.toString()),
      );
    });

    tearDown(() async {
      client.dispose();
      await server.stop();
    });

    test('recognize is not called while identity is valid', () async {
      final poller = VisionPoller(
        camera: FakeCamera([fakeJpegFrame()]),
        client: client,
        identity: identity,
        config: _visionConfig(server.baseUri.toString()),
        clock: clock,
      );

      // Resolve identity first.
      identity.recordMatch('_probe', 1.0);
      expect(identity.isResolved, isTrue);

      await poller.pollOnce(fakeJpegFrame());
      expect(server.detectionCalls, 1);
      expect(server.recognizeCalls, 0);

      await poller.dispose();
    });

    test('recognize called when identity unresolved', () async {
      final poller = VisionPoller(
        camera: FakeCamera([fakeJpegFrame()]),
        client: client,
        identity: identity,
        config: _visionConfig(server.baseUri.toString()),
        clock: clock,
      );

      await poller.pollOnce(fakeJpegFrame());
      expect(server.detectionCalls, 1);
      expect(server.recognizeCalls, 1);

      await poller.dispose();
    });

    test('fps change takes effect on next start', () async {
      final camera = FakeCamera([fakeJpegFrame(), fakeJpegFrame(1)]);
      final poller = VisionPoller(
        camera: camera,
        client: client,
        identity: identity,
        config: _visionConfig(server.baseUri.toString()),
        clock: clock,
      );

      poller.setTargetFps(5);
      await poller.start(initialFps: 5);
      expect(poller.targetFps, 5);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await poller.stop();
      await poller.dispose();
    });

    test('frames dropped not queued when downstream is slow', () async {
      await server.stop();
      server = FakeCpaiServer(
        detectionFixture: loadFixture('../../docs/fixtures/cpai_detection.json'),
        detectionLatency: const Duration(milliseconds: 200),
      );
      await server.start();
      client.dispose();
      client = CpaiClient(
        config: _visionConfig(server.baseUri.toString()),
      );

      final poller = VisionPoller(
        camera: FakeCamera(List.generate(10, fakeJpegFrame)),
        client: client,
        identity: identity,
        config: _visionConfig(server.baseUri.toString()),
        clock: clock,
      );

      await poller.start(initialFps: 30);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await poller.stop();

      expect(server.detectionCalls, lessThan(10));
      await poller.dispose();
    });

    test('emits person and face events', () async {
      final poller = VisionPoller(
        camera: FakeCamera([fakeJpegFrame()]),
        client: client,
        identity: identity,
        config: _visionConfig(server.baseUri.toString()),
        clock: clock,
      );

      final events = <VisionEvent>[];
      poller.events.listen(events.add);

      await poller.pollOnce(fakeJpegFrame());
      expect(events.whereType<VisionPersonDetected>(), isNotEmpty);
      expect(events.whereType<VisionFaceRecognized>(), isNotEmpty);

      await poller.dispose();
    });

    test('person absent after threshold frames', () async {
      await server.stop();
      server = FakeCpaiServer(
        detectionFixture: const <String, dynamic>{
          'success': true,
          'predictions': <dynamic>[],
        },
      );
      await server.start();
      client.dispose();
      client = CpaiClient(
        config: _visionConfig(server.baseUri.toString()),
      );

      final poller = VisionPoller(
        camera: FakeCamera([fakeJpegFrame()]),
        client: client,
        identity: identity,
        config: _visionConfig(server.baseUri.toString()),
        clock: clock,
        absentFrameThreshold: 3,
      );

      final events = <VisionEvent>[];
      poller.events.listen(events.add);

      await poller.pollOnce(fakeJpegFrame());
      await poller.pollOnce(fakeJpegFrame());
      expect(events.whereType<VisionPersonAbsent>(), isEmpty);

      await poller.pollOnce(fakeJpegFrame());
      expect(events.whereType<VisionPersonAbsent>(), isNotEmpty);

      await poller.dispose();
    });
  });
}
