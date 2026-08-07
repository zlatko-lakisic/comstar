import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/coordinator.dart';
import 'package:comstar_bridge/avatar_load_governor.dart';
import 'package:comstar_bridge/admin_server.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/envelope.dart';
import 'package:comstar_bridge/env_sources.dart';
import 'package:comstar_bridge/host_metrics.dart';
import 'package:comstar_bridge/http_audio_server.dart';
import 'package:comstar_bridge/local_ws.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/session.dart';
import 'package:comstar_bridge/road/service.dart';
import 'package:comstar_bridge/speech_routing.dart';
import 'package:comstar_bridge/stt.dart';
import 'package:comstar_bridge/systemd_watchdog.dart';
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
  final stt = PreferReachSttClient(
    speechClientOf: () => session.speechClient,
    fallback: HttpSttClient(),
  );
  final tts = PreferReachTts(
    speechClientOf: () => session.speechClient,
    fallback: createTtsEngine(
      engine: config.avatar.tts,
      piperVoice: config.avatar.piperVoice,
    ),
  );
  final repoRoot = File(configPath).absolute.parent.parent.path;
  final kioskDir = Directory('$repoRoot/terminal/kiosk');
  final audioServer = HttpAudioServer(
    kioskRoot: kioskDir.existsSync() ? kioskDir.path : null,
  );

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

  final watchdog = SystemdWatchdog();
  // Notify early so Type=notify does not race AO/session bring-up (M9.3).
  await watchdog.ready();
  watchdog.startWatchdog();

  final fallbackDir = Directory('$repoRoot/assets/fallback');
  coordinator = AttentionCoordinator(
    config: config,
    ws: ws,
    session: session,
    stt: stt,
    tts: tts,
    audioServer: audioServer,
    fallbackAudioDir: fallbackDir.existsSync() ? fallbackDir.path : null,
  );

  final visionEnabled = Platform.environment['COMSTAR_VISION'] == '1';
  if (visionEnabled) {
    final cameraInput = cameraSource();
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

  final road = RoadService(
    yamlConfig: config.road,
    defaultHealthUrl:
        '${config.orchestration.baseUrl.replaceAll(RegExp(r'/+$'), '')}/health',
  );
  await road.start();

  final adminDir = Directory('$repoRoot/terminal/admin');
  final hostMetrics = HostMetrics();
  await hostMetrics.sample(); // prime /proc/stat delta
  final admin = AdminServer(
    coordinator: coordinator,
    config: config,
    adminRoot: adminDir.existsSync()
        ? adminDir.path
        : '$repoRoot/terminal/admin',
    hostMetrics: hostMetrics,
    oauth: coordinator.googleDesktop,
    kioskRoot: kioskDir.existsSync() ? kioskDir.path : null,
    road: road,
  );
  await admin.start();
  await coordinator.googleDesktop.start(sharedServer: true);

  // Push host CPU/mem to the kiosk sparkline (~1 Hz after first delta sample).
  // Optionally adapt avatar bloom/fps from the same samples.
  final avatarAdapt = _avatarAdaptEnabled();
  final governor = AvatarLoadGovernor(
    preferredBloom: _envDouble('COMSTAR_AVATAR_BLOOM_MAX', 3),
    preferredFps: _envDouble('COMSTAR_AVATAR_FPS_MAX', 12),
    minBloom: 0,
    minFps: _envDouble('COMSTAR_AVATAR_FPS_MIN', 8),
    stressCpu: _envDouble('COMSTAR_AVATAR_CPU_STRESS', 75),
    comfortCpu: _envDouble('COMSTAR_AVATAR_CPU_COMFORT', 50),
    criticalCpu: _envDouble('COMSTAR_AVATAR_CPU_CRITICAL', 90),
    enabled: avatarAdapt,
  );
  if (avatarAdapt) {
    logInfo('avatar_adapt_enabled', 'Avatar load governor active', data: {
      'bloom_max': governor.preferredBloom,
      'fps_max': governor.preferredFps,
      'stress_cpu': governor.stressCpu,
      'comfort_cpu': governor.comfortCpu,
    });
  }

  // Manual /control/avatar updates become the new preferred ceiling + pause auto.
  final priorAvatarHook = audioServer.onAvatarOptions;
  audioServer.onAvatarOptions = (opts) async {
    final source = opts['source']?.toString();
    if (source != 'adapt') {
      governor.setPreferred(
        bloom: (opts['bloom'] as num?)?.toDouble(),
        fps: (opts['fps'] as num?)?.toDouble(),
      );
      governor.pauseAuto();
    }
    final hook = priorAvatarHook;
    if (hook != null) return hook(opts);
    return coordinator!.applyAvatarOptions(opts);
  };

  final healthTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
    try {
      final sample = await hostMetrics.sample();
      ws.sendToRole(
        'kiosk',
        Envelope.create(type: 'health', data: sample.toJson()),
      );
      final adapted = governor.onCpu(sample.cpuPercent);
      if (adapted != null) {
        await coordinator?.applyAvatarOptions(adapted);
      }
    } on Object catch (e) {
      logWarn('health_sample_failed', e.toString());
    }
  });

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
    healthTimer.cancel();
    await watchdog.stop();
    await coordinator?.googleDesktop.stop();
    await admin.stop();
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
    final input = cameraSource();
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

bool _avatarAdaptEnabled() {
  final v = Platform.environment['COMSTAR_AVATAR_ADAPT']?.trim().toLowerCase();
  if (v == null || v.isEmpty) return true; // on by default
  return v == '1' || v == 'true' || v == 'yes';
}

double _envDouble(String key, double fallback) {
  final raw = Platform.environment[key]?.trim();
  if (raw == null || raw.isEmpty) return fallback;
  return double.tryParse(raw) ?? fallback;
}
