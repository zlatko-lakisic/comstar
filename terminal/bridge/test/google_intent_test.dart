import 'package:comstar_bridge/google/pairing_status.dart';
import 'package:test/test.dart';
import 'package:comstar_bridge/google_intent.dart';

void main() {
  group('parseGoogleIntent', () {
    test('status beats connected-as-connect', () {
      expect(
        parseGoogleIntent('Are you connected to my Google?')?.kind,
        GoogleIntentKind.status,
      );
      expect(
        parseGoogleIntent('is google connected')?.kind,
        GoogleIntentKind.status,
      );
      expect(
        parseGoogleIntent('am I linked to google')?.kind,
        GoogleIntentKind.status,
      );
      expect(
        parseGoogleIntent('do I have google')?.kind,
        GoogleIntentKind.status,
      );
    });

    test('connect phrases', () {
      expect(
        parseGoogleIntent('connect my Google')?.kind,
        GoogleIntentKind.connect,
      );
      expect(
        parseGoogleIntent('Connects my Google')?.kind,
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

    test('reconnect', () {
      expect(
        parseGoogleIntent('reconnect my google')?.kind,
        GoogleIntentKind.reconnect,
      );
      expect(
        parseGoogleIntent('connect google again')?.kind,
        GoogleIntentKind.reconnect,
      );
    });

    test('cancel', () {
      expect(
        parseGoogleIntent('Cancel Connect.')?.kind,
        GoogleIntentKind.cancel,
      );
      expect(
        parseGoogleIntent('cancel google pairing')?.kind,
        GoogleIntentKind.cancel,
      );
      expect(
        parseGoogleIntent('stop connecting')?.kind,
        GoogleIntentKind.cancel,
      );
    });

    test('unlink', () {
      expect(
        parseGoogleIntent('disconnect google')?.kind,
        GoogleIntentKind.unlink,
      );
      expect(
        parseGoogleIntent('revoke my google')?.kind,
        GoogleIntentKind.unlink,
      );
      expect(
        parseGoogleIntent('unlink my google')?.kind,
        GoogleIntentKind.unlink,
      );
    });

    test('unrelated', () {
      expect(parseGoogleIntent('what is the weather'), isNull);
      expect(parseGoogleIntent('turn up the volume'), isNull);
    });
  });

  group('GooglePairingPhase', () {
    test('in flight', () {
      expect(
        const GooglePairingStatus(
          phase: GooglePairingPhase.awaitingUser,
          hasTokens: false,
          toolsReady: false,
        ).isPairingInFlight,
        isTrue,
      );
      expect(
        const GooglePairingStatus(
          phase: GooglePairingPhase.linked,
          hasTokens: true,
          toolsReady: true,
        ).isPairingInFlight,
        isFalse,
      );
    });
  });
}
