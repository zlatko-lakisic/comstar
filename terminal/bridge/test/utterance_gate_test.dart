import 'package:comstar_bridge/utterance_gate.dart';
import 'package:test/test.dart';

void main() {
  group('collapseRepeatedUtterance', () {
    test('keeps single phrase', () {
      expect(
        collapseRepeatedUtterance('What torrents do I have downloading?'),
        'What torrents do I have downloading?',
      );
    });

    test('collapses doubled phrase', () {
      expect(
        collapseRepeatedUtterance(
          'What torrents do I have downloading? What torrents do I have downloading?',
        ),
        'What torrents do I have downloading?',
      );
    });
  });

  group('isActionableUtterance', () {
    test('allows questions and commands', () {
      expect(isActionableUtterance('What torrents am I downloading?'), isTrue);
      expect(isActionableUtterance('Check my email'), isTrue);
      expect(isActionableUtterance('Go to sleep'), isTrue);
      expect(isActionableUtterance('Who am I?'), isTrue);
      expect(isActionableUtterance('Reconnect my Google'), isTrue);
      expect(isActionableUtterance('Can you compose a new email for me?'), isTrue);
      expect(isActionableUtterance('What time is it?'), isTrue);
      expect(isActionableUtterance("What's up?"), isTrue);
      expect(isActionableUtterance('How are you?'), isTrue);
    });

    test('allows conversational replies to check-ins', () {
      expect(isActionableUtterance('Yes'), isTrue);
      expect(isActionableUtterance('Yeah'), isTrue);
      expect(isActionableUtterance('No'), isTrue);
      expect(isActionableUtterance('Sure'), isTrue);
      expect(isActionableUtterance('Okay'), isTrue);
      expect(isActionableUtterance("I'm fine"), isTrue);
      expect(isActionableUtterance("I'm good"), isTrue);
      expect(isActionableUtterance('Everything is fine'), isTrue);
      expect(isActionableUtterance('All good'), isTrue);
      expect(isActionableUtterance('Not really'), isTrue);
      expect(isActionableUtterance('Yes everything is fine'), isTrue);
      expect(isActionableUtterance('Got it'), isTrue);
    });

    test('rejects fragments and ambient non-prompts', () {
      expect(isActionableUtterance("I'm"), isFalse);
      expect(isActionableUtterance('Hey!'), isFalse);
      expect(isActionableUtterance('Easy.'), isFalse);
      expect(isActionableUtterance('Got this.'), isFalse);
      expect(isActionableUtterance("I'm sorry."), isFalse);
      expect(
        isActionableUtterance(
          "and we are going to do the opposite, that's it.",
        ),
        isFalse,
      );
    });
  });
}