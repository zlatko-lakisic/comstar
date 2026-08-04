import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/effects.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:comstar_bridge/attention/invariants.dart';
import 'package:comstar_bridge/attention/machine.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:comstar_bridge/config.dart';
import 'package:test/test.dart';

ComstarConfig _loadConfig({String strangerMode = 'restricted'}) {
  final base = ComstarConfig.loadFile('test/fixtures/comstar.valid.yaml');
  if (strangerMode == base.attention.strangerMode) return base;

  return ComstarConfig.loadMap(
    {
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
        'stranger_mode': strangerMode,
      },
      'directory': {
        'enabled': base.directory.enabled,
        'sidecar_url': base.directory.sidecarUrl,
        'require': base.directory.require,
        'cache_ttl_seconds': base.directory.cacheTtlSeconds,
        'timeout_ms': base.directory.timeoutMs,
      },
      'dev': {
        'bind_lan': base.dev.bindLan,
        'lan_token': base.dev.lanToken,
      },
    },
    sourcePath: 'test/fixtures/comstar.valid.yaml',
  );
}

AttentionMachine _machine({
  FakeClock? clock,
  ComstarConfig? config,
  bool faceAttentionTrigger = false,
  String strangerMode = 'restricted',
}) {
  final c = config ?? _loadConfig(strangerMode: strangerMode);
  final clk = clock ?? FakeClock();
  final cfg = faceAttentionTrigger
      ? ComstarConfig.loadMap(
          {
            'orchestration': {
              'base_url': c.orchestration.baseUrl,
              'token': c.orchestration.token,
              'ttl_seconds': c.orchestration.ttlSeconds,
              'timeout_seconds': c.orchestration.timeoutSeconds,
              'overlay_root': c.orchestration.overlayRoot,
            },
            'vision': {
              'codeproject_url': c.vision.codeprojectUrl,
              'detection_endpoint': c.vision.detectionEndpoint,
              'recognize_endpoint': c.vision.recognizeEndpoint,
              'ambient_fps': c.vision.ambientFps,
              'engaged_fps': c.vision.engagedFps,
              'person_confidence': c.vision.personConfidence,
              'face_confidence': c.vision.faceConfidence,
              'recognize_votes': c.vision.recognizeVotes,
              'identity_ttl_seconds': c.vision.identityTtlSeconds,
            },
            'audio': {
              'wakeword_model': c.audio.wakewordModel,
              'wakeword_threshold': c.audio.wakewordThreshold,
              'vad_silence_ms': c.audio.vadSilenceMs,
              'max_utterance_seconds': c.audio.maxUtteranceSeconds,
              'followup_window_seconds': c.audio.followupWindowSeconds,
              'duplex': c.audio.duplex,
            },
            'avatar': {
              'render': c.avatar.render,
              'model': c.avatar.model,
              'tts': c.avatar.tts,
              'piper_voice': c.avatar.piperVoice,
            },
            'attention': {
              'face_attention_trigger': true,
              'stranger_mode': strangerMode,
            },
            'directory': {
              'enabled': c.directory.enabled,
              'sidecar_url': c.directory.sidecarUrl,
              'require': c.directory.require,
              'cache_ttl_seconds': c.directory.cacheTtlSeconds,
              'timeout_ms': c.directory.timeoutMs,
            },
            'dev': {
              'bind_lan': c.dev.bindLan,
              'lan_token': c.dev.lanToken,
            },
          },
          sourcePath: 'test/fixtures/comstar.valid.yaml',
        )
      : c;

  return AttentionMachine(config: cfg, clock: clk);
}

void _apply(AttentionMachine machine, AttentionEvent event) {
  final t = machine.handle(event);
  assertInvariants(t.context);
}

void _engageAndListen(AttentionMachine machine) {
  _apply(machine, const PersonDetected(0.8));
  _apply(machine, const FaceRecognized('zlatko', 0.9));
  // Greeter finished — unlock mic before a spoken turn.
  _apply(machine, const PlaybackEnded());
  _apply(machine, const WakeWord(0.9));
}

bool _hasEffectType<T extends Effect>(List<Effect> effects) =>
    effects.any((e) => e is T);

void main() {
  group('CONTRACTS §8 transition table', () {
    test('ambient + PersonDetected → noticed', () {
      final m = _machine();
      final t = m.handle(const PersonDetected(0.8));
      expect(t.to, isA<Noticed>());
      expect(_hasEffectType<SetVisionFps>(t.effects), isTrue);
      assertInvariants(t.context);
    });

    test('ambient + WakeWord stays ambient (face-first)', () {
      final m = _machine();
      final t = m.handle(const WakeWord(0.9));
      expect(t.to, isA<Ambient>());
      expect(_hasEffectType<StartListening>(t.effects), isFalse);
      expect(m.context.sessionOpen, isFalse);
    });

    test('noticed + WakeWord stays noticed (face-first)', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.8));
      final t = m.handle(const WakeWord(0.9));
      expect(t.to, isA<Noticed>());
      expect(_hasEffectType<StartListening>(t.effects), isFalse);
    });

    test('engaged + PlaybackEnded opens follow-up', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.8));
      _apply(m, const FaceRecognized('zlatko', 0.9));
      final t = m.handle(const PlaybackEnded());
      expect(t.to, isA<Engaged>());
      expect(m.context.followUpOpen, isTrue);
      expect(_hasEffectType<OpenFollowUpWindow>(t.effects), isTrue);
      expect(_hasEffectType<EnableWake>(t.effects), isTrue);
    });
    test('noticed + FaceRecognized → engaged', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.8));
      final t = m.handle(const FaceRecognized('zlatko', 0.9, displayName: 'Zlatko'));
      expect(t.to, isA<Engaged>());
      expect(_hasEffectType<OpenSession>(t.effects), isTrue);
      expect(_hasEffectType<RunGreeter>(t.effects), isTrue);
      expect(m.context.cachedUserid, 'zlatko');
      expect(m.context.cachedDisplayName, 'Zlatko');
    });

    test('engaged + SpeechStart → listening (face-addressable)', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.8));
      _apply(m, const FaceRecognized('zlatko', 0.9));
      _apply(m, const PlaybackEnded());
      final t = m.handle(const SpeechStart());
      expect(t.to, isA<Listening>());
      // Mic already armed by follow-up window → promote, else start fresh.
      expect(
        _hasEffectType<StartListening>(t.effects) ||
            _hasEffectType<PromoteListening>(t.effects),
        isTrue,
      );
    });

    test('engaged + SpeechStart during follow-up → listening', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.8));
      _apply(m, const FaceRecognized('zlatko', 0.9));
      _apply(m, const PlaybackEnded());
      m.context.followUpOpen = true;
      m.context.followUpListening = true;
      m.context.followUpMicArmedAtMs = m.context.clock.nowMs - 2500;
      final t = m.handle(const SpeechStart());
      expect(t.to, isA<Listening>());
      expect(_hasEffectType<PromoteListening>(t.effects), isTrue);
    });

    test('noticed + FaceUnknown + greet → engaged guest', () {
      final m = _machine(strangerMode: 'greet');
      _apply(m, const PersonDetected(0.8));
      final t = m.handle(const FaceUnknown());
      expect(t.to, isA<Engaged>());
      expect(
        t.effects.whereType<OpenSession>().single.guest,
        isTrue,
      );
    });

    test('noticed + FaceUnknown + restricted → noticed', () {
      final m = _machine(strangerMode: 'restricted');
      _apply(m, const PersonDetected(0.8));
      final t = m.handle(const FaceUnknown());
      expect(t.to, isA<Noticed>());
      expect(m.context.sessionOpen, isFalse);
    });

    test('noticed + PersonAbsent x3 → ambient', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.8));
      _apply(m, const PersonAbsent());
      _apply(m, const PersonAbsent());
      final t = m.handle(const PersonAbsent());
      expect(t.to, isA<Ambient>());
      expect(_hasEffectType<SetVisionFps>(t.effects), isTrue);
    });

    test('engaged + WakeWord → listening', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.8));
      _apply(m, const FaceRecognized('zlatko', 0.9));
      _apply(m, const PlaybackEnded());
      // Clear follow-up arm so WakeWord takes the fresh-listen path.
      m.context.followUpListening = false;
      final t = m.handle(const WakeWord(0.9));
      expect(t.to, isA<Listening>());
      expect(_hasEffectType<StartListening>(t.effects), isTrue);
      expect(m.context.wakeEnabled, isFalse);
    });

    test('engaged + SpeechStart + gaze → listening', () {
      final m = _machine(faceAttentionTrigger: true);
      _apply(m, const PersonDetected(0.8));
      _apply(m, const FaceRecognized('zlatko', 0.9));
      _apply(m, const PlaybackEnded());
      m.context.gazeDetected = true;
      m.context.followUpListening = false;
      final t = m.handle(const SpeechStart());
      expect(t.to, isA<Listening>());
      expect(_hasEffectType<StartListening>(t.effects), isTrue);
    });

    test('engaged + Tick identity expired and absent → ambient', () {
      final clock = FakeClock();
      final m = _machine(clock: clock);
      _apply(m, const PersonDetected(0.8));
      _apply(m, const FaceRecognized('zlatko', 0.9));
      clock.advance(301 * 1000);
      m.context.personPresent = false;
      final t = m.handle(const Tick());
      expect(t.to, isA<Ambient>());
      expect(_hasEffectType<CloseSession>(t.effects), isTrue);
    });

    test('listening + SpeechEnd stays listening and calls STT', () {
      final m = _machine();
      _engageAndListen(m);
      final t = m.handle(const SpeechEnd(1200));
      expect(t.to, isA<Listening>());
      expect(_hasEffectType<FinalizeCapture>(t.effects), isTrue);
      expect(_hasEffectType<CallStt>(t.effects), isTrue);
    });

    test('listening + Tick max utterance → stays listening pending STT', () {
      final clock = FakeClock();
      final m = _machine(clock: clock);
      _engageAndListen(m);
      clock.advance(16 * 1000);
      final t = m.handle(const Tick());
      expect(t.to, isA<Listening>());
      expect(_hasEffectType<FinalizeCapture>(t.effects), isTrue);
      expect(_hasEffectType<CallStt>(t.effects), isTrue);
    });

    test('listening + TranscriptReady non-empty → responding', () {
      final m = _machine();
      _engageAndListen(m);
      _apply(m, const SpeechEnd(500));
      final t = m.handle(const TranscriptReady('hello'));
      expect(t.to, isA<Responding>());
      expect(_hasEffectType<SetThinking>(t.effects), isTrue);
      expect(_hasEffectType<CallDirectAgent>(t.effects), isTrue);
      expect(_hasEffectType<StopListening>(t.effects), isTrue);
      expect(_hasEffectType<EnableWake>(t.effects), isTrue);
      final wake = t.effects.whereType<EnableWake>().single;
      expect(wake.enabled, isTrue);
    });

    test('engaged + duplicate PlaybackEnded does not re-open follow-up', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.9));
      _apply(m, const FaceRecognized('zlatko', 0.95));
      _apply(m, const PlaybackEnded());
      expect(m.context.followUpOpen, isTrue);
      final t = m.handle(const PlaybackEnded());
      expect(_hasEffectType<OpenFollowUpWindow>(t.effects), isFalse);
    });

    test('listening + TranscriptReady empty → engaged', () {
      final m = _machine();
      _engageAndListen(m);
      _apply(m, const SpeechEnd(500));
      final t = m.handle(const TranscriptReady('  '));
      expect(t.to, isA<Engaged>());
      expect(_hasEffectType<OpenFollowUpWindow>(t.effects), isTrue);
      expect(_hasEffectType<PlayErrorTone>(t.effects), isFalse);
      expect(_hasEffectType<StopListening>(t.effects), isTrue);
      expect(m.context.turnId, isNull);
    });

    test('responding + ResponseReady speaks', () {
      final m = _machine();
      _engageAndListen(m);
      _apply(m, const SpeechEnd(500));
      _apply(m, const TranscriptReady('hello'));
      final t = m.handle(
        const ResponseReady('hi there', 'http://127.0.0.1/audio.wav'),
      );
      expect(t.to, isA<Responding>());
      expect(_hasEffectType<Speak>(t.effects), isTrue);
    });

    test('responding + PlaybackEnded → engaged', () {
      final m = _machine();
      _engageAndListen(m);
      _apply(m, const SpeechEnd(500));
      _apply(m, const TranscriptReady('hello'));
      _apply(m, const ResponseReady('hi', 'http://127.0.0.1/a.wav'));
      final t = m.handle(const PlaybackEnded());
      expect(t.to, isA<Engaged>());
      expect(_hasEffectType<OpenFollowUpWindow>(t.effects), isTrue);
      expect(m.context.wakeEnabled, isTrue);
      expect(m.context.turnId, isNull);
    });

    test('responding + Tick orchestration timeout → engaged', () {
      final clock = FakeClock();
      final m = _machine(clock: clock);
      _engageAndListen(m);
      _apply(m, const SpeechEnd(500));
      _apply(m, const TranscriptReady('hello'));
      // Floor is 90s so HA tool turns are not cut off by the 15s chat timeout.
      clock.advance(91 * 1000);
      final t = m.handle(const Tick());
      expect(t.to, isA<Engaged>());
      expect(_hasEffectType<SpeakFallback>(t.effects), isTrue);
      expect(m.context.turnId, isNull);
    });

    test('any + fatal Error → ambient', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.8));
      _apply(m, const FaceRecognized('zlatko', 0.9));
      final t = m.handle(const AttentionError('test', fatal: true));
      expect(t.to, isA<Ambient>());
      expect(_hasEffectType<CloseSession>(t.effects), isTrue);
    });
  });

  group('golden scenarios', () {
    test('happy path walk-up greet and question', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.85));
      expect(m.state, isA<Noticed>());
      _apply(m, const FaceRecognized('zlatko', 0.92));
      expect(m.state, isA<Engaged>());
      _apply(m, const PlaybackEnded());
      m.context.followUpListening = false;
      _apply(m, const WakeWord(0.88));
      expect(m.state, isA<Listening>());
      _apply(m, const SpeechEnd(800));
      _apply(m, const TranscriptReady('what time is it'));
      expect(m.state, isA<Responding>());
      _apply(m, const ResponseReady('It is noon', 'http://127.0.0.1/a.wav'));
      _apply(m, const PlaybackEnded());
      expect(m.state, isA<Engaged>());
    });

    test('stranger restricted stays noticed', () {
      final m = _machine(strangerMode: 'restricted');
      _apply(m, const PersonDetected(0.85));
      _apply(m, const FaceUnknown());
      expect(m.state, isA<Noticed>());
      expect(m.context.sessionOpen, isFalse);
    });

    test('wake word from empty room is ignored until face engage', () {
      final m = _machine();
      _apply(m, const WakeWord(0.9));
      expect(m.state, isA<Ambient>());
      expect(m.context.sessionOpen, isFalse);
    });

    test('vision degraded lowers fps', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.85));
      final t = m.handle(const VisionDegraded());
      expect(_hasEffectType<SetVisionFps>(t.effects), isTrue);
      expect(
        t.effects.whereType<SetVisionFps>().single.fps,
        m.context.config.vision.ambientFps,
      );
    });

    test('EnterSleep from engaged keeps session; wake off while greeter playing', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.85));
      _apply(m, const FaceRecognized('zlatko', 0.9));
      expect(m.state, isA<Engaged>());
      expect(m.context.sessionOpen, isTrue);
      expect(m.context.playing, isTrue); // greeter pending

      final t = m.handle(const EnterSleep());
      expect(m.state, isA<Sleeping>());
      expect(m.context.sessionOpen, isTrue);
      // Still "playing" — do not arm wake (HDMI echo would false-trigger).
      expect(m.context.playing, isTrue);
      expect(m.context.wakeEnabled, isFalse);
      expect(_hasEffectType<EnteredSleep>(t.effects), isTrue);
      expect(_hasEffectType<EnableWake>(t.effects), isTrue);
      final wake = t.effects.whereType<EnableWake>().single;
      expect(wake.enabled, isFalse);
      assertInvariants(m.context);
    });

    test('EnterSleep when idle arms wake', () {
      final m = _machine();
      _apply(m, const EnterSleep());
      expect(m.state, isA<Sleeping>());
      expect(m.context.playing, isFalse);
      expect(m.context.wakeEnabled, isTrue);
    });

    test('Sleeping ignores face and VAD', () {
      final m = _machine();
      _apply(m, const EnterSleep());
      _apply(m, const PersonDetected(0.99));
      _apply(m, const FaceRecognized('zlatko', 0.99));
      _apply(m, const SpeechStart());
      _apply(m, const SpeechEnd(500));
      expect(m.state, isA<Sleeping>());
      expect(m.context.sessionOpen, isFalse);
    });

    test('WakeWord exits sleep to Engaged and opens follow-up Listening', () {
      final m = _machine();
      _apply(m, const PersonDetected(0.85));
      _apply(m, const FaceRecognized('zlatko', 0.9));
      _apply(m, const EnterSleep());
      expect(m.state, isA<Sleeping>());

      final t = m.handle(const WakeWord(0.9));
      expect(m.state, isA<Engaged>());
      expect(m.context.sessionOpen, isTrue);
      expect(m.context.wakeEnabled, isTrue);
      expect(_hasEffectType<ExitedSleep>(t.effects), isTrue);
      expect(_hasEffectType<OpenFollowUpWindow>(t.effects), isTrue);
      final followUp = t.effects.whereType<OpenFollowUpWindow>().single;
      expect(followUp.settleMs, 0);
      expect(_hasEffectType<StartListening>(t.effects), isFalse);
      expect(_hasEffectType<EnableWake>(t.effects), isTrue);
      assertInvariants(m.context);
    });

    test('PlaybackEnded while sleeping re-arms wake', () {
      final m = _machine();
      _apply(m, const EnterSleep());
      m.context.playing = true;
      m.context.wakeEnabled = false;
      final t = m.handle(const PlaybackEnded());
      expect(m.state, isA<Sleeping>());
      expect(m.context.playing, isFalse);
      expect(m.context.wakeEnabled, isTrue);
      expect(_hasEffectType<EnableWake>(t.effects), isTrue);
    });

    test('ResponseReady while sleeping speaks sleep ack without leaving sleep', () {
      final m = _machine();
      _apply(m, const EnterSleep());
      final t = m.handle(
        const ResponseReady('Okay, going to sleep.', 'http://127.0.0.1/a.wav'),
      );
      expect(m.state, isA<Sleeping>());
      expect(m.context.playing, isTrue);
      expect(_hasEffectType<Speak>(t.effects), isTrue);
      expect(_hasEffectType<ExitedSleep>(t.effects), isFalse);
    });
  });
}
