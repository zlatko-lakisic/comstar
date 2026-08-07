import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/effects.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:comstar_bridge/attention/machine.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:comstar_bridge/config.dart';
import 'package:test/test.dart';

ComstarConfig _cfg() => ComstarConfig.loadMap(
      {
        'orchestration': {
          'base_url': 'http://10.0.10.16:8765',
          'token': '',
          'ttl_seconds': 3600,
          'timeout_seconds': 15,
          'overlay_root': './overlays/comstar',
        },
        'vision': {
          'codeproject_url': 'http://10.0.10.16:32168',
          'detection_endpoint': '/v1/vision/detection',
          'recognize_endpoint': '/v1/vision/face/recognize',
          'ambient_fps': 1,
          'engaged_fps': 3,
          'person_confidence': 0.6,
          'face_confidence': 0.4,
          'recognize_votes': 2,
          'identity_ttl_seconds': 600,
        },
        'audio': {
          'wakeword_model': './models/hey_comstar.onnx',
          'wakeword_threshold': 0.55,
          'vad_silence_ms': 700,
          'max_utterance_seconds': 15,
          'followup_window_seconds': 25,
          'duplex': 'half',
        },
        'avatar': {
          'render': 'local',
          'model': './assets/comstar.glb',
          'tts': 'piper',
          'piper_voice': 'en_US-ryan-high',
        },
        'attention': {
          'face_attention_trigger': true,
          'stranger_mode': 'greet',
        },
        'directory': {
          'enabled': false,
          'sidecar_url': '',
          'require': false,
          'cache_ttl_seconds': 300,
          'timeout_ms': 500,
        },
        'dev': {'bind_lan': false, 'lan_token': ''},
      },
      sourcePath: 'test://announce_machine',
    );

void main() {
  test('AnnouncementReady from engaged speaks once (invariants 9–10)', () {
    final clock = FakeClock(1000000);
    final machine = AttentionMachine(config: _cfg(), clock: clock);
    machine.handle(const PersonDetected(0.9));
    machine.handle(const FaceRecognized('zlatko', 0.9));
    // Greeter sets playing=true; clear for announce delivery.
    machine.context.playing = false;
    expect(machine.state, isA<Engaged>());
    expect(machine.context.announcedThisEngage, isFalse);

    final t1 = machine.handle(const AnnouncementReady(
      id: 'a1',
      text: 'Your 2pm moved to 3.',
    ));
    expect(machine.state, isA<Responding>());
    expect(machine.context.announcedThisEngage, isTrue);
    expect(t1.effects.whereType<Speak>(), isNotEmpty);

    machine.handle(const PlaybackEnded());
    expect(machine.state, isA<Engaged>());

    final t2 = machine.handle(const AnnouncementReady(
      id: 'a2',
      text: 'Second should hold.',
    ));
    expect(machine.state, isA<Engaged>());
    expect(t2.effects.whereType<Speak>(), isEmpty);
  });

  test('AnnouncementReady ignored in noticed', () {
    final clock = FakeClock(1000000);
    final machine = AttentionMachine(config: _cfg(), clock: clock);
    machine.handle(const PersonDetected(0.9));
    expect(machine.state, isA<Noticed>());
    final t = machine.handle(const AnnouncementReady(id: 'x', text: 'nope'));
    expect(machine.state, isA<Noticed>());
    expect(t.effects.whereType<Speak>(), isEmpty);
  });
}
