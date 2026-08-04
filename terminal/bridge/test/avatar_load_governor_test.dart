import 'package:comstar_bridge/avatar_load_governor.dart';
import 'package:test/test.dart';

void main() {
  group('AvatarLoadGovernor', () {
    test('starts at preferred tier and drops under stress', () {
      final g = AvatarLoadGovernor(
        preferredBloom: 4,
        preferredFps: 12,
        minBloom: 0,
        minFps: 8,
        stressCpu: 70,
        comfortCpu: 45,
        criticalCpu: 90,
        cooldownSteps: 2,
        minIntervalMs: 0,
      );
      final first = g.onCpu(40, nowMs: 1000);
      expect(first, isNotNull);
      expect(first!['bloom'], greaterThan(0));
      expect(g.tier, g.maxTier);

      final down = g.onCpu(85, nowMs: 2000);
      expect(down, isNotNull);
      expect(g.tier, lessThan(g.maxTier));
      expect((down!['bloom'] as num).toDouble(), lessThan(first['bloom'] as num));
    });

    test('eases back up after sustained comfort', () {
      final g = AvatarLoadGovernor(
        preferredBloom: 4,
        preferredFps: 12,
        stressCpu: 70,
        comfortCpu: 45,
        cooldownSteps: 2,
        minIntervalMs: 0,
      );
      g.onCpu(40, nowMs: 1);
      g.onCpu(90, nowMs: 2);
      g.onCpu(90, nowMs: 3);
      final lowTier = g.tier;
      expect(lowTier, lessThan(g.maxTier));

      expect(g.onCpu(30, nowMs: 4), isNull); // streak 1
      final up = g.onCpu(30, nowMs: 5); // streak 2 → step up
      expect(up, isNotNull);
      expect(g.tier, greaterThan(lowTier));
    });

    test('respects pause after manual override', () {
      final g = AvatarLoadGovernor(minIntervalMs: 0);
      g.onCpu(40, nowMs: 1000);
      g.pauseAuto(durationMs: 10000, nowMs: 2000);
      expect(g.onCpu(95, nowMs: 3000), isNull);
      expect(g.onCpu(95, nowMs: 13000), isNotNull);
    });

    test('disabled returns null', () {
      final g = AvatarLoadGovernor(enabled: false, minIntervalMs: 0);
      expect(g.onCpu(99, nowMs: 1), isNull);
    });
  });
}
