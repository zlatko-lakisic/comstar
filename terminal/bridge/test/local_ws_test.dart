import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/envelope.dart';
import 'package:comstar_bridge/local_ws.dart';
import 'package:test/test.dart';

void main() {
  group('Envelope', () {
    test('roundtrip encode/decode', () {
      final original = Envelope.create(
        type: 'ready',
        turnId: 't_test',
        data: {'avatarLoaded': false, 'fps': 30},
        id: 'msg_fixed',
        ts: 1754160000000,
      );

      final decoded = Envelope.decode(original.encode());
      expect(decoded, isNotNull);
      expect(decoded!.v, envelopeVersion);
      expect(decoded.id, 'msg_fixed');
      expect(decoded.type, 'ready');
      expect(decoded.ts, 1754160000000);
      expect(decoded.turnId, 't_test');
      expect(decoded.data['avatarLoaded'], isFalse);
      expect(decoded.data['fps'], 30);
    });

    test('malformed JSON returns null', () {
      expect(Envelope.decode('{not json'), isNull);
      expect(Envelope.decode('{"type":""}'), isNull);
    });
  });

  group('LocalWs message handling', () {
    late ComstarConfig config;

    setUp(() {
      config = ComstarConfig.loadMap(
        {
          'orchestration': {
            'base_url': 'http://127.0.0.1:8765',
            'token': '',
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
          'dev': {
            'bind_lan': false,
            'lan_token': '',
          },
        },
        sourcePath: 'comstar.valid.yaml',
      );
    });

    test('unknown type is dropped not thrown', () {
      final ws = LocalWs(config: config);
      final envelope = Envelope.create(type: 'not.a.real.type');
      expect(ws.handleInbound('kiosk', envelope), isFalse);

      final known = Envelope.create(type: 'ready', data: {'avatarLoaded': false});
      expect(ws.handleInbound('kiosk', known), isTrue);
    });
  });
}
