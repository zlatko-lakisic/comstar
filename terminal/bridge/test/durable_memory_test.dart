import 'package:comstar_bridge/durable_memory.dart';
import 'package:test/test.dart';

void main() {
  group('extractDurableFacts', () {
    test('remember that', () {
      final facts = extractDurableFacts('Remember that I prefer dark mode');
      expect(facts, isNotEmpty);
      expect(facts.first.kind, anyOf('note', 'preference'));
      expect(facts.any((f) => f.text.toLowerCase().contains('dark')), isTrue);
    });

    test('call me / prefer', () {
      expect(
        extractDurableFacts('Call me Ace').single.text,
        contains('Ace'),
      );
      expect(
        extractDurableFacts('I prefer soft music in the hallway').single.kind,
        'preference',
      );
    });

    test('ignores ephemeral', () {
      expect(extractDurableFacts('what time is it'), isEmpty);
      expect(extractDurableFacts('go to sleep'), isEmpty);
    });
  });

  test('formatFactsBlock', () {
    final block = formatFactsBlock(
      const [
        DurableFact(id: 'a', kind: 'note', text: 'Likes tea'),
        DurableFact(id: 'b', kind: 'pref', text: 'Quiet mornings'),
      ],
      maxChars: 40,
    );
    expect(block, contains('Likes tea'));
    expect(block.length, lessThanOrEqualTo(40));
  });
}
