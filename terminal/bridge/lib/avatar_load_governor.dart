import 'dart:math' as math;

/// Adaptive avatar quality tiers driven by host CPU.
///
/// Under stress, steps bloom/fps down. When CPU stays comfortable, eases them
/// back toward the preferred ceiling — slowly, with hysteresis so we do not
/// thrash.
final class AvatarLoadGovernor {
  AvatarLoadGovernor({
    this.preferredBloom = 3,
    this.preferredFps = 12,
    this.minBloom = 0,
    this.minFps = 8,
    this.stressCpu = 75,
    this.comfortCpu = 50,
    this.criticalCpu = 90,
    this.cooldownSteps = 3,
    this.minIntervalMs = 4000,
    this.enabled = true,
  });

  double preferredBloom;
  double preferredFps;
  final double minBloom;
  final double minFps;
  final double stressCpu;
  final double comfortCpu;
  final double criticalCpu;
  final int cooldownSteps;
  final int minIntervalMs;
  bool enabled;

  double _emaCpu = 0;
  var _emaPrimed = false;
  var _tier = 0; // 0 = floor … maxTier = preferred
  var _comfortStreak = 0;
  int? _lastChangeMs;
  int? _pauseUntilMs;

  /// Current applied options (null until first decision).
  Map<String, dynamic>? lastApplied;

  int get maxTier {
    // Discrete steps between floor and preferred (at least 1 step).
    final bloomSpan = (preferredBloom - minBloom).abs();
    final fpsSpan = (preferredFps - minFps).abs();
    final steps = math.max(1, math.max(bloomSpan, fpsSpan / 2).ceil());
    return steps;
  }

  /// Prefer these as the recovery ceiling (e.g. after manual `/control/avatar`).
  void setPreferred({double? bloom, double? fps}) {
    if (bloom != null) preferredBloom = bloom.clamp(minBloom, 24);
    if (fps != null) preferredFps = fps.clamp(minFps, 60);
    _tier = _tier.clamp(0, maxTier);
  }

  /// Ignore auto changes for [durationMs] after an operator override.
  void pauseAuto({int durationMs = 60000, int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    _pauseUntilMs = now + durationMs;
  }

  /// Returns new options when a change is warranted; otherwise null.
  Map<String, dynamic>? onCpu(double cpuPercent, {int? nowMs}) {
    if (!enabled) return null;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final pauseUntil = _pauseUntilMs;
    if (pauseUntil != null && now < pauseUntil) return null;

    final cpu = cpuPercent.clamp(0, 100).toDouble();
    if (!_emaPrimed) {
      _emaCpu = cpu;
      _emaPrimed = true;
      _tier = maxTier;
      return _emit(now);
    }
    _emaCpu = _emaCpu * 0.5 + cpu * 0.5;

    final last = _lastChangeMs;
    if (last != null && now - last < minIntervalMs) return null;

    // Scale down on instantaneous spikes; scale up only when EMA is calm.
    var changed = false;
    if (cpu >= criticalCpu || _emaCpu >= criticalCpu) {
      final next = math.max(0, _tier - 2);
      if (next != _tier) {
        _tier = next;
        changed = true;
      }
      _comfortStreak = 0;
    } else if (cpu >= stressCpu || _emaCpu >= stressCpu) {
      final next = math.max(0, _tier - 1);
      if (next != _tier) {
        _tier = next;
        changed = true;
      }
      _comfortStreak = 0;
    } else if (cpu <= comfortCpu) {
      _comfortStreak++;
      if (_comfortStreak >= cooldownSteps) {
        final next = math.min(maxTier, _tier + 1);
        if (next != _tier) {
          _tier = next;
          changed = true;
        }
        _comfortStreak = 0;
      }
    } else {
      _comfortStreak = 0;
    }

    if (!changed) return null;
    return _emit(now);
  }

  Map<String, dynamic> _emit(int nowMs) {
    _lastChangeMs = nowMs;
    final t = maxTier == 0 ? 1.0 : _tier / maxTier;
    final bloom = minBloom + (preferredBloom - minBloom) * t;
    final fps = minFps + (preferredFps - minFps) * t;
    final opts = <String, dynamic>{
      'bloom': double.parse(bloom.toStringAsFixed(1)),
      'fps': double.parse(fps.toStringAsFixed(0)),
      'scale': 0.62,
      'tier': _tier,
      'max_tier': maxTier,
      'cpu_ema': double.parse(_emaCpu.toStringAsFixed(1)),
      'source': 'adapt',
    };
    lastApplied = opts;
    return opts;
  }

  /// Test/inspect helpers.
  double get emaCpu => _emaCpu;
  int get tier => _tier;
}
