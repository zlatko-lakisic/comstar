import 'package:comstar_bridge/google_intent.dart';
import 'package:test/test.dart';

void main() {
  group('parseGoogleIntent', () {
    test('connect phrases', () {
      expect(
        parseGoogleIntent('connect my Google')?.kind,
        GoogleIntentKind.connect,
      );
      expect(
        parseGoogleIntent('please link google')?.kind,
        GoogleIntentKind.connect,
      );
      expect(
        parseGoogleIntent('sign in to gmail')?.kind,
        GoogleIntentKind.connect,
      );
    });

    test('unlink phrases', () {
      expect(
        parseGoogleIntent('disconnect google')?.kind,
        GoogleIntentKind.unlink,
      );
      expect(
        parseGoogleIntent('unlink my google')?.kind,
        GoogleIntentKind.unlink,
      );
    });

    test('status phrases', () {
      expect(
        parseGoogleIntent('is google connected')?.kind,
        GoogleIntentKind.status,
      );
      expect(
        parseGoogleIntent('do I have google linked')?.kind,
        GoogleIntentKind.status,
      );
    });

    test('unrelated text', () {
      expect(parseGoogleIntent('what is the weather'), isNull);
      expect(parseGoogleIntent('turn up the volume'), isNull);
    });
  });
}
