import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/vision/identity.dart';
import 'package:test/test.dart';

VisionConfig _config({int votes = 3, int ttlSeconds = 300}) => VisionConfig(
      codeprojectUrl: 'http://127.0.0.1:32168',
      detectionEndpoint: '/v1/vision/detection',
      recognizeEndpoint: '/v1/vision/face/recognize',
      ambientFps: 1,
      engagedFps: 3,
      personConfidence: 0.6,
      faceConfidence: 0.55,
      recognizeVotes: votes,
      identityTtlSeconds: ttlSeconds,
    );

void main() {
  group('IdentityResolver', () {
    late FakeClock clock;
    late IdentityResolver identity;

    setUp(() {
      clock = FakeClock();
      identity = IdentityResolver(config: _config(), clock: clock);
    });

    test('needs exactly N votes to resolve', () {
      expect(identity.recordMatch('zlatko', 0.9), isA<IdentityVotePending>());
      expect(identity.recordMatch('zlatko', 0.9), isA<IdentityVotePending>());
      final third = identity.recordMatch('zlatko', 0.9);
      expect(third, isA<IdentityVoteRecognized>());
      expect((third as IdentityVoteRecognized).userid, 'zlatko');
      expect(identity.isResolved, isTrue);
    });

    test('alternating userids never resolve', () {
      identity.recordMatch('alice', 0.9);
      identity.recordMatch('bob', 0.9);
      identity.recordMatch('alice', 0.9);
      identity.recordMatch('bob', 0.9);
      expect(identity.isResolved, isFalse);
    });

    test('TTL expires under fake clock', () {
      identity.recordMatch('zlatko', 0.9);
      identity.recordMatch('zlatko', 0.9);
      identity.recordMatch('zlatko', 0.9);
      expect(identity.isResolved, isTrue);

      clock.advance(299 * 1000);
      expect(identity.isResolved, isTrue);

      clock.advance(2 * 1000);
      expect(identity.isExpired, isTrue);
      expect(identity.needsRecognition, isTrue);
    });

    test('PersonDetected alone does not refresh TTL', () {
      identity.recordMatch('zlatko', 0.9);
      identity.recordMatch('zlatko', 0.9);
      identity.recordMatch('zlatko', 0.9);
      final expiresAt = clock.nowMs + 300 * 1000;

      clock.advance(200 * 1000);
      identity.onPersonDetected();
      expect(identity.isResolved, isTrue);

      clock.set(expiresAt + 1);
      expect(identity.isExpired, isTrue);
    });

    test('unknown userid resets votes and returns unknown', () {
      identity.recordMatch('zlatko', 0.9);
      identity.recordMatch('zlatko', 0.9);
      final unknown = identity.recordUnknown();
      expect(unknown, isA<IdentityVoteUnknown>());
      expect(identity.isResolved, isFalse);

      identity.recordMatch('zlatko', 0.9);
      identity.recordMatch('zlatko', 0.9);
      expect(identity.isResolved, isFalse);
    });

    test('low confidence match resets votes', () {
      identity.recordMatch('zlatko', 0.9);
      identity.recordMatch('zlatko', 0.1);
      identity.recordMatch('zlatko', 0.9);
      identity.recordMatch('zlatko', 0.9);
      expect(identity.isResolved, isFalse);
    });
  });
}
