import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/conversation_memory.dart';
import 'package:comstar_bridge/curated_rag.dart';
import 'package:test/test.dart';

void main() {
  group('curated RAG pack', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('comstar-rag-test');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('loadCuratedRagPack requires enabled + non-empty manifest', () {
      expect(
        loadCuratedRagPack(const MemoryConfig(curatedRagEnabled: false)),
        isNull,
      );
      final packDir = Directory('${tmp.path}/pack')..createSync();
      File('${packDir.path}/manifest.json').writeAsStringSync(
        jsonEncode({
          'pack_id': 'comstar_resident_facts',
          'fact_count': 1,
          'facts': [
            {'kind': 'preference', 'text': 'Resident prefers Assam tea'},
          ],
        }),
      );
      final pack = loadCuratedRagPack(
        MemoryConfig(
          curatedRagEnabled: true,
          curatedRagPackDir: packDir.path,
        ),
      );
      expect(pack, isNotNull);
      expect(pack!.isUsable, isTrue);
      expect(pack.packId, 'comstar_resident_facts');
    });

    test('rejects greeter/news facts in pack', () {
      final packDir = Directory('${tmp.path}/bad')..createSync();
      File('${packDir.path}/manifest.json').writeAsStringSync(
        jsonEncode({
          'pack_id': 'comstar_resident_facts',
          'fact_count': 1,
          'facts': [
            {
              'kind': 'note',
              'text': 'Headlines from around the world today',
            },
          ],
        }),
      );
      expect(
        loadCuratedRagPack(
          MemoryConfig(
            curatedRagEnabled: true,
            curatedRagPackDir: packDir.path,
          ),
        ),
        isNull,
      );
    });

    test('wrapForAgent steers curated pack on open asks, not news', () async {
      final packDir = Directory('${tmp.path}/pack')..createSync();
      File('${packDir.path}/manifest.json').writeAsStringSync(
        jsonEncode({
          'pack_id': 'comstar_resident_facts',
          'fact_count': 1,
          'facts': [
            {'kind': 'preference', 'text': 'Resident prefers Assam tea'},
          ],
        }),
      );
      final memory = ConversationMemory(
        store: FileConversationMemoryStore(root: tmp),
        curatedRagEnabled: true,
        curatedRagPackDir: packDir.path,
        promptMaxTurns: 0,
      );
      final open = await memory.wrapForAgent('zlatko', 'what tea do I like?');
      expect(open, contains('comstar_resident_facts'));
      expect(open, contains('Never attach orchestrator_kb'));
      final news = await memory.wrapForAgent(
        'zlatko',
        "What's happening in the world today?",
      );
      expect(news, isNot(contains('comstar_resident_facts')));
    });
  });

  test('config parses prompt_max_turns and curated_rag', () {
    final base = ComstarConfig.loadFile(
      '${Directory.current.path}/test/fixtures/comstar.valid.yaml',
    );
    final map = <String, dynamic>{
      'orchestration': {
        'base_url': base.orchestration.baseUrl,
        'token': base.orchestration.token,
        'ttl_seconds': base.orchestration.ttlSeconds,
        'timeout_seconds': base.orchestration.timeoutSeconds,
        'overlay_root': base.orchestration.overlayRoot,
      },
      'vision': {
        'codeproject_url': base.vision.codeprojectUrl,
        'detection_endpoint': base.vision.detectionEndpoint,
        'recognize_endpoint': base.vision.recognizeEndpoint,
        'ambient_fps': base.vision.ambientFps,
        'engaged_fps': base.vision.engagedFps,
        'person_confidence': base.vision.personConfidence,
        'face_confidence': base.vision.faceConfidence,
        'recognize_votes': base.vision.recognizeVotes,
        'identity_ttl_seconds': base.vision.identityTtlSeconds,
      },
      'audio': {
        'wakeword_model': base.audio.wakewordModel,
        'wakeword_threshold': base.audio.wakewordThreshold,
        'vad_silence_ms': base.audio.vadSilenceMs,
        'max_utterance_seconds': base.audio.maxUtteranceSeconds,
        'followup_window_seconds': base.audio.followupWindowSeconds,
        'duplex': base.audio.duplex,
      },
      'avatar': {
        'render': base.avatar.render,
        'model': base.avatar.model,
        'tts': base.avatar.tts,
        'piper_voice': base.avatar.piperVoice,
      },
      'attention': {
        'face_attention_trigger': base.attention.faceAttentionTrigger,
        'stranger_mode': base.attention.strangerMode,
      },
      'directory': {
        'enabled': false,
        'sidecar_url': '',
        'require': true,
        'cache_ttl_seconds': 600,
        'timeout_ms': 1500,
      },
      'dev': {'bind_lan': false, 'lan_token': ''},
      'memory': {
        'prompt_max_turns': 3,
        'curated_rag_enabled': true,
        'curated_rag_id': 'comstar_resident_facts',
      },
    };
    final cfg = ComstarConfig.loadMap(map, sourcePath: 'test-memory.yaml');
    expect(cfg.memory.promptMaxTurns, 3);
    expect(cfg.memory.curatedRagEnabled, isTrue);
    expect(cfg.memory.curatedRagId, 'comstar_resident_facts');
  });
}
