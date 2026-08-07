import 'package:comstar_bridge/vision_visit_intent.dart';
import 'package:test/test.dart';

void main() {
  group('parseVisionVisitIntent', () {
    test('driveway today / yesterday', () {
      final today = parseVisionVisitIntent('Who was in my driveway today?');
      expect(today?.kind, VisionVisitIntentKind.whoVisited);
      expect(today?.camera, 'driveway');
      expect(today?.since, 'today');

      final y = parseVisionVisitIntent('Who was in my driveway yesterday?');
      expect(y?.camera, 'driveway');
      expect(y?.since, 'yesterday');
    });

    test('visitors / came by', () {
      expect(
        parseVisionVisitIntent('Any visitors today?')?.since,
        'today',
      );
      expect(
        parseVisionVisitIntent('Who came by yesterday?')?.since,
        'yesterday',
      );
    });

    test('front door historical', () {
      final i = parseVisionVisitIntent(
        'Who was at the front door yesterday?',
      );
      expect(i?.camera, 'front_door');
      expect(i?.since, 'yesterday');
    });

    test('person last seen extracts name', () {
      final i = parseVisionVisitIntent(
        'When was the last time you saw Adna?',
      );
      expect(i?.kind, VisionVisitIntentKind.personLastSeen);
      expect(i?.personName, 'Adna');
      expect(i?.camera, '');
    });

    test('STT last time see variant', () {
      final i = parseVisionVisitIntent(
        'When did you last time see Adna?',
      );
      expect(i?.kind, VisionVisitIntentKind.personLastSeen);
      expect(i?.personName, 'Adna');
    });

    test('where saw follow-up', () {
      final i = parseVisionVisitIntent(
        'And where was it that you saw Anna?',
      );
      expect(i?.kind, VisionVisitIntentKind.personLastSeen);
      expect(i?.personName, 'Anna');
    });

    test('rejects who is home and live presence', () {
      expect(parseVisionVisitIntent("Who's home?"), isNull);
      expect(parseVisionVisitIntent('Who is at the front door?'), isNull);
      expect(parseVisionVisitIntent('What do you see?'), isNull);
    });
  });

  group('clipSpokenHint', () {
    test('passes short hints', () {
      expect(clipSpokenHint('Zlatko at 5 PM.'), 'Zlatko at 5 PM.');
    });

    test('truncates long hints at sentence', () {
      final long = '${'Word. ' * 80}Tail that should go.';
      final clipped = clipSpokenHint(long, maxChars: 100);
      expect(clipped.length, lessThanOrEqualTo(100));
      expect(clipped.endsWith('.'), isTrue);
    });
  });
}
