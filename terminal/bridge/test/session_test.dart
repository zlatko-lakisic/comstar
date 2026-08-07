import 'package:ao_reach/ao_reach.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/session.dart';
import 'package:test/test.dart';

class FakeReachBridge implements ReachSessionBridge {
  ReachConnectionConfig? lastConfig;
  String? lastOverlay;
  bool active = false;
  String? lastAgentId;
  List<String>? lastMcpIds;
  String? lastText;
  SpeechClient? fakeSpeech;
  List<String> fakeRegisteredMcpIds = const ['client.terminal'];
  List<String> fakeRegisteredAgentIds = const [
    'client.voice_responder',
    'client.greeter',
    'client.phrase_bank',
  ];
  double? fakeExpiresAt;
  int refreshCount = 0;
  int startCount = 0;
  Object? directAgentError;
  Object? refreshError;

  @override
  bool get isActive => active;

  @override
  List<String> get registeredMcpIds => fakeRegisteredMcpIds;

  @override
  List<String> get registeredAgentIds => fakeRegisteredAgentIds;

  @override
  double? get expiresAt => fakeExpiresAt;

  @override
  SpeechClient? get speechClient => fakeSpeech;

  @override
  Future<void> start({
    required ReachConnectionConfig config,
    required String overlayRoot,
    SessionMcpBootstrap mcpBootstrap = const EmptySessionMcpBootstrap(),
  }) async {
    lastConfig = config;
    lastOverlay = overlayRoot;
    active = true;
    startCount++;
    fakeExpiresAt =
        DateTime.now().millisecondsSinceEpoch / 1000.0 + config.ttlSeconds;
  }

  @override
  Future<void> stop({bool clearRemote = true}) async {
    active = false;
    fakeExpiresAt = null;
  }

  @override
  Future<Map<String, dynamic>> directAgent({
    required String agentProviderId,
    required String text,
    List<String>? mcpProviderIds,
    Duration? timeout,
  }) async {
    if (directAgentError != null) {
      final err = directAgentError!;
      directAgentError = null;
      throw err;
    }
    lastAgentId = agentProviderId;
    lastText = text;
    lastMcpIds = mcpProviderIds;
    return {'ok': true, 'text': 'hello'};
  }

  @override
  Future<void> refreshOverlay() async {
    refreshCount++;
    if (refreshError != null) {
      final err = refreshError!;
      refreshError = null;
      throw err;
    }
    if (!active) {
      throw StateError('Session bridge is not active — cannot refresh overlay');
    }
    final ttl = lastConfig?.ttlSeconds ?? 3600;
    fakeExpiresAt = DateTime.now().millisecondsSinceEpoch / 1000.0 + ttl;
  }
}

ComstarConfig _config() => ComstarConfig.loadMap(
      {
        'orchestration': {
          'base_url': 'http://10.0.10.16:8765',
          'token': 'test-token',
          'ttl_seconds': 3600,
          'timeout_seconds': 15,
          'overlay_root': './overlays/comstar',
        },
        'vision': {
          'codeproject_url': 'http://127.0.0.1:32168',
          'detection_endpoint': '/v1/vision/detection',
          'recognize_endpoint': '/v1/vision/face/recognize',
          'ambient_fps': 1,
          'engaged_fps': 3,
          'person_confidence': 0.6,
          'face_confidence': 0.55,
          'recognize_votes': 3,
          'identity_ttl_seconds': 300,
        },
        'audio': {
          'wakeword_model': './models/hey_comstar.onnx',
          'wakeword_threshold': 0.55,
          'vad_silence_ms': 700,
          'max_utterance_seconds': 15,
          'followup_window_seconds': 10,
          'duplex': 'half',
        },
        'avatar': {
          'render': 'local',
          'model': './assets/comstar.glb',
          'tts': 'piper',
          'piper_voice': 'en_US-ryan-high',
        },
        'attention': {
          'face_attention_trigger': false,
          'stranger_mode': 'restricted',
        },
        'directory': {
          'enabled': false,
          'sidecar_url': '',
          'require': true,
          'cache_ttl_seconds': 600,
          'timeout_ms': 1500,
        },
        'dev': {
          'bind_lan': false,
          'lan_token': '',
        },
      },
      sourcePath: 'test.yaml',
    );

void main() {
  group('ComstarSession', () {
    late FakeReachBridge fake;
    late ComstarSession session;

    setUp(() {
      fake = FakeReachBridge();
      session = ComstarSession(config: _config(), bridge: fake);
    });

    test('open sets identity headers for known user', () async {
      await session.open(userid: 'zlatko', guest: false);

      expect(fake.active, isTrue);
      expect(fake.lastConfig!.headers['x-agentic-user-name'], 'zlatko');
      expect(fake.lastConfig!.headers['x-agentic-session-id'], 'comstar-zlatko');
      expect(fake.lastConfig!.headers['x-warpgate-token'], 'test-token');
      expect(fake.lastOverlay, './overlays/comstar');
    });

    test('guest session uses guest header', () async {
      await session.open(userid: 'guest', guest: true);

      expect(fake.lastConfig!.headers['x-agentic-user-name'], 'guest');
    });

    test('guest MCP list excludes home_assistant', () async {
      await session.open(userid: 'guest', guest: true);
      await session.directVoice('hello');

      expect(fake.lastMcpIds, isNot(contains('home_assistant')));
      expect(fake.lastMcpIds, isEmpty);
    });


    test('voice MCP list omits client.terminal when tunnel not registered', () async {
      fake.fakeRegisteredMcpIds = const [];
      await session.open(userid: 'zlatko', guest: false);
      await session.directVoice('hello');

      expect(fake.lastMcpIds, contains('home_assistant'));
      expect(fake.lastMcpIds, isNot(contains('client.terminal')));
      expect(fake.lastMcpIds, isNot(contains('client.google_workspace')));
      expect(fake.lastMcpIds, equals(['home_assistant']));
    });

    test('known user default voice omits tunnel google (AO 1.28 name bug)', () async {
      fake.fakeRegisteredMcpIds = const [
        'client.terminal',
        'client.google_workspace',
      ];
      await session.open(userid: 'zlatko', guest: false);
      await session.directVoice('hello');

      expect(fake.lastMcpIds, contains('home_assistant'));
      expect(fake.lastMcpIds, isNot(contains('client.google_workspace')));
      expect(fake.lastMcpIds, isNot(contains('client.terminal')));
      expect(fake.lastMcpIds, equals(['home_assistant']));
    });

    test('known user MCP list includes home_assistant only for voice', () async {
      await session.open(userid: 'zlatko', guest: false);
      await session.directVoice('hello');

      expect(fake.lastMcpIds, contains('home_assistant'));
      expect(fake.lastMcpIds, isNot(contains('client.terminal')));
      // Fake defaults register client.terminal only — google filtered out.
      expect(fake.lastMcpIds, equals(['home_assistant']));
    });

    test('google calendar utterance uses google MCP only', () async {
      fake.fakeRegisteredMcpIds = const [
        'client.google_workspace',
        'client.terminal',
      ];
      await session.open(userid: 'zlatko', guest: false);
      expect(
        session.mcpProvidersForVoice(utterance: "What's on my calendar today?"),
        equals(['client.google_workspace']),
      );
      await session.directVoice('What is on my Google Calendar today?');
      expect(fake.lastMcpIds, equals(['client.google_workspace']));
    });

    test('directory lookup utterance uses ldap_directory MCP', () async {
      fake.fakeRegisteredMcpIds = const [
        'home_assistant',
        'ldap_directory',
        'vision_comstar',
      ];
      await session.open(userid: 'zlatko.lakisic', guest: false);
      expect(
        session.mcpProvidersForVoice(
          utterance: 'Look up user zlatko.lakisic in the directory',
        ),
        equals(['ldap_directory']),
      );
    });

    test('front door camera utterance uses vision_comstar MCP', () async {
      fake.fakeRegisteredMcpIds = const [
        'home_assistant',
        'ldap_directory',
        'vision_comstar',
      ];
      await session.open(userid: 'zlatko.lakisic', guest: false);
      expect(
        session.mcpProvidersForVoice(
          utterance: "Who is at the front door?",
        ),
        equals(['vision_comstar']),
      );
      expect(
        session.mcpProvidersForVoice(
          utterance: 'Who was in my driveway today?',
        ),
        equals(['vision_comstar']),
      );
      expect(
        session.mcpProvidersForVoice(utterance: "Who's home?"),
        equals(['home_assistant']),
      );
    });

    test('guest MCP list excludes google workspace and terminal', () async {
      fake.fakeRegisteredMcpIds = const [
        'client.google_workspace',
        'client.terminal',
      ];
      await session.open(userid: 'guest', guest: true);
      expect(session.mcpProvidersForVoice(), isEmpty);
      expect(
        session.mcpProvidersForVoice(),
        isNot(contains('client.google_workspace')),
      );
      expect(
        session.mcpProvidersForVoice(),
        isNot(contains('client.terminal')),
      );
    });

    test('identity switch closes prior session', () async {
      await session.open(userid: 'zlatko', guest: false);
      await session.open(userid: 'other', guest: false);

      expect(fake.lastConfig!.headers['x-agentic-user-name'], 'other');
    });

    test('close clears session', () async {
      await session.open(userid: 'zlatko', guest: false);
      await session.close();
      expect(fake.active, isFalse);
      expect(session.isOpen, isFalse);
    });

    test('ensureReady refreshes overlay when near expiry', () async {
      await session.open(userid: 'zlatko', guest: false);
      fake.fakeExpiresAt =
          DateTime.now().millisecondsSinceEpoch / 1000.0 + 10; // within lead
      final before = fake.refreshCount;
      await session.ensureReady();
      expect(fake.refreshCount, before + 1);
      expect(fake.active, isTrue);
    });

    test('ensureReady reopens when bridge is inactive', () async {
      await session.open(userid: 'zlatko', guest: false);
      final starts = fake.startCount;
      fake.active = false;
      await session.ensureReady();
      expect(fake.active, isTrue);
      expect(fake.startCount, greaterThan(starts));
    });

    test('ensureReady reopens when overlay refresh fails', () async {
      await session.open(userid: 'zlatko', guest: false);
      fake.fakeExpiresAt =
          DateTime.now().millisecondsSinceEpoch / 1000.0 + 10;
      fake.refreshError = StateError('overlay gone');
      final starts = fake.startCount;
      await session.ensureReady();
      expect(fake.active, isTrue);
      expect(fake.startCount, greaterThan(starts));
    });

    test('directVoice renews after unknown agent failure', () async {
      await session.open(userid: 'zlatko', guest: false);
      fake.directAgentError = StateError(
        "unknown agent_provider_id 'client.voice_responder'; not in catalog",
      );
      final starts = fake.startCount;
      final text = await session.directVoice('hello');
      expect(text, 'hello');
      expect(fake.startCount, greaterThan(starts));
    });
  });
}
