import 'package:comstar_bridge/admin_ops.dart';
import 'package:comstar_bridge/admin_server.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:test/test.dart';

void main() {
  group('parseInjectEvent', () {
    test('TranscriptReady', () {
      final event = parseInjectEvent('TranscriptReady', {'text': 'hello'});
      expect(event, isA<TranscriptReady>());
      expect((event as TranscriptReady).text, 'hello');
    });

    test('FaceRecognized requires userid', () {
      expect(parseInjectEvent('FaceRecognized', {}), isNull);
      final event = parseInjectEvent('FaceRecognized', {
        'userid': 'zlatko',
        'confidence': 0.9,
      });
      expect(event, isA<FaceRecognized>());
    });

    test('WakeWord defaults score', () {
      final event = parseInjectEvent('WakeWord', {});
      expect(event, isA<WakeWord>());
      expect((event as WakeWord).score, 0.8);
    });

    test('unknown event returns null', () {
      expect(parseInjectEvent('NotReal', {}), isNull);
    });
  });

  group('inject env gate', () {
    test('isAdminInjectEnabled is boolean', () {
      expect(isAdminInjectEnabled(), anyOf(isTrue, isFalse));
    });
  });
}
