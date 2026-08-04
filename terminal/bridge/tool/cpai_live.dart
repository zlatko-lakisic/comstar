import 'dart:io';

import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/vision/cpai_client.dart';

Future<void> main(List<String> args) async {
  final url =
      Platform.environment['COMSTAR_CPAI_URL'] ?? 'http://10.0.10.16:32168';
  final imgPath = args.isNotEmpty
      ? args.first
      : (Platform.environment['COMSTAR_IMAGE'] ??
          '../../docs/fixtures/_probe_frame.jpg');

  final cfg = ComstarConfig.loadMap(
    {
      'orchestration': {
        'base_url': 'http://10.0.10.16:8765',
        'token': '',
        'ttl_seconds': 3600,
        'timeout_seconds': 15,
        'overlay_root': './overlays/comstar',
      },
      'vision': {
        'codeproject_url': url,
        'detection_endpoint': '/v1/vision/detection',
        'recognize_endpoint': '/v1/vision/face/recognize',
        'ambient_fps': 1,
        'engaged_fps': 3,
        'person_confidence': 0.5,
        'face_confidence': 0.4,
        'recognize_votes': 1,
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
      'dev': {'bind_lan': false, 'lan_token': ''},
    },
    sourcePath: 'live',
  );

  final client = CpaiClient(config: cfg.vision);
  final bytes = await File(imgPath).readAsBytes();

  final sw = Stopwatch()..start();
  final persons = await client.detectPerson(bytes);
  final detectMs = sw.elapsedMilliseconds;
  sw.reset();
  final faces = await client.recognizeFace(bytes);
  final recogMs = sw.elapsedMilliseconds;

  stdout.writeln('CPAI=$url image=$imgPath');
  stdout.writeln(
    'detect ${detectMs}ms => $persons degraded=${client.isDegraded}',
  );
  stdout.writeln('recognize ${recogMs}ms => $faces');

  final hasPerson = persons.any((p) => p.label == 'person');
  if (!hasPerson) {
    stderr.writeln('FAIL: expected person in frame');
    exitCode = 1;
  } else if (client.isDegraded) {
    stderr.writeln('FAIL: vision degraded');
    exitCode = 1;
  } else {
    stdout.writeln('DART_CPAI_PASS');
  }
  client.dispose();
}
