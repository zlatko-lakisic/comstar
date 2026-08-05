import 'dart:io';

import 'package:comstar_bridge/conversation_memory.dart';
import 'package:test/test.dart';

void main() {
  group('ConversationMemory', () {
    late Directory tmp;
    late ConversationMemory memory;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('comstar-memory-test');
      memory = ConversationMemory(
        store: FileConversationMemoryStore(root: tmp),
        maxTurns: 4,
        maxInjectChars: 200,
        terminalId: 'hall',
        now: () => DateTime.utc(2026, 8, 5, 2, 0),
      );
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('isMemoryUser rejects guests', () {
      expect(ConversationMemory.isMemoryUser('zlatko'), isTrue);
      expect(ConversationMemory.isMemoryUser('guest'), isFalse);
      expect(ConversationMemory.isMemoryUser('unknown'), isFalse);
      expect(ConversationMemory.isMemoryUser(null), isFalse);
    });

    test('records and wraps prior turns', () async {
      await memory.recordExchange(
        userid: 'zlatko',
        userText: "What's up?",
        assistantText: 'Just hanging in the hallway.',
      );
      await memory.recordExchange(
        userid: 'zlatko',
        userText: 'Remember that I prefer quiet evenings',
        assistantText: 'Got it.',
      );

      final prompt = await memory.wrapForAgent('zlatko', 'What do I prefer?');
      expect(prompt, contains('Prior conversation'));
      expect(prompt, contains("What's up?"));
      expect(prompt, contains('Known facts'));
      expect(prompt.toLowerCase(), contains('quiet'));
      expect(prompt, contains('Current request:'));
      expect(prompt, contains('What do I prefer?'));
      expect(prompt, contains('[hall]'));
    });

    test('trims to maxTurns', () async {
      for (var i = 0; i < 5; i++) {
        await memory.recordExchange(
          userid: 'zlatko',
          userText: 'user $i',
          assistantText: 'asst $i',
        );
      }
      final hist = await memory.store.load('zlatko');
      expect(hist.turns.length, 4);
      expect(hist.turns.first.text, 'user 3');
    });

    test('formatHistoryBlock drops oldest when over budget', () {
      final turns = <ConversationTurn>[];
      for (var i = 0; i < 5; i++) {
        turns.add(
          ConversationTurn(
            role: i.isEven ? 'user' : 'assistant',
            text: 'line-$i-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
            tsMs: i,
          ),
        );
      }
      final block = ConversationMemory.formatHistoryBlock(turns, maxChars: 120);
      expect(block.length, lessThanOrEqualTo(120));
      expect(block, contains('COMSTAR'));
      expect(block, isNot(contains('line-0-')));
    });

    test('guests get no wrap', () async {
      final prompt = await memory.wrapForAgent('guest', 'hello');
      expect(prompt, 'hello');
    });
  });
}
