import 'dart:math';

import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:comstar_bridge/attention/invariants.dart';
import 'package:comstar_bridge/attention/machine.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:comstar_bridge/config.dart';
import 'package:test/test.dart';

final _rng = Random(42);

List<AttentionEvent> _randomEvent() {
  final roll = _rng.nextInt(14);
  return switch (roll) {
    0 => [PersonDetected(0.5 + _rng.nextDouble() * 0.5)],
    1 => [const PersonAbsent()],
    2 => [FaceRecognized('user${_rng.nextInt(3)}', 0.6 + _rng.nextDouble() * 0.4)],
    3 => [const FaceUnknown()],
    4 => [WakeWord(0.4 + _rng.nextDouble() * 0.6)],
    5 => [const SpeechStart()],
    6 => [SpeechEnd(100 + _rng.nextInt(2000))],
    7 => [TranscriptReady(_rng.nextBool() ? 'hello' : '')],
    8 => [
        ResponseReady('answer', 'http://127.0.0.1/a.wav'),
        const PlaybackEnded(),
      ],
    9 => [const Tick()],
    10 => [AttentionError('scope', fatal: _rng.nextBool())],
    11 => [const EnterSleep()],
    12 => [const ExitSleep()],
    _ => [const VisionDegraded(), const VisionRecovered()],
  };
}

void main() {
  test('random sequences preserve invariants', () {
    final config = ComstarConfig.loadFile('test/fixtures/comstar.valid.yaml');
    final clock = FakeClock();

    for (var seq = 0; seq < 1000; seq++) {
      final machine = AttentionMachine(config: config, clock: clock);
      final steps = 5 + _rng.nextInt(20);

      for (var i = 0; i < steps; i++) {
        for (final event in _randomEvent()) {
          expect(() => machine.handle(event), returnsNormally);
          assertInvariants(machine.context);

          if (machine.state is Engaged && event is SpeechStart) {
            machine.context.gazeDetected = _rng.nextBool();
          }
        }
        clock.advance(100 + _rng.nextInt(5000));
      }
    }
  });
}
