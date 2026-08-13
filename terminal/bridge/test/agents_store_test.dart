import 'dart:io';

import 'package:comstar_bridge/agents/catalog.dart';
import 'package:comstar_bridge/agents/routing.dart';
import 'package:comstar_bridge/agents/store.dart';
import 'package:comstar_bridge/config.dart';
import 'package:test/test.dart';

void main() {
  group('preferDirectVoice / hybrid', () {
    test('home control prefers direct', () {
      expect(
        preferDirectVoice(
          utterance: 'turn on the kitchen lights',
          mcpProviders: const ['home_assistant'],
        ),
        isTrue,
      );
      expect(looksLikeHomeControl('set the thermostat to 72'), isTrue);
    });

    test('open question with only HA mcp prefers dynamic when planning on', () {
      expect(
        shouldUseDynamicChat(
          dynamicPlanning: true,
          voiceBackend: 'hybrid',
          utterance: 'explain quantum tunneling simply',
          mcpProviders: const ['home_assistant'],
        ),
        isTrue,
      );
    });

    test('google specialty prefers direct', () {
      expect(
        shouldUseDynamicChat(
          dynamicPlanning: true,
          voiceBackend: 'hybrid',
          utterance: 'what is on my calendar tomorrow',
          mcpProviders: const ['client.google_workspace'],
        ),
        isFalse,
      );
    });

    test('voice_backend direct never uses chat', () {
      expect(
        shouldUseDynamicChat(
          dynamicPlanning: true,
          voiceBackend: 'direct',
          utterance: 'explain relativity',
          mcpProviders: const ['home_assistant'],
        ),
        isFalse,
      );
    });
  });

  group('AgentsStore', () {
    late Directory tmp;
    late AgentsStore store;
    late OrchestrationConfig yaml;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('comstar-agents-');
      store = AgentsStore(stateDir: tmp.path);
      yaml = const OrchestrationConfig(
        baseUrl: 'http://127.0.0.1:8765',
        token: '',
        ttlSeconds: 3600,
        timeoutSeconds: 15,
        overlayRoot: './overlays/comstar',
        dynamicPlanning: true,
        allowedAgentProviderIds: kCuratedAgentIds,
      );
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('filters cloud agents without secrets', () async {
      final ids = await store.effectiveAllowedIds(yaml);
      expect(ids, ['ollama_qwen2_5_14b_instruct']);
    });

    test('includes openai agents when secret set', () async {
      await store.setSecrets(openaiApiKey: 'sk-test-key-12345678');
      final ids = await store.effectiveAllowedIds(yaml);
      expect(ids, contains('gpt_research'));
      expect(ids, contains('ollama_qwen2_5_14b_instruct'));
      expect(ids, isNot(contains('claude_research')));
      final env = await store.sessionEnvMap();
      expect(env['OPENAI_API_KEY'], 'sk-test-key-12345678');
    });

    test('status masks secrets', () async {
      await store.setSecrets(openaiApiKey: 'sk-abcdefghijklmnop');
      final status = await store.statusPayload(
        yaml: yaml,
        sessionActive: false,
      );
      expect(status['ok'], isTrue);
      final secrets = status['secrets'] as Map;
      final openai = secrets['openai'] as Map;
      expect(openai['configured'], isTrue);
      expect(openai['hint'], isNot(contains('abcdefghijklmnop')));
      expect(openai['masked'], isNot(contains('abcdefghijklmnop')));
      expect(openai['masked'], startsWith('sk-'));
      expect(openai['valid'], isNull);
      expect(status['apply'], isA<Map>());
    });

    test('test_secret without key marks invalid', () async {
      final result = await store.testSecret('openai');
      expect(result['valid'], isFalse);
      expect(result['error'], 'not_configured');
      expect(store.openaiKeyValid, isFalse);
    });

    test('configure persists mcp and skill allowlists', () async {
      await store.configure(
        enabledAgentIds: const ['ollama_qwen2_5_14b_instruct'],
        enabledMcpIds: const ['client.home_assistant'],
        enabledSkillIds: const ['skill.example'],
      );
      final runtime = await store.loadRuntime();
      expect(runtime.enabledMcpIds, ['client.home_assistant']);
      expect(runtime.enabledSkillIds, ['skill.example']);
      expect(await store.effectiveAllowedMcpIds(), ['client.home_assistant']);
      expect(await store.effectiveAllowedSkillIds(), ['skill.example']);
      final status = await store.statusPayload(yaml: yaml, sessionActive: true);
      expect(status['enabled_mcp_ids'], ['client.home_assistant']);
      expect(status['session_open'], isTrue);
      expect(status['ao_progress'], isNull);
    });

    test('sessionEnvMap includes generic catalog secrets', () async {
      await store.setSecrets(env: {'SOME_CATALOG_KEY': 'secret-value'});
      final env = await store.sessionEnvMap();
      expect(env['SOME_CATALOG_KEY'], 'secret-value');
    });
  });
}
