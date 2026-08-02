import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/coordinator.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/http_audio_server.dart';
import 'package:comstar_bridge/local_ws.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/session.dart';
import 'package:comstar_bridge/stt.dart';
import 'package:comstar_bridge/tts.dart';
import 'package:comstar_bridge/vision/camera.dart';
import 'package:comstar_bridge/vision/cpai_client.dart';
import 'package:comstar_bridge/vision/identity.dart';
import 'package:comstar_bridge/vision/vision_poller.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show usage')
    ..addFlag(
      'vision-once',
      negatable: false,
      help: 'Run one CPAI detection if COMSTAR_CPAI_URL is set',
    )
    ..addOption(
      'config',
      abbr: 'c',
      help: 'Path to comstar.yaml',
    );

  late final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(2);
  }

  if (results['help'] as bool) {
    stdout.writeln('COMSTAR bridge\n');
    stdout.writeln(parser.usage);
    exit(0);
  }

  if (results['vision-once'] as bool) {
    await _runVisionOnce();
    exit(0);
  }

  late final String configPath;
  configPath = results['config'] as String? ??
      Platform.environment['COMSTAR_CONFIG'] ??
      'config/comstar.yaml';

  late final ComstarConfig config;
  try {
    config = ComstarConfig.loadFile(configPath);
  } on ConfigError catch (e) {
    logError('config_error', e.message);
    exit(1);
  }

  final session = ComstarSession(config: config);
  final stt = HttpSttClient();
  final tts = createTtsEngine(
    engine: config.avatar.tts,
    piperVoice: config.avatar.piperVoice,
  );
  final audioServer = HttpAudioServer();

  AttentionCoordinator? coordinator;
  VisionPoller? visionPoller;

  final ws = LocalWs(
    config: config,
    onMessage: (role, envelope, channel) {
      coordinator?.handleWsMessage(role, envelope);
      if (role == 'audio') {
        coordinator?.attachAudioChannel(channel);
      }
    },
    onBinary: (role, data, channel) {
      if (role == 'audio') {
        coordinator?.handleBinaryAudio(Uint8List.fromList(data));
      }
    },
  );
  await ws.start();

  coordinator = AttentionCoordinator(
    config: config,
    ws: ws,
    session: session,
    stt: stt,
    tts: tts,
    audioServer: audioServer,
  );

  final visionEnabled = Platform.environment['COMSTAR_VISION'] == '1';
  if (visionEnabled) {
    final cameraInput = Platform.environment['COMSTAR_CAMERA_INPUT'];
    final camera = cameraInput != null && cameraInput.isNotEmpty
        ? FfmpegCamera(input: cameraInput)
        : StubCamera();
    final cpaiClient = CpaiClient(config: config.vision);
    final identity = IdentityResolver(
      config: config.vision,
      clock: SystemClock(),
    );
    visionPoller = VisionPoller(
      camera: camera,
      client: cpaiClient,
      identity: identity,
      config: config.vision,
      clock: SystemClock(),
    );
    logInfo('vision_enabled', 'Vision poller starting', data: {
      'camera': cameraInput ?? 'stub',
    });
  }

  await coordinator.start(visionPoller: visionPoller);

  logInfo('bridge_started', 'COMSTAR bridge running', data: {
    'config': configPath,
    'dev_lan': config.devLanBindingEnabled,
    'vision': visionEnabled,
  });

  final completer = Completer<void>();
  var stopping = false;

  Future<void> shutdown() async {
    if (stopping) return;
    stopping = true;
    logInfo('shutdown', 'SIGTERM received, draining');
    await coordinator?.stop();
    stt.dispose();
    await visionPoller?.dispose();
    await ws.stop();
    if (!completer.isCompleted) completer.complete();
  }

  ProcessSignal.sigterm.watch().listen((_) => unawaited(shutdown()));
  ProcessSignal.sigint.watch().listen((_) => unawaited(shutdown()));

  await completer.future;
  exit(0);
}

Future<void> _runVisionOnce() async {
  final cpaiUrl = Platform.environment['COMSTAR_CPAI_URL'];
  if (cpaiUrl == null || cpaiUrl.isEmpty) {
    stderr.writeln('COMSTAR_CPAI_URL not set; skipping vision-once');
    exit(0);
  }

  final configPath = Platform.environment['COMSTAR_CONFIG'] ??
      'config/comstar.yaml';
  ComstarConfig config;
  try {
    config = ComstarConfig.loadFile(configPath);
  } catch (_) {
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
          'codeproject_url': cpaiUrl,
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
      sourcePath: 'vision-once.yaml',
    );
  }

  final vision = VisionConfig(
    codeprojectUrl: cpaiUrl,
    detectionEndpoint: config.vision.detectionEndpoint,
    recognizeEndpoint: config.vision.recognizeEndpoint,
    ambientFps: config.vision.ambientFps,
    engagedFps: config.vision.engagedFps,
    personConfidence: config.vision.personConfidence,
    faceConfidence: config.vision.faceConfidence,
    recognizeVotes: config.vision.recognizeVotes,
    identityTtlSeconds: config.vision.identityTtlSeconds,
  );

  final client = CpaiClient(config: vision);
  try {
    final input = Platform.environment['COMSTAR_CAMERA_INPUT'];
    Uint8List frame;
    if (input != null && input.isNotEmpty) {
      final camera = FfmpegCamera(input: input);
      frame = await camera.frames(targetFps: 1).first;
      await camera.dispose();
    } else {
      frame = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
    }

    final detections = await client.detectPerson(frame);
    logInfo('vision_once', 'Detection complete', data: {
      'person_count': detections.where((d) => d.isPerson).length,
      'predictions': detections
          .map((d) => {
                'label': d.label,
                'confidence': d.confidence,
              })
          .toList(),
    });

    if (detections.any((d) => d.isPerson)) {
      final faces = await client.recognizeFace(frame);
      logInfo('vision_once', 'Recognition complete', data: {
        'faces': faces
            .map((f) => {
                  'userid': f.userid,
                  'confidence': f.confidence,
                })
            .toList(),
      });
    }
  } finally {
    client.dispose();
  }
}
