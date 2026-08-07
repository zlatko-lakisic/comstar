import 'package:comstar_bridge/backoff.dart';
import 'package:test/test.dart';

void main() {
  test('backoff stays within cap and grows with attempt ceiling', () {
    final delays = <int>[];
    for (var attempt = 0; attempt < 8; attempt++) {
      var maxSeen = 0;
      for (var i = 0; i < 40; i++) {
        final d = backoffDelay(
          attempt: attempt,
          base: const Duration(milliseconds: 100),
          cap: const Duration(seconds: 2),
          random: null, // uses Random() — statistical check below
        );
        if (d.inMilliseconds > maxSeen) maxSeen = d.inMilliseconds;
        expect(d.inMilliseconds, inInclusiveRange(0, 2000));
      }
      delays.add(maxSeen);
    }
    // Early attempts should be able to stay under later ceilings.
    expect(delays.first, lessThanOrEqualTo(250));
    expect(delays.last, greaterThan(500));
    expect(delays.last, lessThanOrEqualTo(2000));
  });

  test('attempt 0 ceiling equals base', () {
    for (var i = 0; i < 20; i++) {
      final d = backoffDelay(
        attempt: 0,
        base: const Duration(milliseconds: 250),
        cap: const Duration(seconds: 5),
      );
      expect(d.inMilliseconds, inInclusiveRange(0, 250));
    }
  });
}
