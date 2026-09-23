import 'package:comstar_bridge/speak_format.dart';
import 'package:test/test.dart';

void main() {
  group('formatForSpeech', () {
    test('leaves plain prose alone', () {
      expect(
        formatForSpeech('Hello from the hallway.'),
        'Hello from the hallway.',
      );
    });

    test('strips emphasis and headings', () {
      expect(
        formatForSpeech('## Status\nThe **porch** light is *on*.'),
        'Status. The porch light is on.',
      );
    });

    test('turns bullets into spoken sentences', () {
      final got = formatForSpeech(
        'Here is what I found:\n- Windows locked\n- Front door closed\n- Garage clear',
      );
      expect(got.contains('*'), isFalse);
      expect(got.contains('-'), isFalse);
      expect(got.toLowerCase(), contains('windows locked'));
      expect(got.toLowerCase(), contains('front door closed'));
    });

    test('links become link text only', () {
      expect(
        formatForSpeech('See [the forecast](https://example.com/wx) for details.'),
        'See the forecast for details.',
      );
    });

    test('omits fenced code dumps', () {
      final got = formatForSpeech(
        'Done.\n```json\n{"entity_id":"light.x","state":"on"}\n```\nAll set.',
      );
      expect(got.contains('{'), isFalse);
      expect(got.toLowerCase(), contains('done'));
      expect(got.toLowerCase(), contains('all set'));
      expect(got.toLowerCase(), contains('code omitted'));
    });

    test('strips numbered lists and blockquotes', () {
      final got = formatForSpeech('> Note\n1. First step\n2. Second step');
      expect(got.contains('>'), isFalse);
      expect(RegExp(r'\b1\.').hasMatch(got), isFalse);
      expect(got.toLowerCase(), contains('first step'));
      expect(got.toLowerCase(), contains('second step'));
    });

    test('idempotent on already formatted text', () {
      const once = 'The porch light is on.';
      expect(formatForSpeech(formatForSpeech(once)), once);
    });
  });
}
