import 'dart:io';

import 'package:comstar_bridge/conversation_memory.dart';
import 'package:comstar_bridge/durable_memory.dart';
import 'package:test/test.dart';

void main() {
  group('ConversationMemory', () {
    late Directory tmp;
    late ConversationMemory memory;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('comstar-memory-test');
      memory = ConversationMemory(
        store: FileConversationMemoryStore(root: tmp),
        maxTurns: 20,
        promptMaxTurns: 2,
        maxInjectChars: 2000,
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

    test('wrapForAgent is thin: recent pairs only, no facts block', () async {
      await memory.recordExchange(
        userid: 'zlatko',
        userText: "What's up?",
        assistantText: 'Just hanging in the hallway.',
      );
      await memory.recordExchange(
        userid: 'zlatko',
        userText: 'Remember that I prefer quiet evenings',
        assistantText: 'Got it — quiet evenings noted.',
      );

      final prompt = await memory.wrapForAgent('zlatko', 'What do I prefer?');
      expect(prompt, contains('Prior conversation'));
      expect(prompt, contains('Current request:'));
      expect(prompt, contains('What do I prefer?'));
      expect(prompt, contains('quiet evenings'));
      expect(prompt, contains('[hall]'));
      // No durable-facts dump in the prompt.
      expect(prompt, isNot(contains('Known facts')));
      // Two pairs fit in promptMaxTurns=2.
      expect(prompt, contains("What's up?"));
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

    test('wrapForAgent filters greeter and working-ack noise', () async {
      await memory.recordExchange(
        userid: 'zlatko',
        userText: 'hello',
        assistantText: 'Good morning — welcome back.',
      );
      await memory.recordExchange(
        userid: 'zlatko',
        userText: 'turn on the kitchen light',
        assistantText: 'One moment.',
      );
      await memory.recordExchange(
        userid: 'zlatko',
        userText: 'the under-cabinet one',
        assistantText: 'Done — under-cabinet kitchen light is on.',
      );
      final prompt = await memory.wrapForAgent('zlatko', 'dim it a bit');
      expect(prompt, contains('under-cabinet'));
      expect(prompt, isNot(contains('Good morning')));
      expect(prompt, isNot(contains('One moment')));
      expect(prompt, isNot(contains('Awaiting your voice')));
    });

    test('trims store to maxTurns', () async {
      for (var i = 0; i < 5; i++) {
        await memory.recordExchange(
          userid: 'zlatko',
          userText: 'user $i',
          assistantText: 'asst $i',
        );
      }
      final hist = await memory.store.load('zlatko');
      // maxTurns on this fixture is 20; use a tight memory for trim.
      final tight = ConversationMemory(
        store: FileConversationMemoryStore(root: tmp),
        maxTurns: 4,
        promptMaxTurns: 2,
      );
      for (var i = 0; i < 5; i++) {
        await tight.recordExchange(
          userid: 'ace',
          userText: 'user $i',
          assistantText: 'asst $i',
        );
      }
      final trimmed = await tight.store.load('ace');
      expect(trimmed.turns.length, 4);
      expect(trimmed.turns.first.text, 'user 3');
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

    test('wrapForAgent drops bloated house-status dumps', () async {
      final dump =
          'Hi there! It looks like everything around your house is running smoothly. '
          'The security systems, climate controls, and appliances are all functioning properly. '
          'The home network is stable, and the internet speed is as expected. '
          'Your irrigation systems are also up to date. No alarms detected. '
          'If you were asking about global news, here is a quick update: something happened.';
      await memory.recordExchange(
        userid: 'zlatko',
        userText: "What's going on around my house?",
        assistantText: dump,
      );
      await memory.recordExchange(
        userid: 'zlatko',
        userText: "What's going on around my house?",
        assistantText: dump,
      );
      final prompt = await memory.wrapForAgent(
        'zlatko',
        "What's the status of my home?",
      );
      expect(prompt, contains("What's the status of my home?"));
      expect(prompt, isNot(contains('running smoothly')));
      expect(prompt, isNot(contains('global news')));
      expect(prompt, isNot(contains('security systems')));
    });

    test('fat history stays within prompt_max_turns pairs', () async {
      for (var i = 0; i < 8; i++) {
        await memory.recordExchange(
          userid: 'zlatko',
          userText: 'seed-user-$i with filler about world news headlines',
          assistantText:
              'seed-asst-$i long reply that must not all fit in the prompt window xxx',
        );
      }
      final prompt = await memory.wrapForAgent('zlatko', 'home status please');
      expect(prompt, contains('home status please'));
      expect(prompt, contains('seed-user-7'));
      expect(prompt, contains('seed-asst-7'));
      // promptMaxTurns=2 → at most 4 turn lines (+ framing).
      expect(prompt, isNot(contains('seed-user-0')));
      expect(prompt, isNot(contains('seed-asst-0')));
      expect(prompt, isNot(contains('Known facts')));
      expect(prompt.length, lessThan(2500));
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
      expect(prompt, contains('which button'));
      final hist = await memory.store.load('zlatko');
      expect(hist.turns.length, 1);
      expect(hist.turns.single.role, 'assistant');
    });

    test('durable facts still recorded but not wrapped', () async {
      await memory.recordExchange(
        userid: 'zlatko',
        userText: 'Remember that I prefer Assam tea',
        assistantText: 'Noted.',
      );
      final facts = await memory.store.searchFacts('zlatko', query: 'tea');
      expect(facts, isNotEmpty);
      final prompt = await memory.wrapForAgent('zlatko', 'any tea prefs?');
      expect(prompt, isNot(contains('Known facts')));
    });
  });

  group('extractDurableFacts hardened', () {
    test('accepts remember / prefer', () {
      final facts = extractDurableFacts('Remember that I prefer dark mode');
      expect(facts, isNotEmpty);
      expect(facts.any((f) => f.text.toLowerCase().contains('dark')), isTrue);
    });

    test('rejects epistemic junk', () {
      expect(extractDurableFacts("I don't know what that is"), isEmpty);
      expect(extractDurableFacts("I don't hear you"), isEmpty);
      expect(extractDurableFacts('Do not. Do not know the answer'), isEmpty);
      expect(extractDurableFacts('Remember that I do not know'), isEmpty);
    });

    test('call me / prefer still work', () {
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
}
