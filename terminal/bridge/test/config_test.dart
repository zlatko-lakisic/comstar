import 'dart:io';

import 'package:comstar_bridge/config.dart';
import 'package:test/test.dart';

void main() {
  group('ComstarConfig', () {
    late String fixturePath;

    setUp(() {
      fixturePath = '${Directory.current.path}/test/fixtures/comstar.valid.yaml';
    });

    test('valid config parses', () {
      final config = ComstarConfig.loadFile(fixturePath);
      expect(config.vision.ambientFps, 1);
      expect(config.vision.engagedFps, 3);
      expect(config.orchestration.timeoutSeconds, 15);
      expect(config.attention.strangerMode, 'restricted');
      expect(config.attention.workingAckMs, 4500);
      expect(config.attention.workingAckOnTools, isTrue);
      expect(config.dev.bindLan, isFalse);
      expect(config.phrases.enabled, isTrue);
      expect(config.phrases.refreshHours, 6);
      expect(config.phrases.bankSize, 8);
    });

    test('phrases section overrides defaults', () {
      final base = ComstarConfig.loadFile(fixturePath);
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
        'dev': {
          'bind_lan': base.dev.bindLan,
          'lan_token': base.dev.lanToken,
        },
        'phrases': {
          'enabled': false,
          'refresh_hours': 12,
          'bank_size': 10,
        },
      };
      final config = ComstarConfig.loadMap(map, sourcePath: 'test.yaml');
      expect(config.phrases.enabled, isFalse);
      expect(config.phrases.refreshHours, 12);
      expect(config.phrases.bankSize, 10);
    });

    test('unknown key is fatal with suggestion', () {
      final base = ComstarConfig.loadFile(fixturePath);
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
          'ambient_fpx': 99,
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
        'dev': {
          'bind_lan': base.dev.bindLan,
          'lan_token': base.dev.lanToken,
        },
      };

      expect(
        () => ComstarConfig.loadMap(map, sourcePath: 'test.yaml'),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Unknown key in vision'),
              contains('ambient_fpx'),
              contains('ambient_fps'),
            ),
          ),
        ),
      );
    });

    test('out of range values are rejected', () {
      final base = ComstarConfig.loadFile(fixturePath);
      final map = <String, dynamic>{
        'orchestration': {
          'base_url': base.orchestration.baseUrl,
          'token': base.orchestration.token,
          'ttl_seconds': base.orchestration.ttlSeconds,
          'timeout_seconds': 120,
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
        'dev': {
          'bind_lan': base.dev.bindLan,
          'lan_token': base.dev.lanToken,
        },
      };

      expect(
        () => ComstarConfig.loadMap(map, sourcePath: 'test.yaml'),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('orchestration.timeout_seconds'),
          ),
        ),
      );
    });

    test('comstar.example.yaml ships with dev.bind_lan false', () {
      final examplePath =
          '${Directory.current.path}/../../config/comstar.example.yaml';
      final config = ComstarConfig.loadFile(examplePath);
      expect(config.dev.bindLan, isFalse);
      expect(config.directory.enabled, isFalse);
    });

    test('directory.enabled requires sidecar_url', () {
      final base = ComstarConfig.loadFile(fixturePath);
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
          'enabled': true,
          'sidecar_url': '',
          'require': true,
          'cache_ttl_seconds': 600,
          'timeout_ms': 1500,
        },
        'dev': {
          'bind_lan': base.dev.bindLan,
          'lan_token': base.dev.lanToken,
        },
      };
      expect(
        () => ComstarConfig.loadMap(map, sourcePath: 'test.yaml'),
        throwsA(
          isA<ConfigError>().having(
            (e) => e.message,
            'message',
            contains('directory.sidecar_url'),
          ),
        ),
      );
    });
  });
}
