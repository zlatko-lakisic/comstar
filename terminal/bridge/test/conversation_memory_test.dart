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

    test('wrapForAgent drops timeout apology spam', () async {
      await memory.recordExchange(
        userid: 'zlatko',
        userText: 'Do some research on private networks',
        assistantText: 'Sorry, I could not get an answer in time.',
      );
      await memory.recordExchange(
        userid: 'zlatko',
        userText: 'Try again',
        assistantText: 'Private networks isolate traffic with VLANs.',
      );
      final prompt = await memory.wrapForAgent('zlatko', 'Summarize that');
      expect(prompt, contains('Current request:'));
      expect(prompt, contains('Private networks isolate'));
      expect(prompt, isNot(contains('could not get an answer in time')));
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

    test('formatHistoryBlock can suppress news headline dumps', () {
      final turns = [
        const ConversationTurn(
          role: 'user',
          text: "What's happening in the world today?",
          tsMs: 1,
        ),
        ConversationTurn(
          role: 'assistant',
          text:
              "Here are some headlines from around the world today:\n"
              "1. Something big happened at the BBC and NPR covered it too.\n"
              "2. Another story about elections around the world today.\n"
              "3. A third headline so this is clearly a news dump reply.",
          tsMs: 2,
        ),
        const ConversationTurn(
          role: 'user',
          text: 'You snuck on me',
          tsMs: 3,
        ),
      ];
      final kept = ConversationMemory.formatHistoryBlock(
        turns,
        maxChars: 2000,
        suppressNewsAnswers: true,
      );
      expect(kept, contains('You snuck on me'));
      expect(kept, isNot(contains('headlines from around the world')));
      final forNews = ConversationMemory.formatHistoryBlock(
        turns,
        maxChars: 2000,
        suppressNewsAnswers: false,
      );
      expect(forNews, contains('headlines from around the world'));
    });

    test('wrapForAgent suppresses prior headlines on non-news asks', () async {
      await memory.recordExchange(
        userid: 'zlatko',
        userText: "What's happening in the world today?",
        assistantText:
            "Here are some headlines from around the world today:\n"
            "1. Example BBC story about something worldwide.\n"
            "2. Example NPR story with enough text to look like a dump.",
      );
      final prompt = await memory.wrapForAgent('zlatko', 'You snuck on me');
      expect(prompt, contains('You snuck on me'));
      expect(prompt, contains('Do not recite prior world news'));
      expect(prompt, isNot(contains('headlines from around the world')));
    });

    test('guests get no wrap', () async {
      final prompt = await memory.wrapForAgent('guest', 'hello');
      expect(prompt, 'hello');
    });

    test('assistant-only lines are retained for follow-ups', () async {
      await memory.recordExchange(
        userid: 'zlatko',
        userText: '',
        assistantText: 'Just push the button when you are ready.',
      );
      final prompt = await memory.wrapForAgent('zlatko', 'which button');
      expect(prompt, contains('Just push the button'));
      expect(prompt, contains('short follow-up'));
      expect(prompt, contains('which button'));
      final hist = await memory.store.load('zlatko');
      expect(hist.turns.length, 1);
      expect(hist.turns.single.role, 'assistant');
    });
  });
}
