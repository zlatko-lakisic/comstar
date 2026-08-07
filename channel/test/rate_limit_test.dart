import 'package:comstar_channel/rate_limit.dart';
import 'package:test/test.dart';

void main() {
  test('per-sender cap under fake clock', () {
    var now = DateTime.utc(2026, 8, 7, 12, 0);
    final lim = RateLimiter(
      perSenderMax: 3,
      perSenderWindow: const Duration(minutes: 10),
      dailyCap: 100,
      clock: () => now,
    );

    expect(lim.allow('a'), isTrue);
    expect(lim.allow('a'), isTrue);
    expect(lim.allow('a'), isTrue);
    expect(lim.allow('a'), isFalse);

    // Other sender still ok
    expect(lim.allow('b'), isTrue);

    // Window rolls
    now = now.add(const Duration(minutes: 11));
    expect(lim.allow('a'), isTrue);
  });

  test('daily cap shared across senders', () {
    var now = DateTime.utc(2026, 8, 7, 12, 0);
    final lim = RateLimiter(
      perSenderMax: 50,
      perSenderWindow: const Duration(hours: 1),
      dailyCap: 5,
      clock: () => now,
    );

    for (var i = 0; i < 5; i++) {
      expect(lim.allow('s$i'), isTrue, reason: 'hit $i');
    }
    expect(lim.allow('anyone'), isFalse);
    expect(lim.remainingDaily, 0);

    // Next calendar day resets
    now = DateTime.utc(2026, 8, 8, 0, 1);
    expect(lim.allow('anyone'), isTrue);
    expect(lim.remainingDaily, 4);
  });

  test('both windows reset correctly', () {
    // Stay on the same calendar day when rolling the per-sender window.
    var now = DateTime.utc(2026, 8, 7, 12, 0);
    final lim = RateLimiter(
      perSenderMax: 2,
      perSenderWindow: const Duration(minutes: 5),
      dailyCap: 3,
      clock: () => now,
    );

    expect(lim.allow('x'), isTrue);
    expect(lim.allow('x'), isTrue);
    expect(lim.allow('x'), isFalse); // per-sender

    now = now.add(const Duration(minutes: 6));
    expect(lim.allow('x'), isTrue); // window reset, still under daily (3rd)
    expect(lim.allow('x'), isFalse); // daily cap

    now = DateTime.utc(2026, 8, 8, 0, 0);
    expect(lim.allow('x'), isTrue);
  });
}
