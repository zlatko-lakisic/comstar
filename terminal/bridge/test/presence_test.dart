import 'package:comstar_bridge/attention/presence.dart';
import 'package:test/test.dart';

void main() {
  group('selectPrimaryUserid', () {
    test('picks highest confidence known face', () {
      final map = {
        'alice': PresenceEntry(
          userid: 'alice',
          confidence: 0.7,
          seenAtMs: 1000,
          displayName: 'Alice',
        ),
        'bob': PresenceEntry(
          userid: 'bob',
          confidence: 0.9,
          seenAtMs: 1000,
          displayName: 'Bob',
        ),
      };
      expect(
        selectPrimaryUserid(map, nowMs: 1500, ttlMs: 5000),
        'bob',
      );
    });

    test('prefers known over guest', () {
      final map = {
        'guest': PresenceEntry(
          userid: 'guest',
          confidence: 0.99,
          seenAtMs: 1000,
          guest: true,
        ),
        'alice': PresenceEntry(
          userid: 'alice',
          confidence: 0.5,
          seenAtMs: 1000,
        ),
      };
      expect(
        selectPrimaryUserid(map, nowMs: 1500, ttlMs: 5000),
        'alice',
      );
    });

    test('prunes expired entries', () {
      final map = {
        'alice': PresenceEntry(
          userid: 'alice',
          confidence: 0.9,
          seenAtMs: 0,
        ),
      };
        final kept = prunePresence(map, nowMs: 10000, ttlMs: 1000);
      expect(kept, isEmpty);
      expect(map, isEmpty);
    });
  });
}
