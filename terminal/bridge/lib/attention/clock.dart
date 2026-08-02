/// Injectable time source for the attention machine and identity TTL.
abstract class Clock {
  int get nowMs;
}

class SystemClock implements Clock {
  @override
  int get nowMs => DateTime.now().millisecondsSinceEpoch;
}

class FakeClock implements Clock {
  FakeClock([this._nowMs = 0]);

  int _nowMs;

  @override
  int get nowMs => _nowMs;

  void set(int ms) => _nowMs = ms;

  void advance(int ms) => _nowMs += ms;
}
