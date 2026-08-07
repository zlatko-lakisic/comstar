import 'dart:io';

import 'package:comstar_bridge/announce/channel_client.dart';
import 'package:comstar_bridge/announce/service.dart';
import 'package:comstar_bridge/announce/types.dart';
import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/machine.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:comstar_bridge/config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ComstarConfig _cfg(String queuePath, {String channelUrl = 'http://channel.test'}) {
  return ComstarConfig.loadMap(
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
      'announce': {
        'enabled': true,
        'queue_path': queuePath,
        'channel_url': channelUrl,
        'channel_token': 't',
      },
    },
    sourcePath: 'test://announce_channel',
  );
}

void main() {
  test('channel surface delivers urgent when ambient and claims once', () async {
    final dir = await Directory.systemTemp.createTemp('ann-ch-');
    final db = p.join(dir.path, 'q.db');
    final cfg = _cfg(db);
    final machine = AttentionMachine(config: cfg, clock: FakeClock(1000000));
    expect(machine.state, isA<Ambient>());

    var posts = 0;
    final client = ChannelAnnounceClient(
      baseUrl: 'http://channel.test',
      token: 't',
      httpClient: MockClient((req) async {
        posts++;
        expect(req.url.path, '/v1/announce');
        return http.Response(
          '{"ok":true,"delivered":true,"sender_id":"1"}',
          200,
        );
      }),
    );

    final svc = AnnounceService(
      config: cfg,
      machine: machine,
      onEvent: (_) {},
      channelClient: client,
    );
    // Do not call start() — avoids schedule/HA timers.
    svc.queue.open();
    svc.enqueue(
      recipient: 'zlatko',
      intent: 'Pipe burst',
      priority: AnnouncementPriority.urgent,
      text: 'Pipe burst in the basement',
    );

    final n = await svc.evaluateChannelSurface();
    expect(n, 1);
    expect(posts, 1);
    expect(svc.queue.list(status: AnnouncementStatus.delivered), hasLength(1));

    final n2 = await svc.evaluateChannelSurface();
    expect(n2, 0);
    expect(posts, 1);

    svc.queue.close();
    client.close();
    await dir.delete(recursive: true);
  });

  test('failed channel deliver reopens pending', () async {
    final dir = await Directory.systemTemp.createTemp('ann-ch2-');
    final db = p.join(dir.path, 'q.db');
    final cfg = _cfg(db);
    final machine = AttentionMachine(config: cfg, clock: FakeClock(1000000));

    final client = ChannelAnnounceClient(
      baseUrl: 'http://channel.test',
      token: 't',
      httpClient: MockClient((req) async {
        return http.Response(
          '{"ok":true,"delivered":false,"reason":"skip"}',
          200,
        );
      }),
    );
    final svc = AnnounceService(
      config: cfg,
      machine: machine,
      onEvent: (_) {},
      channelClient: client,
    );
    svc.queue.open();
    svc.enqueue(
      recipient: 'zlatko',
      intent: 'x',
      priority: AnnouncementPriority.urgent,
      text: 'x',
    );
    final n = await svc.evaluateChannelSurface();
    expect(n, 0);
    expect(svc.queue.list(status: AnnouncementStatus.pending), hasLength(1));
    svc.queue.close();
    client.close();
    await dir.delete(recursive: true);
  });

  test('normal priority does not post to channel', () async {
    final dir = await Directory.systemTemp.createTemp('ann-ch3-');
    final db = p.join(dir.path, 'q.db');
    final cfg = _cfg(db);
    final machine = AttentionMachine(config: cfg, clock: FakeClock(1000000));
    var posts = 0;
    final client = ChannelAnnounceClient(
      baseUrl: 'http://channel.test',
      token: 't',
      httpClient: MockClient((req) async {
        posts++;
        return http.Response('{"ok":true,"delivered":true}', 200);
      }),
    );
    final svc = AnnounceService(
      config: cfg,
      machine: machine,
      onEvent: (_) {},
      channelClient: client,
    );
    svc.queue.open();
    svc.enqueue(
      recipient: 'zlatko',
      intent: 'remind me',
      priority: AnnouncementPriority.normal,
      text: 'remind me',
    );
    expect(await svc.evaluateChannelSurface(), 0);
    expect(posts, 0);
    expect(svc.queue.list(status: AnnouncementStatus.pending), hasLength(1));
    svc.queue.close();
    client.close();
    await dir.delete(recursive: true);
  });
}
