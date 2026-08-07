import 'dart:convert';

import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/ha_agent_client.dart';
import 'package:comstar_bridge/house_presence.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

http.Response _emptyPersonList() => http.Response(
      jsonEncode({'success': true, 'entities': <dynamic>[]}),
      200,
    );

void main() {
  group('PresenceConfig', () {
    test('parses ha_person_by_uid', () {
      final base = ComstarConfig.loadFile(
        'test/fixtures/comstar.valid.yaml',
      );
      final map = _baseMap(base);
      map['presence'] = {
        'ha_person_by_uid': {
          'zlatko': 'person.zlatko_lakisic',
          'alice': 'person.alice',
        },
      };
      final cfg = ComstarConfig.loadMap(map, sourcePath: 't.yaml');
      expect(cfg.presence.haPersonByUid['zlatko'], 'person.zlatko_lakisic');
      expect(cfg.presence.haPersonByUid['alice'], 'person.alice');
    });

    test('rejects non-person entity', () {
      final base = ComstarConfig.loadFile(
        'test/fixtures/comstar.valid.yaml',
      );
      final map = _baseMap(base);
      map['presence'] = {
        'ha_person_by_uid': {'zlatko': 'sensor.foo'},
      };
      expect(
        () => ComstarConfig.loadMap(map, sourcePath: 't.yaml'),
        throwsA(isA<ConfigError>()),
      );
    });
  });

  group('HousePresenceService', () {
    test('snapshot maps HA entity states', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/list')) return _emptyPersonList();
        expect(request.url.path, contains('person.zlatko_lakisic'));
        return http.Response(
          jsonEncode({
            'success': true,
            'state': {
              'entity_id': 'person.zlatko_lakisic',
              'state': 'home',
              'attributes': {'friendly_name': 'Zlatko'},
            },
          }),
          200,
        );
      });
      final svc = HousePresenceService(
        config: const PresenceConfig(
          haPersonByUid: {'zlatko': 'person.zlatko_lakisic'},
        ),
        clock: FakeClock(1000),
        ha: HaAgentClient(
          httpClient: client,
          baseUrlOverride: 'http://ha.test',
          apiKeyOverride: 'test-key',
        ),
      );
      final snap = await svc.snapshot();
      expect(snap['ts'], 1000);
      final people = snap['people'] as List;
      expect(people, hasLength(1));
      expect(people.first['uid'], 'zlatko');
      expect(people.first['displayName'], 'Zlatko');
      expect(people.first['state'], 'home');
      expect(people.first['ha_entity'], 'person.zlatko_lakisic');
    });

    test('spokenSummary for one person home', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/list')) return _emptyPersonList();
        return http.Response(
          jsonEncode({
            'success': true,
            'state': {
              'state': 'home',
              'attributes': {'friendly_name': 'Zlatko'},
            },
          }),
          200,
        );
      });
      final svc = HousePresenceService(
        config: const PresenceConfig(
          haPersonByUid: {'zlatko': 'person.zlatko_lakisic'},
        ),
        clock: FakeClock(1),
        ha: HaAgentClient(
          httpClient: client,
          baseUrlOverride: 'http://ha.test',
          apiKeyOverride: 'test-key',
        ),
      );
      expect(await svc.spokenSummary(), 'Zlatko is home.');
    });

    test('whereIs matches first name and reports home', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/list')) return _emptyPersonList();
        final path = request.url.path;
        if (path.contains('adna')) {
          return http.Response(
            jsonEncode({
              'success': true,
              'state': {
                'state': 'unknown',
                'attributes': {'friendly_name': 'Adna Zujo Lakisic'},
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'success': true,
            'state': {
              'state': 'home',
              'attributes': {'friendly_name': 'Zlatko Lakisic'},
            },
          }),
          200,
        );
      });
      final svc = HousePresenceService(
        config: const PresenceConfig(
          haPersonByUid: {
            'zlatko': 'person.zlatko_lakisic',
            'adna': 'person.adna_zujo_lakisic',
          },
        ),
        clock: FakeClock(1),
        ha: HaAgentClient(
          httpClient: client,
          baseUrlOverride: 'http://ha.test',
          apiKeyOverride: 'test-key',
        ),
      );

      final z = await svc.whereIs('Zlatko');
      expect(z.matched, isTrue);
      expect(z.liveKnown, isTrue);
      expect(z.spoken, 'Zlatko Lakisic is home.');

      final a = await svc.whereIs('Adna');
      expect(a.matched, isTrue);
      expect(a.liveKnown, isFalse);
      expect(a.spoken, contains('does not have a live location'));
      expect(a.displayName, 'Adna Zujo Lakisic');
    });

    test('whereIs dedupes aliased uids for same entity', () async {
      var stateCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path.contains('/list')) return _emptyPersonList();
        stateCalls++;
        return http.Response(
          jsonEncode({
            'success': true,
            'state': {
              'state': 'home',
              'attributes': {'friendly_name': 'Zlatko Lakisic'},
            },
          }),
          200,
        );
      });
      final svc = HousePresenceService(
        config: const PresenceConfig(
          haPersonByUid: {
            'zlatko': 'person.zlatko_lakisic',
            'zlatko.lakisic': 'person.zlatko_lakisic',
          },
        ),
        clock: FakeClock(1),
        ha: HaAgentClient(
          httpClient: client,
          baseUrlOverride: 'http://ha.test',
          apiKeyOverride: 'test-key',
        ),
      );
      final people = (await svc.snapshot())['people'] as List;
      expect(people, hasLength(1));
      expect(stateCalls, 1);
    });

    test('discovers person.* without yaml map', () async {
      final client = MockClient((request) async {
        expect(request.url.path, contains('/list'));
        expect(request.url.queryParameters['domain'], 'person');
        return http.Response(
          jsonEncode({
            'success': true,
            'entities': [
              {
                'entity_id': 'person.google_home',
                'state': 'unknown',
                'friendly_name': 'Google Home',
              },
              {
                'entity_id': 'person.md_admin',
                'state': 'unknown',
                'friendly_name': 'md-admin',
              },
              {
                'entity_id': 'person.adna_zujo_lakisic',
                'state': 'not_home',
                'friendly_name': 'Adna Zujo Lakisic',
              },
            ],
          }),
          200,
        );
      });
      final svc = HousePresenceService(
        config: const PresenceConfig(),
        clock: FakeClock(1),
        ha: HaAgentClient(
          httpClient: client,
          baseUrlOverride: 'http://ha.test',
          apiKeyOverride: 'test-key',
        ),
      );

      final people = (await svc.snapshot())['people'] as List;
      expect(people, hasLength(1));
      expect(people.first['ha_entity'], 'person.adna_zujo_lakisic');
      expect(people.first['uid'], 'adna_zujo_lakisic');

      final a = await svc.whereIs('Adna');
      expect(a.matched, isTrue);
      expect(a.spoken, 'Adna Zujo Lakisic is away from home.');
    });

    test('yaml mapping wins over discovery for same entity', () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/list')) {
          return http.Response(
            jsonEncode({
              'success': true,
              'entities': [
                {
                  'entity_id': 'person.zlatko_lakisic',
                  'state': 'not_home',
                  'friendly_name': 'Zlatko Lakisic',
                },
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'success': true,
            'state': {
              'state': 'home',
              'attributes': {'friendly_name': 'Zlatko'},
            },
          }),
          200,
        );
      });
      final svc = HousePresenceService(
        config: const PresenceConfig(
          haPersonByUid: {'zlatko': 'person.zlatko_lakisic'},
        ),
        clock: FakeClock(1),
        ha: HaAgentClient(
          httpClient: client,
          baseUrlOverride: 'http://ha.test',
          apiKeyOverride: 'test-key',
        ),
      );
      final people = (await svc.snapshot())['people'] as List;
      expect(people, hasLength(1));
      expect(people.first['uid'], 'zlatko');
      expect(people.first['displayName'], 'Zlatko');
      expect(people.first['state'], 'home');
    });
  });
}

Map<String, dynamic> _baseMap(ComstarConfig base) => {
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
    };
