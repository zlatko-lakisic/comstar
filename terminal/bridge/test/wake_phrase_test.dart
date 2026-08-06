import 'package:comstar_bridge/wake_phrase.dart';
import 'package:test/test.dart';

void main() {
  test('accepts hey/hello comstar', () {
    expect(isComstarWakePhrase('hey comstar'), isTrue);
    expect(isComstarWakePhrase('Hello Comstar!'), isTrue);
    expect(isComstarWakePhrase('hey comstar what time is it'), isTrue);
    expect(isComstarWakePhrase('okay hello comstar'), isTrue);
  });

  test('strips residual prompt after wake phrase', () {
    expect(residualAfterWakePhrase('hey comstar'), isEmpty);
    expect(residualAfterWakePhrase('hey comstar whats up'), 'whats up');
    expect(residualAfterWakePhrase('Hey Comestar, what are you up to?'),
        'what are you up to');
    expect(residualAfterWakePhrase('hello comstar what time is it'),
        'what time is it');
    expect(residualAfterWakePhrase('comstar volume up'), 'volume up');
    expect(residualAfterWakePhrase('just hello'), isEmpty);
  });

  test('rejects bare hello / hey / noise', () {
    expect(isComstarWakePhrase('hello'), isFalse);
    expect(isComstarWakePhrase('hey'), isFalse);
    expect(isComstarWakePhrase('hello there'), isFalse);
    expect(isComstarWakePhrase(''), isFalse);
  });

  test('accepts STT mishears of comstar', () {
    expect(isComstarWakePhrase('hey com star'), isTrue);
    expect(isComstarWakePhrase('hello come star'), isTrue);
    expect(isComstarWakePhrase('comstar'), isTrue);
    expect(isComstarWakePhrase('hi comstar'), isTrue);
    // Live Pi Whisper mangling (logs 2026-08-03).
    expect(isComstarWakePhrase('Hey Comestar!'), isTrue);
    expect(isComstarWakePhrase('Hey, Comestar.'), isTrue);
    expect(isComstarWakePhrase('Hey Comster!'), isTrue);
    expect(isComstarWakePhrase('Hey ComStore.'), isTrue);
    expect(isComstarWakePhrase('Hey Comestar, what are you up to?'), isTrue);
    expect(isComstarWakePhrase('Hey come start'), isTrue);
    expect(isComstarWakePhrase('Hey, here comes the star'), isTrue);
  });
}
