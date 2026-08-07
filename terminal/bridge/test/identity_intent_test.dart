import 'package:comstar_bridge/identity_intent.dart';
import 'package:test/test.dart';

void main() {
  test('who am i', () {
    expect(parseIdentityIntent('Who am I?')?.kind, IdentityIntentKind.whoAmI);
    expect(
      parseIdentityIntent("Do you know me?")?.kind,
      IdentityIntentKind.whoAmI,
    );
  });

  test('recognize me', () {
    expect(
      parseIdentityIntent('Recognize me')?.kind,
      IdentityIntentKind.recognizeMe,
    );
    expect(
      parseIdentityIntent('Look at me again')?.kind,
      IdentityIntentKind.recognizeMe,
    );
  });

  test('unrelated null', () {
    expect(parseIdentityIntent('what time is it'), isNull);
    expect(parseIdentityIntent('turn on the lights'), isNull);
  });
}
