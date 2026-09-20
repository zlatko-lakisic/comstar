import 'package:comstar_bridge/working_ack.dart';
import 'package:test/test.dart';

void main() {
  group('looksLikeLongToolQuery', () {
    test('arms for home / calendar / lookup work', () {
      expect(looksLikeLongToolQuery('Turn on the kitchen lights'), isTrue);
      expect(looksLikeLongToolQuery("What's on my calendar today?"), isTrue);
      expect(looksLikeLongToolQuery('Check my email'), isTrue);
      expect(looksLikeLongToolQuery("Who's home?"), isTrue);
      expect(looksLikeLongToolQuery('What torrents am I downloading?'), isTrue);
      expect(looksLikeLongToolQuery('Describe the front door camera'), isTrue);
      expect(looksLikeLongToolQuery('Who was in my driveway today?'), isTrue);
      expect(looksLikeLongToolQuery('Any visitors today?'), isTrue);
    });

    test('skips conversational continuity', () {
      expect(looksLikeLongToolQuery("Okay, that's good to know."), isFalse);
      expect(looksLikeLongToolQuery('Thanks'), isFalse);
      expect(looksLikeLongToolQuery('Got it'), isFalse);
      expect(looksLikeLongToolQuery("I don't hear you."), isFalse);
      expect(
        looksLikeLongToolQuery("I couldn't hear you for a second there."),
        isFalse,
      );
      expect(looksLikeLongToolQuery('Sounds good'), isFalse);
    });
  });

  group('looksLikeResearch', () {
    test('matches world news / current events phrasing', () {
      expect(looksLikeResearch("What's going on in the world today?"), isTrue);
      expect(looksLikeResearch('Tell me the news'), isTrue);
      expect(looksLikeResearch('Any current events I should know?'), isTrue);
      expect(looksLikeResearch('Thanks'), isFalse);
    });
  });

  group('looksLikeNewsResearch', () {
    test('matches news / world phrasing only', () {
      expect(
        looksLikeNewsResearch("What's going on in the world today?"),
        isTrue,
      );
      expect(looksLikeNewsResearch('Tell me the news'), isTrue);
      expect(looksLikeNewsResearch('Any current events I should know?'), isTrue);
      expect(looksLikeNewsResearch('Explain photosynthesis'), isFalse);
      expect(looksLikeNewsResearch('Thanks'), isFalse);
    });
  });

  group('seedNewsFetchPrompt', () {
    test('embeds RSS fetch URLs and anti-placeholder rules', () {
      final prompt = seedNewsFetchPrompt("What's going on in the world today?");
      expect(prompt, contains("What's going on in the world today?"));
      expect(prompt, contains('https://feeds.bbci.co.uk/news/world/rss.xml'));
      expect(prompt, contains('https://www.npr.org/rss/rss.php?id=1001'));
      expect(prompt, isNot(contains('https://www.reuters.com/')));
      expect(prompt, contains('[Description]'));
      expect(prompt, contains('fetch_url'));
      expect(prompt, contains('RSS'));
    });
  });

  group('steerDynamicResearchChat', () {
    test('requires step mcp_providers fetch_url and forbids weather drift', () {
      final out = steerDynamicResearchChat(
        'Current request:\nTell me the news',
        'Tell me the news',
      );
      expect(out, contains('mcp_providers: ["fetch_url"]'));
      expect(out, contains('https://feeds.bbci.co.uk/news/world/rss.xml'));
      expect(out, contains('Do not attach weather_mcp'));
      expect(out, isNot(contains('weather_mcp when useful')));
      expect(out, contains('Current request:'));
    });

    test('leaves non-research prompts unchanged', () {
      expect(steerDynamicResearchChat('hello', 'Thanks'), 'hello');
    });
  });

  group('shouldArmWorkingAck', () {
    test('arms only when utterance looks tool-heavy', () {
      expect(
        shouldArmWorkingAck(
          mcpProviders: const ['home_assistant'],
          workingAckOnTools: true,
          workingAckMs: 4500,
          utterance: 'Turn off the hallway light',
        ),
        isTrue,
      );
      expect(
        shouldArmWorkingAck(
          mcpProviders: const ['home_assistant'],
          workingAckOnTools: true,
          workingAckMs: 4500,
          utterance: "Okay, that's good to know.",
        ),
        isFalse,
      );
    });

    test('skips when tools required but providers empty', () {
      expect(
        shouldArmWorkingAck(
          mcpProviders: const [],
          workingAckOnTools: true,
          workingAckMs: 4500,
          utterance: 'Turn on the lights',
        ),
        isFalse,
      );
    });

    test('still requires tool-like utterance when on_tools false', () {
      expect(
        shouldArmWorkingAck(
          mcpProviders: const [],
          workingAckOnTools: false,
          workingAckMs: 4500,
          utterance: 'Thanks',
        ),
        isFalse,
      );
      expect(
        shouldArmWorkingAck(
          mcpProviders: const [],
          workingAckOnTools: false,
          workingAckMs: 4500,
          utterance: 'Check my calendar',
        ),
        isTrue,
      );
    });

    test('disabled when working_ack_ms is 0', () {
      expect(
        shouldArmWorkingAck(
          mcpProviders: const ['home_assistant'],
          workingAckOnTools: true,
          workingAckMs: 0,
          utterance: 'Turn on the lights',
        ),
        isFalse,
      );
    });
  });

  group('prefixResultReady', () {
    test('prepends preface', () {
      expect(
        prefixResultReady('The lights are on.', preface: 'I have what you asked for.'),
        'I have what you asked for. The lights are on.',
      );
    });

    test('skips when reply already framed', () {
      expect(
        prefixResultReady(
          'I have what you asked for. Kitchen is 72.',
          preface: 'I have what you asked for.',
        ),
        'I have what you asked for. Kitchen is 72.',
      );
    });

    test('uses default preface', () {
      expect(
        prefixResultReady('Done.'),
        'I have what you asked for. Done.',
      );
    });
  });
}
