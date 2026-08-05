import 'dart:math';

import 'package:comstar_bridge/social_intent.dart';
import 'package:test/test.dart';

void main() {
  test('how are you variants', () {
    expect(parseSocialIntent('How are you?')?.kind, SocialIntentKind.howAreYou);
    expect(parseSocialIntent("how's it going")?.kind, SocialIntentKind.howAreYou);
    expect(parseSocialIntent('how you doing')?.kind, SocialIntentKind.howAreYou);
  });

  test('whats up variants', () {
    expect(parseSocialIntent("what's up")?.kind, SocialIntentKind.whatsUp);
    expect(parseSocialIntent('whats shaking')?.kind, SocialIntentKind.whatsUp);
    expect(parseSocialIntent("what's good")?.kind, SocialIntentKind.whatsUp);
    expect(parseSocialIntent('sup')?.kind, SocialIntentKind.whatsUp);
  });

  test('greetings and thanks', () {
    expect(parseSocialIntent('good morning')?.kind, SocialIntentKind.greeting);
    expect(parseSocialIntent('hello there')?.kind, SocialIntentKind.greeting);
    expect(parseSocialIntent('thank you')?.kind, SocialIntentKind.thanks);
  });

  test('non-social returns null', () {
    expect(parseSocialIntent('what time is it'), isNull);
    expect(parseSocialIntent('go to sleep'), isNull);
    expect(parseSocialIntent('check my calendar'), isNull);
  });

  test('formatSocialAnswer prefers bank line', () {
    final spoken = formatSocialAnswer(
      const SocialIntent(SocialIntentKind.whatsUp),
      bankLine: 'Just vibing in the hallway.',
      random: Random(1),
    );
    expect(spoken, 'Just vibing in the hallway.');
  });

  test('formatSocialAnswer fallback includes name', () {
    final spoken = formatSocialAnswer(
      const SocialIntent(SocialIntentKind.howAreYou),
      name: 'Zlatko',
      // Always pick index 0 — the named variant is first in the pool.
      random: _PickZero(),
    );
    expect(spoken.toLowerCase(), contains('zlatko'));
  });
}

class _PickZero implements Random {
  @override
  int nextInt(int max) => 0;

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}
