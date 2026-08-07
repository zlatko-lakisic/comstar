import 'dart:io';

import 'package:comstar_bridge/ao_mtls/service.dart';
import 'package:comstar_bridge/config.dart';
import 'package:test/test.dart';

ComstarConfig _cfg({String? materialDir, bool enabled = false}) =>
    ComstarConfig.loadMap(
      {
        'orchestration': {
          'base_url': enabled
              ? 'https://10.0.10.16:8765'
              : 'http://10.0.10.16:8765',
          'token': '',
          'ttl_seconds': 3600,
          'timeout_seconds': 15,
          'overlay_root': './overlays/comstar',
          'mtls': {
            'enabled': enabled,
            if (materialDir != null) 'material_dir': materialDir,
            'client_name': 'test-client',
          },
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
        'dev': {'bind_lan': false, 'lan_token': ''},
      },
      sourcePath: 'ao-mtls-test.yaml',
    );

void main() {
  group('AoMtlsService', () {
    test('inspect reports unpaired when PEMs missing', () async {
      final dir = Directory.systemTemp.createTempSync('ao-mtls-insp-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on Object {}
      });
      final svc = AoMtlsService(config: _cfg(materialDir: dir.path, enabled: true));
      final status = await svc.inspect();
      expect(status['ok'], isTrue);
      expect(status['paired'], isFalse);
      expect(status['enabled'], isTrue);
      expect(status['material_dir'], dir.path);
    });

    test('clear removes PEMs and meta', () async {
      final dir = Directory.systemTemp.createTempSync('ao-mtls-clr-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on Object {}
      });
      File('${dir.path}/cert.pem').writeAsStringSync('c');
      File('${dir.path}/key.pem').writeAsStringSync('k');
      File('${dir.path}/ca.pem').writeAsStringSync('a');
      File('${dir.path}/meta.json').writeAsStringSync('{"client_name":"x"}');
      final svc = AoMtlsService(config: _cfg(materialDir: dir.path));
      final r = await svc.clear();
      expect(r['ok'], isTrue);
      expect(r['paired'], isFalse);
      expect(File('${dir.path}/cert.pem').existsSync(), isFalse);
    });
  });
}
