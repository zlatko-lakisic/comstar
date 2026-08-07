/// Per-sender rate limit + daily orchestration-call cap (M11.7).
library;

/// Sliding / windowed rate limiter for channel turns.
class RateLimiter {
  RateLimiter({
    this.perSenderMax = 20,
    this.perSenderWindow = const Duration(minutes: 10),
    this.dailyCap = 200,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Max turns per sender inside [perSenderWindow].
  final int perSenderMax;

  final Duration perSenderWindow;

  /// Global daily orchestration-call cap (all senders).
  final int dailyCap;

  final DateTime Function() _clock;

  final Map<String, List<DateTime>> _hits = {};
  int _dayOrdinal = -1;
  int _dayCount = 0;

  void _rollDay(DateTime now) {
    final ordinal = now.year * 1000 + now.month * 40 + now.day;
    if (ordinal != _dayOrdinal) {
      _dayOrdinal = ordinal;
      _dayCount = 0;
    }
  }

  /// Returns true if a turn is allowed; records the hit when allowed.
  bool allow(String senderId) {
    final now = _clock();
    _rollDay(now);
    if (_dayCount >= dailyCap) return false;

    final cutoff = now.subtract(perSenderWindow);
    final list = (_hits[senderId] ?? <DateTime>[])
        .where((t) => t.isAfter(cutoff))
        .toList();
    if (list.length >= perSenderMax) {
      _hits[senderId] = list;
      return false;
    }
    list.add(now);
    _hits[senderId] = list;
    _dayCount++;
    return true;
  }

  /// Test / ops: remaining daily budget.
  int get remainingDaily {
    _rollDay(_clock());
    return dailyCap - _dayCount;
  }
}
