import 'dart:math';

/// Exponential backoff with full jitter (M9.2).
///
/// delay = random(0, min(cap, base * 2^attempt))
Duration backoffDelay({
  required int attempt,
  Duration base = const Duration(milliseconds: 250),
  Duration cap = const Duration(seconds: 5),
  Random? random,
}) {
  final a = attempt < 0 ? 0 : attempt;
  final baseMs = base.inMilliseconds.clamp(1, 60000);
  final capMs = cap.inMilliseconds.clamp(baseMs, 300000);
  final exp = baseMs * (1 << a.clamp(0, 16));
  final ceiling = exp > capMs ? capMs : exp;
  final rng = random ?? Random();
  final ms = rng.nextInt(ceiling + 1);
  return Duration(milliseconds: ms);
}
