import 'package:ao_reach/ao_reach.dart' show ReachRunException, ReachRunStatus;
import 'package:comstar_bridge/ao_status_speak.dart';
import 'package:test/test.dart';

void main() {
  group('aoStatusSpeakLine', () {
    test('uses message when processing', () {
      expect(
        aoStatusSpeakLine(ReachRunStatus(
          processing: true,
          phase: 'planning',
          message: 'Planning…',
        )),
        'Planning…',
      );
    });

    test('skips done and empty', () {
      expect(
        aoStatusSpeakLine(ReachRunStatus(
          processing: false,
          phase: 'done',
          message: 'Done',
        )),
        isNull,
      );
      expect(
        aoStatusSpeakLine(ReachRunStatus(
          processing: true,
          phase: 'info',
          message: '',
        )),
        isNull,
      );
    });

    test('queued without message', () {
      expect(
        aoStatusSpeakLine(ReachRunStatus(
          processing: true,
          phase: 'queued',
          message: '',
          queuePosition: 2,
          queueLength: 5,
        )),
        'Queued, position 2 of 5.',
      );
    });

    test('falls back to humanized phase', () {
      expect(
        aoStatusSpeakLine(ReachRunStatus(
          processing: true,
          phase: 'warming_agent',
          message: '',
        )),
        'Warming agent.',
      );
    });
  });

  group('aoStatusChanged', () {
    test('detects change and ignores empty next', () {
      expect(aoStatusChanged(null, 'Planning…'), isTrue);
      expect(aoStatusChanged('Planning…', 'Planning…'), isFalse);
      expect(aoStatusChanged('Planning…', 'Searching…'), isTrue);
      expect(aoStatusChanged('Planning…', null), isFalse);
    });
  });

  group('aoPeriodicStillLine', () {
    test('prefixes Still', () {
      expect(aoPeriodicStillLine('Planning…'), 'Still Planning…');
      expect(aoPeriodicStillLine('Searching.'), 'Still Searching.');
      expect(aoPeriodicStillLine('Still working.'), 'Still working.');
      expect(aoPeriodicStillLine(''), 'Still working.');
    });
  });

  group('aoFailureSpeakLine', () {
    test('uses ReachRunException message', () {
      final line = aoFailureSpeakLine(ReachRunException(
        message:
            "Unknown rag_id(s) in task step_1: ['orchestrator_kb']. Known: (empty catalog)",
        code: 'run_failed',
      ));
      expect(line, startsWith('Sorry — Knowledge base missing:'));
      expect(line, contains('orchestrator_kb'));
    });

    test('trims long messages', () {
      final long = 'x' * 200;
      final line = aoFailureSpeakLine(ReachRunException(message: long));
      expect(line!.length, lessThanOrEqualTo(kAoFailureSpeakMaxChars + 10));
      expect(line, contains('…'));
    });

    test('returns null for opaque errors', () {
      expect(aoFailureSpeakLine(StateError('boom')), isNull);
    });
  });
}
