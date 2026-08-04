import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/effects.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:comstar_bridge/attention/machine.dart';
import 'package:comstar_bridge/attention/runner.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/directory/directory_resolver.dart';
import 'package:comstar_bridge/envelope.dart';
import 'package:comstar_bridge/env_sources.dart';
import 'package:comstar_bridge/google/device_pairing.dart';
import 'package:comstar_bridge/google/desktop_upgrade.dart';
import 'package:comstar_bridge/google/pairing_status.dart';
import 'package:comstar_bridge/google/qr_svg.dart';
import 'package:comstar_bridge/google/token_store.dart';
import 'package:comstar_bridge/google_intent.dart';
import 'package:comstar_bridge/google_data_intent.dart';
import 'package:comstar_bridge/google/workspace_client.dart';
import 'package:comstar_bridge/ha_agent_client.dart';
import 'package:comstar_bridge/home_data_intent.dart';
import 'package:comstar_bridge/http_audio_server.dart';
import 'package:comstar_bridge/local_ws.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/session.dart';
import 'package:comstar_bridge/stt.dart';
import 'package:comstar_bridge/utterance_gate.dart';
import 'package:comstar_bridge/terminal_control.dart';
import 'package:comstar_bridge/terminal_intent.dart';
import 'package:comstar_bridge/tts.dart';
import 'package:comstar_bridge/wake_phrase.dart';
import 'package:comstar_bridge/wav_duration.dart';
import 'package:comstar_bridge/vision/vision_poller.dart' as vision;
import 'package:path/path.dart' as p;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Wires the attention machine to session, STT, TTS, and local WebSocket clients.
class AttentionCoordinator {
  AttentionCoordinator({
    required this.config,
    required this.ws,
    required this.session,
    required this.stt,
    required this.tts,
    required this.audioServer,
    TerminalControl? control,
    Clock? clock,
    this.fallbackAudioDir,
    GoogleTokenStore? googleTokenStore,
    GoogleDevicePairing? googlePairing,
    GoogleDesktopUpgrade? googleDesktopUpgrade,
    DirectoryResolver? directory,
  })  : clock = clock ?? SystemClock(),
        control = control ?? TerminalControl(),
        googleTokens = googleTokenStore ?? GoogleTokenStore(),
        googleOAuth = googlePairing ?? GoogleDevicePairing(),
        googleDesktop = googleDesktopUpgrade ?? GoogleDesktopUpgrade(),
        directory = directory ??
            DirectoryResolver(
              config: config.directory,
              clock: clock ?? SystemClock(),
            ),
        machine = AttentionMachine(
          config: config,
          clock: clock ?? SystemClock(),
        ),
        runner = EffectRunner() {
    this.control.loadPersistedVolume();
    audioServer.control = this.control;
    audioServer.onSleepAction = _onSleepHttp;
  }

  final ComstarConfig config;
  final LocalWs ws;
  final ComstarSession session;
  final SttClient stt;
  final TtsEngine tts;
  final HttpAudioServer audioServer;
  final TerminalControl control;
  final GoogleTokenStore googleTokens;
  final GoogleDevicePairing googleOAuth;
  final GoogleDesktopUpgrade googleDesktop;
  final DirectoryResolver directory;
  final Clock clock;
  final AttentionMachine machine;
  final EffectRunner runner;

  /// Directory of prebaked WAVs (`sorry.wav`, `offline.wav`, …). Optional.
  final String? fallbackAudioDir;

  Timer? _tickTimer;
  Timer? _speakWatchdog;
  Timer? _followUpTimer;
  /// Bumped to cancel a pending follow-up mic-arm when a new speak starts.
  var _followUpGen = 0;
  vision.VisionPoller? _visionPoller;
  StreamSubscription<vision.VisionEvent>? _visionSub;
  Future<void>? _sessionOpenFuture;
  Completer<void>? _googlePairingCancel;
  var _googlePhase = GooglePairingPhase.idle;
  String? _googlePairingUserCode;
  String? _googleLastError;

  final _captureBuffer = BytesBuilder(); // copy:true — toBytes() must not wipe PCM
  var _capturePeakRms = 0.0;
  var _loudFrameCount = 0;
  var _totalFrameCount = 0;
  var _deferRestartCount = 0;
  var _lastDeferRestartAtMs = 0;

  var _captureSampleRate = 16000;
  WebSocketChannel? _audioChannel;
  final Map<String, String> _greetingCache = {};
  DateTime? _speakStartedAt;
  Duration? _lastTtsTotal;
  /// WAV (or text-estimate) play length for the in-flight speak — not TTS synth time.
  int _lastSpeakDurationMs = 3000;

  /// Force-wake while Sleeping: capture + STT must match hey/hello comstar.
  var _sleepWakeVerifyInFlight = false;
  double _sleepWakeScore = 0.8;
  Timer? _sleepWakeTimer;
  var _sleepWakeRestartCount = 0;
  var _sleepWakeRestarting = false;

  Future<void> start({vision.VisionPoller? visionPoller}) async {
    await audioServer.start();
    _tickTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => handle(const Tick()),
    );
    if (visionPoller != null) {
      _visionPoller = visionPoller;
      await visionPoller.start();
      _visionSub = visionPoller.events.listen(_onVisionEvent);
    }
  }

  Future<void> stop() async {
    _tickTimer?.cancel();
    _tickTimer = null;
    _cancelSpeakWatchdog();
    _followUpTimer?.cancel();
    _followUpTimer = null;
    _cancelSleepWakeVerify(stopListen: true);
    await _visionSub?.cancel();
    _visionSub = null;
    await _visionPoller?.stop();
    await session.close();
    await audioServer.stop();
  }

  void attachAudioChannel(WebSocketChannel channel) {
    _audioChannel = channel;
  }

  void handleWsMessage(String role, Envelope envelope) {
    if (role == 'audio') {
      _handleAudioEnvelope(envelope);
      return;
    }
    if (role == 'kiosk') {
      _handleKioskEnvelope(envelope);
    }
  }

  void handleBinaryAudio(Uint8List chunk) {
    _captureBuffer.add(chunk);
    // Track peak / loudness while capturing so we can decide STT vs re-arm
    // without relying on average RMS (speech is sparse in a 3s window).
    if (chunk.length >= 2) {
      final rms = _pcmRms(chunk);
      _totalFrameCount++;
      if (rms > _capturePeakRms) _capturePeakRms = rms;
      // Frame is "loud" if clearly above idle C525 @70%.
      if (rms >= 0.05) _loudFrameCount++;
    }
  }

  void _resetCaptureStats() {
    _capturePeakRms = 0.0;
    _loudFrameCount = 0;
    _totalFrameCount = 0;
  }

  void handle(AttentionEvent event) {
    final transition = machine.handle(event);
    for (final effect in transition.effects) {
      runner.dispatch(effect);
      _handleEffect(effect);
    }
  }

  void _handleEffect(Effect effect) {
    switch (effect) {
      case SetVisionFps(:final fps):
        _visionPoller?.setTargetFps(fps);
      case OpenSession(:final userid, :final guest):
        _sessionOpenFuture = session.open(userid: userid, guest: guest);
        unawaited(_sessionOpenFuture);
      case CloseSession():
        _cancelGooglePairing();
        _sessionOpenFuture = null;
        directory.clearCache();
        unawaited(session.close());
      case StartListening(:final turnId):
        _followUpTimer?.cancel();
        _followUpTimer = null;
        _captureBuffer.clear();
        _resetCaptureStats();
        _deferRestartCount = 0;
        _sendAudio(
          Envelope.create(
            type: 'listen.start',
            turnId: turnId,
            data: {
              'turn_id': turnId,
              'maxMs': config.audio.maxUtteranceSeconds * 1000,
              // Wake-path pre-roll was producing 1.9s ambient STT junk.
              'preRollMs': 0,
            },
          ),
        );
        _broadcastPhase('listening', detail: 'Listening…');
        _broadcastKiosk(
          Envelope.create(type: 'listening', data: {'active': true}),
        );
      case StopListening():
        _sendAudio(Envelope.create(type: 'listen.stop'));
        _broadcastKiosk(
          Envelope.create(type: 'listening', data: {'active': false}),
        );
      case FinalizeCapture():
        _sendAudio(Envelope.create(type: 'listen.stop'));
      case CallStt(:final turnId):
        unawaited(_runStt(turnId));
      case CallDirectAgent(:final text, :final turnId):
        unawaited(_runDirectAgent(text, turnId));
      case SetThinking(:final active):
        _broadcastKiosk(
          Envelope.create(type: 'thinking', data: {'active': active}),
        );
        if (active) {
          _broadcastPhase('thinking', detail: 'Talking to AO…');
        }
      case Speak(:final text, :final audioUrl, :final turnId):
        machine.context.playing = true;
        // Half-duplex: never capture while TTS is on the speaker.
        // Abort sleep-wake STT so listen.stop does not finalize empty PCM.
        if (_sleepWakeVerifyInFlight) {
          _cancelSleepWakeVerify(stopListen: false);
          if (machine.state is Sleeping) {
            _returnSleepHud();
          }
        }
        _followUpGen++;
        _followUpTimer?.cancel();
        _followUpTimer = null;
        machine.context.followUpListening = false;
        machine.context.followUpOpen = false;
        _sendAudio(Envelope.create(type: 'listen.stop'));
        _sendAudio(
          Envelope.create(type: 'wake.enable', data: {'enabled': false}),
        );
        _broadcastKiosk(
          Envelope.create(type: 'listening', data: {'active': false}),
        );
        // Clear thinking UI as soon as we have audio to play.
        _broadcastKiosk(
          Envelope.create(type: 'thinking', data: {'active': false}),
        );
        _beginSpeakWatchdog();
        final sleepAck = machine.state is Sleeping;
        // Sleep ack: keep Sleeping HUD/avatar dim while the line plays.
        if (sleepAck) {
          _broadcastPhase('sleeping', detail: text);
        } else {
          _broadcastPhase('speaking', detail: text);
        }
        if (text.trim().isNotEmpty) {
          logInfo('speak', 'Sending reply to kiosk', data: {
            'turn_id': turnId,
            'chars': text.length,
            'audioUrl': audioUrl,
            'duration_ms': _lastSpeakDurationMs,
            if (sleepAck) 'sleep_ack': true,
          });
        }
        _broadcastKiosk(
          Envelope.create(
            type: 'speak',
            turnId: turnId,
            data: {
              'text': text,
              'audioUrl': audioUrl,
              if (sleepAck) 'keepSleeping': true,
            },
          ),
        );
        unawaited(_maybePlayLocal(audioUrl));
      case SpeakFallback(:final line, :final turnId):
        unawaited(_speakFallback(line, turnId));
      case PlayErrorTone():
        _sendAudio(Envelope.create(type: 'play', data: {'tone': 'error'}));
      case EnableWake(:final enabled):
        _sendAudio(
          Envelope.create(type: 'wake.enable', data: {'enabled': enabled}),
        );
      case OpenFollowUpWindow():
        _openFollowUpWindow();
      case PromoteListening():
        _followUpTimer?.cancel();
        _followUpTimer = null;
        logInfo('listen_promote', 'Promoted follow-up capture to Listening');
        _broadcastPhase('listening', detail: 'Listening…');
        _broadcastKiosk(
          Envelope.create(type: 'listening', data: {'active': true}),
        );
      case RunGreeter(:final userid):
        unawaited(_runGreeterAfterSession(userid));
      case EmitState(:final stateName, :final userid, :final displayName):
        _broadcastKiosk(
          Envelope.create(
            type: 'state',
            data: {
              'state': stateName,
              if (userid != null) 'userid': userid,
              if (displayName != null) 'displayName': displayName,
            },
          ),
        );
        // Drive the phase pill from attention state so the HUD is not stuck
        // on Ready while we are noticed / listening / responding.
        switch (stateName) {
          case 'noticed':
            _broadcastPhase('noticed', detail: 'I see you…');
          case 'listening':
            _broadcastPhase('listening', detail: 'Listening…');
          case 'responding':
            break; // speak / thinking handlers set finer phases
          case 'engaged':
            _broadcastPhase('engaged', detail: userid ?? '');
          case 'ambient':
            _broadcastPhase('idle', detail: '');
          case 'sleeping':
            _broadcastPhase('sleeping', detail: 'Sleeping…');
          default:
            break;
        }
      case EnteredSleep():
        _cancelGooglePairing();
        control.sleepEnter();
        _cancelSleepWakeVerify(stopListen: true);
        _followUpTimer?.cancel();
        _followUpTimer = null;
        // Dim avatar + Sleeping HUD immediately (before sleep-ack TTS).
        _syncKioskAttention();
        _broadcastKiosk(
          Envelope.create(type: 'listening', data: {'active': false}),
        );
        _broadcastKiosk(
          Envelope.create(type: 'thinking', data: {'active': false}),
        );
      case ExitedSleep():
        control.sleepExit();
        _cancelSleepWakeVerify(stopListen: false);
      case LogAttention():
        break;
    }
  }

  Future<bool> _onSleepHttp(String action) async {
    if (action == 'enter') {
      handle(const EnterSleep());
      // Re-push even if already sleeping so a reconnecting kiosk catches up.
      _syncKioskAttention();
      return machine.state is Sleeping;
    }
    if (action == 'exit') {
      if (machine.state is Sleeping) {
        handle(const ExitSleep());
      }
      _syncKioskAttention();
      return machine.state is! Sleeping;
    }
    return false;
  }

  void _openFollowUpWindow() {
    final seconds = config.audio.followupWindowSeconds;
    final gen = ++_followUpGen;
    logInfo('followup', 'Follow-up window opened', data: {'seconds': seconds});
    final turnId = 'followup-${clock.nowMs}';
    machine.context.followUpOpen = true;
    machine.context.followUpListening = true;
    machine.context.followUpOpenedAtMs = clock.nowMs;
    machine.context.turnId = turnId;
    machine.context.listeningStartedAtMs = clock.nowMs;
    _captureBuffer.clear();
    _broadcastPhase('listening', detail: 'Listening…');
    _broadcastKiosk(
      Envelope.create(
        type: 'listening',
        data: {'active': true, 'followUp': true},
      ),
    );
    // Keep force-wake muted until TTS echo settles.
    _sendAudio(
      Envelope.create(type: 'wake.enable', data: {'enabled': false}),
    );
    _sendAudio(Envelope.create(type: 'listen.stop'));
    // Delay mic start until after settle so the first VAD speech_start cannot
    // race the arm window and be lost forever (continuous hiss never re-fires).
    const settleMs = 1500;
    Future<void>.delayed(const Duration(milliseconds: settleMs), () {
      if (gen != _followUpGen) return;
      if (machine.context.turnId != turnId) return;
      if (machine.context.playing) return;
      if (machine.state is! Engaged || !machine.context.followUpListening) {
        return;
      }
      machine.context.followUpMicArmedAtMs = clock.nowMs;
      machine.context.wakeEnabled = true;
      _captureBuffer.clear();
      _resetCaptureStats();
      _sendAudio(
        Envelope.create(type: 'wake.enable', data: {'enabled': true}),
      );
      _sendAudio(
        Envelope.create(
          type: 'listen.start',
          turnId: turnId,
          data: {
            'turn_id': turnId,
            // Cap one utterance; speech_end usually finishes earlier.
            'maxMs': 8000,
            'preRollMs': 0,
            'vadSettleMs': 0,
            'clearRing': true,
          },
        ),
      );
      logInfo(
        'followup',
        'Engaged mic armed — listening for utterance',
      );
      // Enter Listening immediately so levels + capture are live. STT is gated
      // later by peak energy so silence still does not go to Whisper.
      machine.context.followUpMicArmedAtMs = clock.nowMs - 2000;
      handle(const SpeechStart());
    });
    _followUpTimer?.cancel();
    _followUpTimer = Timer(Duration(seconds: seconds), () {
      if (gen != _followUpGen) return;
      // Only stop if we never entered a real listening turn.
      if (machine.state is! Listening) {
        machine.context.followUpListening = false;
        if (machine.context.turnId == turnId) {
          machine.context.turnId = null;
        }
        _sendAudio(Envelope.create(type: 'listen.stop'));
        _broadcastKiosk(
          Envelope.create(type: 'listening', data: {'active': false}),
        );
      }
      machine.context.followUpOpen = false;
      logInfo('followup', 'Follow-up window closed');
    });
  }

  void _onVisionEvent(vision.VisionEvent event) {
    switch (event) {
      case vision.VisionPersonDetected(:final confidence):
        handle(PersonDetected(confidence));
      case vision.VisionPersonAbsent():
        handle(const PersonAbsent());
      case vision.VisionFaceRecognized(:final userid, :final confidence):
        unawaited(_onFaceRecognized(userid, confidence));
      case vision.VisionFaceUnknown():
        handle(const FaceUnknown());
      case vision.VisionDegraded():
        handle(const VisionDegraded());
      case vision.VisionRecovered():
        handle(const VisionRecovered());
    }
  }

  Future<void> _onFaceRecognized(String faceId, double confidence) async {
    final result = await directory.resolveByFaceId(faceId);
    switch (result) {
      case DirectoryResolved(:final profile):
        logInfo('directory_resolved', 'faceId mapped to uid', data: {
          'face_id': faceId,
          'uid': profile.uid,
          'displayName': profile.displayName,
        });
        handle(
          FaceRecognized(
            profile.uid,
            confidence,
            displayName: profile.displayName,
            faceId: faceId,
          ),
        );
      case DirectoryMiss():
        logWarn('directory_miss', 'no LDAP person for faceId', data: {
          'face_id': faceId,
          'require': config.directory.require,
        });
        if (config.directory.enabled && config.directory.require) {
          handle(const FaceUnknown());
        } else {
          handle(
            FaceRecognized(
              faceId,
              confidence,
              displayName: faceId,
              faceId: faceId,
            ),
          );
        }
      case DirectoryError(:final message):
        logWarn('directory_error', message, data: {
          'face_id': faceId,
          'require': config.directory.require,
        });
        if (config.directory.enabled && config.directory.require) {
          handle(const FaceUnknown());
        } else {
          handle(
            FaceRecognized(
              faceId,
              confidence,
              displayName: faceId,
              faceId: faceId,
            ),
          );
        }
    }
  }

  void _handleAudioEnvelope(Envelope envelope) {
    switch (envelope.type) {
      case 'wake':
        final score = (envelope.data['score'] as num?)?.toDouble() ?? 0;
        final model = envelope.data['model']?.toString() ?? '';
        // Sleep: real hey_comstar model may wake immediately. Force/energy wake
        // (no ONNX on Pi) must STT-confirm "hey/hello comstar" — not bare hello.
        if (machine.state is Sleeping && model != 'hey_comstar') {
          // TTS still playing — ignore energy wakes (HDMI echo / greeter race).
          if (machine.context.playing) break;
          unawaited(_beginSleepWakeVerify(score));
          break;
        }
        handle(WakeWord(score));
      case 'vad.speech_start':
        if (_sleepWakeVerifyInFlight) break;
        handle(const SpeechStart());
      case 'vad.speech_end':
        if (_sleepWakeVerifyInFlight) {
          unawaited(_finishSleepWakeVerify(reason: 'vad_end'));
          break;
        }
        final durationMs = (envelope.data['durationMs'] as num?)?.toInt() ?? 0;
        if ((machine.state is Listening || machine.context.followUpListening) &&
            !machine.context.sttPending) {
          if (_tryDeferShortCapture(
            reason: 'vad_end',
            durationMs: durationMs,
          )) {
            break;
          }
        }
        handle(SpeechEnd(durationMs));
      case 'audio.begin':
        // Keep buffered PCM across listen restarts; only refresh sample rate.
        _captureSampleRate =
            (envelope.data['sampleRate'] as num?)?.toInt() ?? 16000;
      case 'audio.end':
        if (_sleepWakeVerifyInFlight) {
          unawaited(_finishSleepWakeVerify(reason: 'listen_eof'));
          break;
        }
        // Streamer hit maxMs / stop without a VAD speech_end — still finalize,
        // but bounce true blips the same way as early SpeechEnd.
        if (machine.state is Listening && !machine.context.sttPending) {
          final turnId = machine.context.turnId;
          if (turnId != null) {
            if (_tryDeferShortCapture(reason: 'listen_eof', durationMs: 0)) {
              break;
            }
            logInfo('listen_eof', 'audio.end while Listening; finalizing', data: {
              'turn_id': turnId,
              'bytes': _captureBuffer.length,
            });
            handle(SpeechEnd(_captureBuffer.length));
          }
        }
      case 'level':
        // Only drive the avatar mic meter while we are actually capturing.
        // After FinalizeCapture the streamer stops but level msgs continue —
        // that made the orb "listen" while STT ran on dead audio.
        final capturing = (machine.state is Listening ||
                machine.context.followUpListening ||
                _sleepWakeVerifyInFlight) &&
            !machine.context.sttPending;
        if (!capturing) {
          break;
        }
        final rms = (envelope.data['rms'] as num?)?.toDouble() ?? 0;
        _broadcastKiosk(
          Envelope.create(
            type: 'listening',
            data: {'active': true, 'level': rms},
          ),
        );
      default:
        break;
    }
  }

  Future<void> _beginSleepWakeVerify(double score) async {
    if (machine.state is! Sleeping) return;
    if (_sleepWakeVerifyInFlight) return;
    if (machine.context.playing) return;
    _sleepWakeVerifyInFlight = true;
    _sleepWakeScore = score;
    _sleepWakeRestartCount = 0;
    _captureBuffer.clear();
    _resetCaptureStats();
    final turnId = 'sleep-wake-${clock.nowMs}';
    logInfo('sleep_wake_verify', 'Checking wake phrase (need hey/hello comstar)', data: {
      'turn_id': turnId,
      'score': score,
    });
    // Sleep submode: brighten to Listening while we STT-confirm the phrase.
    _broadcastPhase('listening', detail: 'Listening for hey comstar…');
    _broadcastKiosk(
      Envelope.create(type: 'state', data: {'state': 'listening'}),
    );
    _broadcastKiosk(
      Envelope.create(type: 'listening', data: {'active': true}),
    );
    // Keep force-wake quiet during verify so we don't stack energy wakes.
    _sendAudio(
      Envelope.create(type: 'wake.enable', data: {'enabled': false}),
    );
    _sendAudio(
      Envelope.create(
        type: 'listen.start',
        turnId: turnId,
        data: {
          'turn_id': turnId,
          // Force-wake fires after the phrase; keep a long ring pre-roll so
          // "hey comstar" is still in the buffer for STT confirm.
          'maxMs': 4000,
          'preRollMs': 2800,
          'vadSettleMs': 4000,
          'clearRing': false,
        },
      ),
    );
    _sleepWakeTimer?.cancel();
    _sleepWakeTimer = Timer(const Duration(seconds: 8), () {
      unawaited(_finishSleepWakeVerify(reason: 'timeout'));
    });
  }

  Future<void> _finishSleepWakeVerify({required String reason}) async {
    if (!_sleepWakeVerifyInFlight) return;
    if (_sleepWakeRestarting) return;
    _sleepWakeTimer?.cancel();
    _sleepWakeTimer = null;
    final score = _sleepWakeScore;
    _sendAudio(Envelope.create(type: 'listen.stop'));
    _broadcastKiosk(
      Envelope.create(type: 'listening', data: {'active': false}),
    );

    final pcm = _captureBuffer.toBytes();
    final peak = _capturePeakRms;
    _captureBuffer.clear();
    _resetCaptureStats();

    if (machine.state is! Sleeping) {
      _sleepWakeVerifyInFlight = false;
      _sleepWakeRestartCount = 0;
      return;
    }

    // First eof often arrives before pre-roll speech is flushed — retry once.
    if ((pcm.length < 32000 || peak < _speechPeakRms * 0.6) &&
        _sleepWakeRestartCount < 1 &&
        reason != 'timeout') {
      _sleepWakeRestartCount++;
      _sleepWakeRestarting = true;
      logInfo('sleep_wake_retry', 'Wake verify capture thin; listening again', data: {
        'reason': reason,
        'bytes': pcm.length,
        'peak': peak,
      });
      final turnId = 'sleep-wake-${clock.nowMs}';
      _sendAudio(
        Envelope.create(
          type: 'listen.start',
          turnId: turnId,
          data: {
            'turn_id': turnId,
            'maxMs': 4000,
            'preRollMs': 2800,
            'vadSettleMs': 4000,
            'clearRing': false,
          },
        ),
      );
      _sleepWakeTimer = Timer(const Duration(seconds: 8), () {
        unawaited(_finishSleepWakeVerify(reason: 'timeout'));
      });
      _sleepWakeRestarting = false;
      return;
    }

    // Prefer trying STT even on short captures — Whisper often still hears
    // "hey comestar" and the phrase gate is the real filter.
    if (pcm.length < 8000 || peak < _speechPeakRms * 0.35) {
      logInfo('sleep_wake_reject', 'Wake verify too quiet / short', data: {
        'reason': reason,
        'bytes': pcm.length,
        'peak': peak,
      });
      _sleepWakeVerifyInFlight = false;
      _sleepWakeRestartCount = 0;
      _returnSleepHud();
      return;
    }

    try {
      final text = await stt.transcribe(pcm, sampleRate: _captureSampleRate);
      final ok = isComstarWakePhrase(text);
      logInfo('sleep_wake_stt', ok ? 'Wake phrase accepted' : 'Wake phrase rejected', data: {
        'reason': reason,
        'text': text.length > 80 ? '${text.substring(0, 80)}…' : text,
        'accepted': ok,
      });
      _sleepWakeVerifyInFlight = false;
      _sleepWakeRestartCount = 0;
      if (ok && machine.state is Sleeping) {
        handle(WakeWord(score));
        // Ready HUD — mute force-wake briefly so the same utterance does not
        // immediately flip Engaged → Listening.
        machine.context.wakeEnabled = false;
        _sendAudio(
          Envelope.create(type: 'wake.enable', data: {'enabled': false}),
        );
        _broadcastPhase('idle', detail: '');
        _broadcastKiosk(
          Envelope.create(
            type: 'state',
            data: {
              'state': machine.state.name,
              if (machine.context.cachedUserid != null)
                'userid': machine.context.cachedUserid,
            },
          ),
        );
        Future<void>.delayed(const Duration(milliseconds: 1500), () {
          if (machine.state is! Engaged) return;
          if (machine.context.playing) return;
          if (machine.context.followUpListening) return;
          machine.context.wakeEnabled = true;
          _sendAudio(
            Envelope.create(type: 'wake.enable', data: {'enabled': true}),
          );
        });
      } else {
        _returnSleepHud();
      }
    } catch (e) {
      _sleepWakeVerifyInFlight = false;
      _sleepWakeRestartCount = 0;
      logWarn('sleep_wake_stt_failed', e.toString());
      _returnSleepHud();
    }
  }

  void _returnSleepHud() {
    _broadcastPhase('sleeping', detail: 'Sleeping…');
    _broadcastKiosk(
      Envelope.create(type: 'state', data: {'state': 'sleeping'}),
    );
    _broadcastKiosk(
      Envelope.create(type: 'listening', data: {'active': false}),
    );
    // Reject / abort paths mute wake for verify; restore if still dormant.
    if (machine.state is Sleeping && !machine.context.playing) {
      machine.context.wakeEnabled = true;
      _sendAudio(
        Envelope.create(type: 'wake.enable', data: {'enabled': true}),
      );
    }
  }

  void _cancelSleepWakeVerify({required bool stopListen}) {
    _sleepWakeTimer?.cancel();
    _sleepWakeTimer = null;
    if (!_sleepWakeVerifyInFlight) return;
    _sleepWakeVerifyInFlight = false;
    _sleepWakeRestartCount = 0;
    if (stopListen) {
      _sendAudio(Envelope.create(type: 'listen.stop'));
      _captureBuffer.clear();
      _resetCaptureStats();
    }
  }

  /// ~2.0s mono s16le @ 16 kHz. Fast phrases were finalizing at ~1.6s truncated.
  static const _minFinalizeBytes = 64000;
  /// ~0.8s — below this, keep listening (unless very loud short "yes"/"hey").
  static const _minKeepBytes = 25600;
  /// Peak RMS that counts as "someone spoke" (C525 @80%).
  static const _speechPeakRms = 0.04;
  /// Min gap between defer→listen.start restarts (prevents audio.end feedback storms).
  static const _deferRestartCooldownMs = 500;
  /// After this many soft restarts, force STT / give up instead of looping.
  static const _maxDeferRestarts = 4;

  /// Returns true if we deferred STT and restarted capture (caller should break).
  bool _tryDeferShortCapture({
    required String reason,
    required int durationMs,
  }) {
    final bytes = _captureBuffer.length;
    final peak = _capturePeakRms;
    final loudFrac = _totalFrameCount == 0
        ? 0.0
        : _loudFrameCount / _totalFrameCount;

    final hasSpeech = peak >= _speechPeakRms || loudFrac >= 0.15;

    // Enough audio AND real speech energy → finalize.
    if (bytes >= _minFinalizeBytes && hasSpeech) {
      _deferRestartCount = 0;
      return false;
    }
    // Short but clearly spoken → finalize.
    if (bytes >= _minKeepBytes && peak >= 0.08) {
      logInfo('capture_short_ok', 'Finalizing short loud utterance', data: {
        'reason': reason,
        'bytes': bytes,
        'peak': peak,
        'loud_frac': loudFrac,
        'duration_ms': durationMs,
      });
      _deferRestartCount = 0;
      return false;
    }

    final now = clock.nowMs;
    if (now - _lastDeferRestartAtMs < _deferRestartCooldownMs) {
      // Ignore duplicate audio.end/vad_end from listen.start→stop races.
      return true;
    }
    if (_deferRestartCount >= _maxDeferRestarts) {
      logWarn(
        'capture_defer_exhausted',
        'Too many soft restarts; forcing finalize',
        data: {
          'reason': reason,
          'bytes': bytes,
          'peak': peak,
          'restarts': _deferRestartCount,
        },
      );
      _deferRestartCount = 0;
      return false;
    }

    final turnId = machine.context.turnId ?? 'relisten';
    // Long quiet window: drop ambient so the next utterance is clean.
    // Short window: keep PCM in case speech was mid-phrase.
    final clear = bytes >= _minFinalizeBytes && !hasSpeech;
    if (clear) {
      _captureBuffer.clear();
      _resetCaptureStats();
    }
    _deferRestartCount += 1;
    _lastDeferRestartAtMs = now;
    logWarn(
      reason == 'listen_eof' ? 'listen_eof_ignored' : 'vad_end_ignored',
      clear
          ? 'Quiet capture; clearing and restarting'
          : 'No clear speech yet; keeping PCM and restarting',
      data: {
        'bytes': bytes,
        'peak': peak,
        'loud_frac': loudFrac,
        'duration_ms': durationMs,
        'turn_id': turnId,
        'cleared': clear,
        'restart': _deferRestartCount,
      },
    );
    machine.context.listeningStartedAtMs = clock.nowMs;
    // Keep a short VAD settle so listen.start→immediate speech_end cannot storm.
    _sendAudio(
      Envelope.create(
        type: 'listen.start',
        turnId: turnId,
        data: {
          'turn_id': turnId,
          'maxMs': 8000,
          'preRollMs': 0,
          'vadSettleMs': 500,
          'clearRing': clear,
        },
      ),
    );
    return true;
  }

  void _handleKioskEnvelope(Envelope envelope) {
    switch (envelope.type) {
      case 'ready':
        // Kiosk (re)connected — push current attention so sleep/listen HUD
        // and avatar opacity match the machine after a Chromium restart.
        _syncKioskAttention();
      case 'speak.started':
        final started = _speakStartedAt;
        if (started != null) {
          final ms = DateTime.now().difference(started).inMilliseconds;
          Span('avatar_start').close();
          logDebug('span', 'avatar_start', data: {'ms': ms});
        }
      case 'speak.ended':
        _cancelSpeakWatchdog();
        logInfo(
          'speak_ended',
          'Kiosk reported speak.ended',
          data: {'state': machine.state.name},
        );
        final alreadyFollowUp = machine.context.followUpListening ||
            machine.context.followUpOpen;
        final micNeverArmed = machine.context.followUpMicArmedAtMs == null;
        handle(const PlaybackEnded());
        // Defensive: open follow-up if the machine did not; re-open when a
        // premature PlaybackEnded raced greeter (_followUpGen) and cancelled
        // settle before the mic was armed.
        if (machine.state is Engaged &&
            alreadyFollowUp &&
            micNeverArmed &&
            machine.context.followUpMicArmedAtMs == null) {
          logWarn(
            'followup_rearm',
            'Re-opening follow-up after speak.ended (mic never armed)',
          );
          machine.context.followUpOpen = true;
          machine.context.followUpOpenedAtMs = clock.nowMs;
          _openFollowUpWindow();
        } else if (machine.state is Engaged &&
            !machine.context.followUpListening &&
            !alreadyFollowUp) {
          logWarn('followup_fallback', 'Opening follow-up after speak.ended');
          machine.context.followUpOpen = true;
          machine.context.followUpOpenedAtMs = clock.nowMs;
          _openFollowUpWindow();
        } else if (machine.context.followUpListening ||
            machine.state is Listening) {
          _broadcastPhase('listening', detail: 'Listening…');
        } else if (machine.state is Sleeping) {
          // Speak muted wake for half-duplex; always re-arm after sleep TTS.
          machine.context.playing = false;
          machine.context.wakeEnabled = true;
          _sendAudio(
            Envelope.create(type: 'wake.enable', data: {'enabled': true}),
          );
          _returnSleepHud();
        } else {
          _broadcastPhase('idle', detail: '');
        }
      default:
        break;
    }
  }

  void _beginSpeakWatchdog() {
    _cancelSpeakWatchdog();
    _speakStartedAt = DateTime.now();
    // Use play duration (WAV), not TTS synth latency — early PlaybackEnded
    // was arming the mic while the kiosk was still speaking.
    final playMs = _lastSpeakDurationMs > 0 ? _lastSpeakDurationMs : 3000;
    final timeout = Duration(milliseconds: playMs + 4000);
    _speakWatchdog = Timer(timeout, () {
      logWarn(
        'speak_watchdog',
        'kiosk speak.ended missing; forcing PlaybackEnded',
        data: {
          'timeout_ms': timeout.inMilliseconds,
          'play_ms': playMs,
        },
      );
      // Greeter speaks while Engaged — mirror speak.ended wake restore.
      if (machine.context.state is! Responding) {
        _sendAudio(
          Envelope.create(type: 'wake.enable', data: {'enabled': true}),
        );
      }
      handle(const PlaybackEnded());
    });
  }

  /// Record expected speaker play time before sending a `speak` envelope.
  void _noteSpeakDuration({required String path, String text = ''}) {
    final fromWav = wavDurationMs(path);
    _lastSpeakDurationMs = fromWav ?? estimateSpeechMs(text);
    logDebug('speak_duration', 'Expected play length', data: {
      'ms': _lastSpeakDurationMs,
      'source': fromWav != null ? 'wav' : 'text_estimate',
      'chars': text.trim().length,
    });
  }

  void _cancelSpeakWatchdog() {
    _speakWatchdog?.cancel();
    _speakWatchdog = null;
  }

  Future<void> _runStt(String turnId) async {
    final span = Span('stt');
    try {
      var pcm = _captureBuffer.toBytes();
      final peak = _capturePeakRms;
      final avg = _pcmRms(pcm);
      final loudFrac = _totalFrameCount == 0
          ? 0.0
          : _loudFrameCount / _totalFrameCount;

      if (pcm.length < 16000) {
        logWarn('stt_too_short', 'Capture too short for STT', data: {
          'turn_id': turnId,
          'bytes': pcm.length,
          'peak': peak,
        });
        handle(const TranscriptReady(''));
        return;
      }

      // Gate on peak / loud fraction — average RMS of a 3s clip stays low even
      // when the user clearly spoke for 1s in the middle.
      final hasSpeech = peak >= _speechPeakRms || loudFrac >= 0.12;
      if (!hasSpeech) {
        logInfo('stt_silence', 'No speech energy in capture; re-arming', data: {
          'turn_id': turnId,
          'bytes': pcm.length,
          'peak': peak,
          'avg': avg,
          'loud_frac': loudFrac,
        });
        handle(const TranscriptReady(''));
        return;
      }

      // Digital gain was clipping soft C525 captures and feeding Moonshine
      // garbage that hallucinates. Leave levels alone — raise mic at ALSA.
      final samplePeak = _pcmSamplePeak(pcm);
      if (samplePeak > 0 && samplePeak < 0.05) {
        logInfo('stt_soft', 'Capture is very soft', data: {
          'turn_id': turnId,
          'peak': peak,
          'sample_peak': samplePeak,
        });
      }

      _broadcastPhase('thinking', detail: 'Transcribing…');
      final text = await stt.transcribe(pcm, sampleRate: _captureSampleRate);
      logInfo(
        'stt_result',
        text.trim().isEmpty ? 'Empty transcript' : 'Transcript ready',
        data: {
          'turn_id': turnId,
          'bytes': pcm.length,
          'peak': peak,
          'avg': avg,
          'loud_frac': loudFrac,
          'text': text.length > 120 ? '${text.substring(0, 120)}…' : text,
        },
      );
      if (text.trim().isEmpty) {
        handle(const TranscriptReady(''));
        return;
      }
      final cleaned = collapseRepeatedUtterance(text);
      if (_isJunkTranscript(cleaned)) {
        logWarn('stt_junk', 'Rejecting hallucinated/junk transcript', data: {
          'turn_id': turnId,
          'bytes': pcm.length,
          'len': cleaned.length,
          'text': cleaned.length > 80 ? '${cleaned.substring(0, 80)}…' : cleaned,
        });
        _broadcastPhase('missed', detail: "Didn't catch that — try again");
        handle(const TranscriptReady(''));
        return;
      }
      if (!isActionableUtterance(cleaned)) {
        logInfo('stt_non_prompt', 'Ignoring non-prompt transcript', data: {
          'turn_id': turnId,
          'bytes': pcm.length,
          'text': cleaned.length > 80 ? '${cleaned.substring(0, 80)}…' : cleaned,
        });
        _broadcastPhase('missed', detail: "Didn't catch a question — try again");
        handle(const TranscriptReady(''));
        return;
      }
      final clipped =
          cleaned.length > 80 ? '${cleaned.substring(0, 80)}…' : cleaned;
      _broadcastPhase('heard', detail: clipped);
      handle(TranscriptReady(cleaned));
    } finally {
      _resetCaptureStats();
      span.close();
    }
  }

  Uint8List _boostPcm(Uint8List pcm, double gain) {
    final out = Uint8List(pcm.length);
    final src = ByteData.sublistView(pcm);
    final dst = ByteData.sublistView(out);
    final n = pcm.length ~/ 2;
    for (var i = 0; i < n; i++) {
      final s = src.getInt16(i * 2, Endian.little);
      final v = (s * gain).round().clamp(-32768, 32767);
      dst.setInt16(i * 2, v, Endian.little);
    }
    return out;
  }

  /// Absolute sample peak of int16 LE PCM in 0..1.
  double _pcmSamplePeak(Uint8List pcm) {
    if (pcm.length < 2) return 0;
    final bd = ByteData.sublistView(pcm);
    final samples = pcm.length ~/ 2;
    var peak = 0;
    for (var i = 0; i < samples; i++) {
      final s = bd.getInt16(i * 2, Endian.little).abs();
      if (s > peak) peak = s;
    }
    return peak / 32768.0;
  }

  /// RMS of int16 LE PCM in ~0..1 (same scale as energy VAD).
  double _pcmRms(Uint8List pcm) {
    if (pcm.length < 4) return 0;
    final bd = ByteData.sublistView(pcm);
    final samples = pcm.length ~/ 2;
    var sum = 0.0;
    for (var i = 0; i < samples; i++) {
      final s = bd.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
    }
    return math.sqrt(sum / samples);
  }

  /// Whisper often emits long runs of a single character (or no spaces) on
  /// hum/clipping. Treat those as a missed listen, not a real utterance.
  bool _isJunkTranscript(String text) {
    final t = text.trim();
    if (t.isEmpty) return true;
    final lower = t
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Exact micro-fillers.
    const fillers = {
      'okay',
      'ok',
      'yes',
      'yeah',
      'yep',
      'no',
      'nope',
      'you',
      'the',
      'a',
      'um',
      'uh',
      'hmm',
      'hi',
      'hello',
      'bye',
      'thanks',
      'thank you',
      'thank you very much',
      'thanks for watching',
      'subtitle',
      'subtitles',
      'music',
      'applause',
      'silence',
      'a user speaking to the phone',
      'a user speaking to the comstar home assistant',
    };
    if (fillers.contains(lower)) return true;

    // Stutter loops: "Hello. Hello. Hello."
    if (RegExp(r'^(\b\w+\b)([.\s,]+\1){2,}\.?$', caseSensitive: false)
        .hasMatch(t)) {
      return true;
    }

    // Phrase-family hallucinations (YouTube / podcast Whisper priors +
    // Moonshine Librispeech priors that fire on noise).
    const ghostPhrases = [
      'thank you very much',
      'thanks for watching',
      'thanks for listening',
      'please subscribe',
      'like and subscribe',
      'see you next time',
      'see you in the next',
      'we ll see you',
      "we'll see you",
      'for your time',
      'for watching',
      'amara.org',
      'subtitle',
      'transcription by',
      'a user speaking',
      'speaking to the phone',
      'speaking to the comstar',
      'questions and requests',
      'clear english',
      'yellow lamps',
      'squalid',
      'early nightfall',
      'quarter of the brothel',
      'you d be dead',
      'youd be dead',
      'you would be dead',
      'i dont believe you',
      "i don't believe you",
      'shut up now',
      'can you see my god',
    ];
    for (final p in ghostPhrases) {
      if (lower.contains(p)) return true;
    }

    // Mostly "thank you" / "thanks" with little else.
    final words = lower.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isNotEmpty) {
      final thankish = words.where((w) =>
          w == 'thank' ||
          w == 'thanks' ||
          w == 'you' ||
          w == 'very' ||
          w == 'much' ||
          w == 'for' ||
          w == 'your' ||
          w == 'time' ||
          w == 'watching' ||
          w == 'listening').length;
      if (thankish / words.length >= 0.7) return true;
    }

    if (t.length > 80 && !t.contains(RegExp(r'\s'))) return true;
    final letters = lower.replaceAll(RegExp(r'[^a-z]'), '');
    if (letters.isEmpty) return true;
    final counts = <String, int>{};
    for (final c in letters.split('')) {
      counts[c] = (counts[c] ?? 0) + 1;
    }
    final maxCount = counts.values.reduce((a, b) => a > b ? a : b);
    if (maxCount / letters.length >= 0.55) return true;
    if (RegExp(r'(.)\1{8,}').hasMatch(letters)) return true;
    // Exact phrase doubles are collapsed upstream via collapseRepeatedUtterance;
    // only treat pathological multi-repeats (3+) as junk here.
    if (RegExp(r'^(.{8,}?)(\s*\1){2,}$', caseSensitive: false).hasMatch(t)) {
      return true;
    }
    return false;
  }

  Future<void> _runDirectAgent(String text, String turnId) async {
    final turnSpan = Span('turn_total');
    try {
      final local = await _tryTerminalIntent(text, turnId);
      if (local) return;

      final google = await _tryGoogleIntent(text, turnId);
      if (google) return;

      final googleData = await _tryGoogleDataIntent(text, turnId);
      if (googleData) return;

      final homeData = await _tryHomeDataIntent(text, turnId);
      if (homeData) return;

      final clipped =
          text.length > 500 ? '${text.substring(0, 500)}…' : text;
      logInfo('direct_agent', 'Calling voice agent', data: {
        'turn_id': turnId,
        'text': clipped,
        'mcp': session.mcpProvidersForVoice(utterance: text),
      });
      final response = await session.directVoice(text);
      if (response.trim().isEmpty) {
        logWarn('direct_agent_empty', 'AO returned empty reply', data: {
          'turn_id': turnId,
        });
        await _speakFallback(
          "I heard you, but I don't have a reply right now.",
          turnId,
        );
        return;
      }
      logInfo('direct_agent_ok', 'AO reply ready', data: {
        'turn_id': turnId,
        'chars': response.length,
        'preview': response.length > 80
            ? '${response.substring(0, 80)}…'
            : response,
      });
      final ttsSpan = Span('tts_total');
      final path = await tts.synthesizeToFile(response);
      _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
      ttsSpan.close();
      _noteSpeakDuration(path: path, text: response);
      final audioUrl = audioServer.registerFile(path);
      handle(ResponseReady(response, audioUrl));
    } catch (e) {
      logWarn('direct_agent_failed', e.toString(), data: {'turn_id': turnId});
      await _speakFallback(
        'Sorry, I could not get an answer in time.',
        turnId,
      );
    } finally {
      turnSpan.close();
    }
  }

  Future<bool> _tryHomeDataIntent(String text, String turnId) async {
    final intent = parseHomeDataIntent(text);
    if (intent == null) return false;
    if (!HaAgentClient.isConfigured) {
      // Fall through to AO HA MCP (may be slow / flaky).
      return false;
    }

    late final String? spoken;
    switch (intent.kind) {
      case HomeDataIntentKind.torrentsDownloading:
        spoken = await HaAgentClient().torrentsSpokenSummary();
    }
    if (spoken == null || spoken.trim().isEmpty) {
      logWarn('home_data_intent', 'HA agent returned empty', data: {
        'turn_id': turnId,
        'kind': intent.kind.name,
      });
      return false;
    }
    logInfo('home_data_intent', 'Answered from HA agent', data: {
      'turn_id': turnId,
      'kind': intent.kind.name,
      'chars': spoken.length,
    });
    await _speakText(spoken, turnId);
    return true;
  }

  Future<bool> _tryGoogleDataIntent(String text, String turnId) async {
    final intent = parseGoogleDataIntent(text);
    if (intent == null) return false;
    if (session.guest || session.userid == null) {
      await _speakText(
        'Google data is only available when I recognize you.',
        turnId,
      );
      return true;
    }
    if (!googleOAuth.isConfigured) {
      await _speakText('Google is not configured on this terminal yet.', turnId);
      return true;
    }
    final userid = session.userid!;
    final refresh = await googleTokens.readRefreshToken(userid);
    if (refresh == null || refresh.isEmpty) {
      await _speakText(
        'Google is not connected. Say connect my Google to link it.',
        turnId,
      );
      return true;
    }

    final clientId = Platform.environment['GOOGLE_CLIENT_ID']?.trim() ?? '';
    final clientSecret =
        Platform.environment['GOOGLE_CLIENT_SECRET']?.trim() ?? '';
    final kind = await googleTokens.readClientKind(userid);
    final deskId =
        Platform.environment['GOOGLE_DESKTOP_CLIENT_ID']?.trim() ?? '';
    final deskSecret =
        Platform.environment['GOOGLE_DESKTOP_CLIENT_SECRET']?.trim() ?? '';
    final useId = kind == GoogleOAuthClientKind.desktop && deskId.isNotEmpty
        ? deskId
        : clientId;
    final useSecret =
        kind == GoogleOAuthClientKind.desktop && deskSecret.isNotEmpty
            ? deskSecret
            : clientSecret;
    if (useId.isEmpty || useSecret.isEmpty) {
      await _speakText('Google OAuth client is not configured.', turnId);
      return true;
    }

    final gw = GoogleWorkspaceClient(
      clientId: useId,
      clientSecret: useSecret,
      refreshToken: refresh,
    );
    try {
      late final String spoken;
      switch (intent.kind) {
        case GoogleDataIntentKind.calendarToday:
          final titles = await gw.listTodayEventTitles();
          spoken = speakCalendarToday(titles);
        case GoogleDataIntentKind.calendarList:
          final names = await gw.listCalendarNames();
          spoken = speakCalendarList(names);
        case GoogleDataIntentKind.driveList:
          final n = await gw.countDriveFiles();
          spoken = speakDriveCount(n);
        case GoogleDataIntentKind.gmailToday:
          try {
            final subjects = await gw.listRecentGmailSubjects();
            spoken = speakGmailSubjects(subjects);
          } catch (e) {
            logWarn('google_gmail_read', e.toString());
            spoken =
                'Gmail is not authorized on this voice link. '
                'Calendar still works. Gmail needs a Desktop OAuth token.';
          }
      }
      logInfo('google_data_ok', 'Local Google read', data: {
        'turn_id': turnId,
        'kind': intent.kind.name,
        'chars': spoken.length,
        'preview': spoken.length > 160 ? '${spoken.substring(0, 160)}…' : spoken,
      });
      await _speakText(spoken, turnId);
      return true;
    } catch (e) {
      logWarn('google_data_failed', e.toString(), data: {
        'turn_id': turnId,
        'kind': intent.kind.name,
      });
      await _speakText(
        'I could not read that from Google right now. Try again in a moment.',
        turnId,
      );
      return true;
    } finally {
      gw.close();
    }
  }

  Future<bool> _tryGoogleIntent(String text, String turnId) async {
    final intent = parseGoogleIntent(text);
    if (intent == null) return false;

    if (session.guest || session.userid == null) {
      await _speakText(
        'Google linking is only available when I recognize you.',
        turnId,
      );
      return true;
    }

    final userid = session.userid!;
    switch (intent.kind) {
      case GoogleIntentKind.status:
        await _speakText(await _googleStatusSpeech(userid), turnId);
        return true;

      case GoogleIntentKind.cancel:
        if (!_googlePairingInFlight) {
          await _speakText(
            'There is no Google pairing in progress.',
            turnId,
          );
          return true;
        }
        _cancelGooglePairing(announce: false);
        await _speakText(
          'Okay, I cancelled Google pairing.',
          turnId,
        );
        return true;

      case GoogleIntentKind.unlink:
        final had = await googleTokens.hasTokens(userid);
        _cancelGooglePairing(announce: false);
        await googleTokens.clear(userid);
        _googlePhase = GooglePairingPhase.idle;
        _googleLastError = null;
        _googlePairingUserCode = null;
        _broadcastPairingUi(active: false);
        if (!had) {
          await _speakText(
            'Google was not connected.',
            turnId,
          );
          return true;
        }
        try {
          await session.close();
          await session.open(userid: userid, guest: false);
        } catch (e) {
          logWarn('google_unlink_session', e.toString());
        }
        await _speakText(
          'Okay, I disconnected and revoked Google for you.',
          turnId,
        );
        return true;

      case GoogleIntentKind.connect:
      case GoogleIntentKind.reconnect:
        if (!googleOAuth.isConfigured) {
          await _speakText(
            'Google is not configured on this terminal yet.',
            turnId,
          );
          return true;
        }
        final linked = await googleTokens.hasTokens(userid);
        if (linked && intent.kind == GoogleIntentKind.connect) {
          await _speakText(
            '${await _googleStatusSpeech(userid)} '
            'Say reconnect my Google to link again, or disconnect Google to remove it.',
            turnId,
          );
          return true;
        }
        if (_googlePairingInFlight) {
          await _speakText(
            'Google pairing is already in progress'
            '${_googlePairingUserCode != null ? ". The code is ${GoogleDevicePairing.speakableUserCode(_googlePairingUserCode!)}" : ""}. '
            'I will update you when it finishes, or say cancel connect to stop.',
            turnId,
          );
          return true;
        }
        await _startGooglePairing(userid, turnId);
        return true;
    }
  }

  bool get _googlePairingInFlight =>
      _googlePhase == GooglePairingPhase.awaitingUser ||
      _googlePhase == GooglePairingPhase.verifying;

  Future<String> _googleStatusSpeech(String userid) async {
    final has = await googleTokens.hasTokens(userid);
    final tools =
        session.mcpProvidersForVoice().contains('client.google_workspace');
    if (_googlePhase == GooglePairingPhase.awaitingUser) {
      final code = _googlePairingUserCode;
      return code == null
          ? 'I am still waiting for you to approve Google on your phone. '
              'Say cancel connect to stop.'
          : 'I am still waiting for Google approval. '
              'The code is ${GoogleDevicePairing.speakableUserCode(code)}. '
              'Say cancel connect to stop.';
    }
    if (_googlePhase == GooglePairingPhase.verifying) {
      return 'I got approval from Google and I am verifying the connection now. '
          'You will hear an update shortly.';
    }
    if (!has) {
      if (_googlePhase == GooglePairingPhase.failed &&
          (_googleLastError?.isNotEmpty ?? false)) {
        return 'Google is not connected. Last attempt failed: $_googleLastError. '
            'Say connect my Google to try again.';
      }
      return 'Google is not connected. Say connect my Google to link it.';
    }
    _googlePhase = GooglePairingPhase.linked;
    if (tools) {
      return 'Yes — your Google account is connected and Workspace tools are ready. '
          'I can help with calendar. Gmail needs a separate Desktop login.';
    }
    return 'Your Google account is linked on this terminal, but Workspace tools '
        'did not start cleanly. Calendar may be limited until that is fixed. '
        'Say reconnect my Google if you want to try again.';
  }

  /// Issues device code + QR, acknowledges, then polls in the background.
  Future<void> _startGooglePairing(String userid, String turnId) async {
    _cancelGooglePairing(announce: false);
    final cancel = Completer<void>();
    _googlePairingCancel = cancel;
    _googleLastError = null;

    try {
      final code = await googleOAuth.begin();
      _googlePhase = GooglePairingPhase.awaitingUser;
      _googlePairingUserCode = code.userCode;
      _broadcastPairingUi(
        active: true,
        phase: 'awaiting',
        url: code.verificationUrlComplete,
        userCode: code.userCode,
        qrSvg: qrSvg(code.verificationUrlComplete),
      );

      final spokenCode = GoogleDevicePairing.speakableUserCode(code.userCode);
      logInfo('google_pairing_start', 'Device code issued', data: {
        'userid': userid,
        'user_code': code.userCode,
      });
      await _speakText(
        'Open Google on your phone and enter code $spokenCode, '
        'or scan the QR on the screen. '
        'I will keep watching and let you know when it is done. '
        'Say cancel connect if you want to stop.',
        turnId,
      );
      unawaited(_finishGooglePairing(userid, code, cancel));
    } catch (e) {
      _googlePhase = GooglePairingPhase.failed;
      _googleLastError = _friendlyGoogleError(e.toString());
      _googlePairingUserCode = null;
      _broadcastPairingUi(active: false);
      if (_googlePairingCancel == cancel) {
        _googlePairingCancel = null;
      }
      logWarn('google_pairing_failed', e.toString(), data: {'userid': userid});
      await _speakText(
        'I could not start Google pairing. $_googleLastError',
        turnId,
      );
    }
  }

  Future<void> _finishGooglePairing(
    String userid,
    GoogleDeviceCode code,
    Completer<void> cancel,
  ) async {
    try {
      final result = await googleOAuth.waitForApproval(
        code,
        cancel: cancel.future,
      );
      if (_googlePairingCancel != cancel) return;

      switch (result.outcome) {
        case GooglePairingOutcome.cancelled:
          _googlePhase = GooglePairingPhase.idle;
          _googlePairingUserCode = null;
          _broadcastPairingUi(active: false);
          return;

        case GooglePairingOutcome.timeout:
          _googlePhase = GooglePairingPhase.failed;
          _googleLastError = 'pairing timed out';
          _googlePairingUserCode = null;
          _broadcastPairingUi(active: false);
          await _announceEngaged(
            'Google pairing timed out. Say connect my Google to try again.',
          );

        case GooglePairingOutcome.denied:
          _googlePhase = GooglePairingPhase.failed;
          _googleLastError = 'access was denied';
          _googlePairingUserCode = null;
          _broadcastPairingUi(active: false);
          await _announceEngaged(
            'Google access was denied. Say connect my Google if you change your mind.',
          );

        case GooglePairingOutcome.error:
          _googlePhase = GooglePairingPhase.failed;
          _googleLastError = result.message ?? 'unknown error';
          _googlePairingUserCode = null;
          _broadcastPairingUi(active: false);
          await _announceEngaged(
            'I could not finish Google pairing. $_googleLastError. '
            'Say connect my Google to try again.',
          );

        case GooglePairingOutcome.success:
          final refresh = result.tokens?.refreshToken;
          if (refresh == null || refresh.isEmpty) {
            _googlePhase = GooglePairingPhase.failed;
            _googleLastError = 'no refresh token returned';
            _googlePairingUserCode = null;
            _broadcastPairingUi(active: false);
            await _announceEngaged(
              'Google approved, but I did not get a refresh token. '
              'Say connect my Google to try again.',
            );
            return;
          }

          _googlePhase = GooglePairingPhase.verifying;
          _broadcastPairingUi(
            active: true,
            phase: 'verifying',
            userCode: code.userCode,
          );
          await _announceEngaged(
            'Got it from Google. I am verifying the connection and '
            'turning on Workspace tools. You will hear an update shortly.',
          );

          try {
            await googleTokens.writeRefreshToken(
              userid,
              refresh,
              client: GoogleOAuthClientKind.tv,
            );
            await session.close();
            await session.open(userid: userid, guest: false);
          } catch (e) {
            logWarn('google_pair_session', e.toString());
            _googlePhase = GooglePairingPhase.failed;
            _googleLastError = 'saved tokens but session refresh failed';
            _googlePairingUserCode = null;
            _broadcastPairingUi(active: false);
            await _announceEngaged(
              'I saved your Google login, but I could not refresh the session. '
              'Try walking away and back, or say reconnect my Google.',
            );
            return;
          }

          final ok = session.mcpProvidersForVoice()
              .contains('client.google_workspace');
          _googlePairingUserCode = null;
          _broadcastPairingUi(active: false);
          _googlePhase = GooglePairingPhase.linked;
          _googleLastError = ok ? null : 'Workspace tools failed to start';

          final offer = await googleDesktop.offerAfterTvPairing(
            userid: userid,
            accessToken: result.tokens?.accessToken,
          );
          if (offer.emailed) {
            await _announceEngaged(
              ok
                  ? 'Google calendar is connected. I emailed you a link to '
                      'enable Gmail and Drive — open it on your phone or computer.'
                  : 'Your Google account is linked, but Workspace tools did not '
                      'start. I still emailed you a link to finish Gmail and Drive.',
            );
            unawaited(_awaitDesktopUpgrade(offer));
          } else if (ok) {
            await _announceEngaged(
              'Google is connected. I can help with calendar and Drive files.',
            );
          } else {
            await _announceEngaged(
              'Your Google account is linked, but Workspace tools did not start '
              'on this terminal. Say check google for status, or reconnect my Google.',
            );
          }
      }
    } catch (e) {
      _googlePhase = GooglePairingPhase.failed;
      _googleLastError = _friendlyGoogleError(e.toString());
      _googlePairingUserCode = null;
      _broadcastPairingUi(active: false);
      logWarn('google_pairing_poll', e.toString(), data: {'userid': userid});
      await _announceEngaged(
        'I could not finish Google pairing. $_googleLastError',
      );
    } finally {
      if (_googlePairingCancel == cancel) {
        _googlePairingCancel = null;
      }
    }
  }

  Future<void> _awaitDesktopUpgrade(GoogleDesktopUpgradeOffer offer) async {
    final linked = await offer.done;
    if (!linked) {
      logInfo('google_desktop_upgrade_timeout', 'Desktop upgrade not completed');
      return;
    }
    final userid = session.userid;
    if (userid != null && !session.guest) {
      try {
        await session.close();
        await session.open(userid: userid, guest: false);
      } catch (e) {
        logWarn('google_desktop_session', e.toString());
      }
    }
    await _announceEngaged(
      'Gmail and Drive are linked now. You can ask me about your inbox or files.',
    );
  }

  void _cancelGooglePairing({bool announce = false}) {
    final c = _googlePairingCancel;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
    _googlePairingCancel = null;
    if (_googlePhase == GooglePairingPhase.awaitingUser ||
        _googlePhase == GooglePairingPhase.verifying) {
      _googlePhase = GooglePairingPhase.idle;
    }
    _googlePairingUserCode = null;
    _broadcastPairingUi(active: false);
    if (announce) {
      unawaited(
        _announceEngaged('Okay, I cancelled Google pairing.'),
      );
    }
  }

  void _broadcastPairingUi({
    required bool active,
    String phase = 'idle',
    String? url,
    String? userCode,
    String? qrSvg,
  }) {
    _broadcastKiosk(
      Envelope.create(
        type: 'pairing.qr',
        data: {
          'active': active,
          'phase': active ? phase : 'idle',
          if (url != null) 'url': url,
          if (userCode != null) 'userCode': userCode,
          if (qrSvg != null) 'qrSvg': qrSvg,
        },
      ),
    );
  }

  String _friendlyGoogleError(String raw) {
    if (raw.contains('invalid_scope')) {
      return 'Google rejected the permission list for this device login';
    }
    if (raw.contains('invalid_client')) {
      return 'Google OAuth client is misconfigured';
    }
    if (raw.contains('unauthorized_client')) {
      return 'This Google client cannot use device login';
    }
    final clipped = raw.replaceFirst(RegExp(r'^Bad state:\s*'), '');
    return clipped.length > 120 ? '${clipped.substring(0, 117)}…' : clipped;
  }

  /// Turn reply via the attention machine (must be in Responding).
  Future<void> _speakText(String spoken, String turnId) async {
    final ttsSpan = Span('tts_total');
    final path = await tts.synthesizeToFile(spoken);
    _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
    ttsSpan.close();
    _noteSpeakDuration(path: path, text: spoken);
    final audioUrl = audioServer.registerFile(path);
    handle(ResponseReady(spoken, audioUrl));
  }

  /// Greeter-style announce while Engaged (pairing outcome after the turn).
  Future<void> _announceEngaged(String spoken) async {
    try {
      machine.context.playing = true;
      _followUpGen++;
      _followUpTimer?.cancel();
      _followUpTimer = null;
      machine.context.followUpListening = false;
      _sendAudio(Envelope.create(type: 'listen.stop'));
      _sendAudio(
        Envelope.create(type: 'wake.enable', data: {'enabled': false}),
      );
      _broadcastKiosk(
        Envelope.create(type: 'listening', data: {'active': false}),
      );
      final ttsSpan = Span('tts_total');
      final path = await tts.synthesizeToFile(spoken);
      _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
      ttsSpan.close();
      _noteSpeakDuration(path: path, text: spoken);
      final audioUrl = audioServer.registerFile(path);
      _beginSpeakWatchdog();
      _broadcastPhase('speaking', detail: spoken);
      _broadcastKiosk(
        Envelope.create(
          type: 'speak',
          data: {'text': spoken, 'audioUrl': audioUrl},
        ),
      );
      unawaited(_maybePlayLocal(audioUrl));
    } catch (e) {
      logWarn('google_announce', e.toString());
      machine.context.playing = false;
      _sendAudio(
        Envelope.create(type: 'wake.enable', data: {'enabled': true}),
      );
    }
  }

  /// Sleep / volume without AO MCP (tunnelled client.terminal hangs tool load).
  Future<bool> _tryTerminalIntent(String text, String turnId) async {
    final intent = parseTerminalIntent(text);
    if (intent == null) return false;

    late final Map<String, dynamic> result;
    late final String spoken;
    switch (intent.kind) {
      case TerminalIntentKind.sleepEnter:
        handle(const EnterSleep());
        result = control.sleepStatus();
        spoken = 'Okay, going to sleep. Say hey comstar when you need me.';
      case TerminalIntentKind.volumeMute:
        result = control.volumeMute(true);
        spoken = result['ok'] == true
            ? 'Okay, I muted the speaker.'
            : 'I could not mute the speaker.';
      case TerminalIntentKind.volumeUnmute:
        result = control.volumeMute(false);
        spoken = result['ok'] == true
            ? 'Okay, speaker unmuted.'
            : 'I could not unmute the speaker.';
      case TerminalIntentKind.volumeUp:
        result = control.volumeAdjust(intent.delta ?? 10);
        spoken = result['ok'] == true
            ? 'Volume is now ${result['percent']} percent.'
            : 'I could not change the volume.';
      case TerminalIntentKind.volumeDown:
        result = control.volumeAdjust(intent.delta ?? -10);
        spoken = result['ok'] == true
            ? 'Volume is now ${result['percent']} percent.'
            : 'I could not change the volume.';
      case TerminalIntentKind.volumeSet:
        result = control.volumeSet(intent.percent ?? 50);
        spoken = result['ok'] == true
            ? 'Volume set to ${result['percent']} percent.'
            : 'I could not set the volume.';
    }

    logInfo('terminal_intent', 'Handled device control locally', data: {
      'turn_id': turnId,
      'kind': intent.kind.name,
      'result': result,
    });

    final ttsSpan = Span('tts_total');
    final path = await tts.synthesizeToFile(spoken);
    _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
    ttsSpan.close();
    _noteSpeakDuration(path: path, text: spoken);
    final audioUrl = audioServer.registerFile(path);
    handle(ResponseReady(spoken, audioUrl));
    return true;
  }

  Future<void> _runGreeterAfterSession(String userid) async {
    final pending = _sessionOpenFuture;
    if (pending != null) {
      try {
        await pending;
      } catch (e) {
        logWarn('session_open_failed', e.toString(), data: {'userid': userid});
        return;
      }
    } else if (!session.isOpen) {
      try {
        await session.open(userid: userid, guest: false);
      } catch (e) {
        logWarn('session_open_failed', e.toString(), data: {'userid': userid});
        return;
      }
    }
    await _runGreeter(userid);
  }

  Future<void> _runGreeter(String userid) async {
    try {
      final cached = _greetingCache[userid];
      final greeting = cached ?? await session.runGreeter(userid);
      if (greeting.trim().isEmpty) return;
      _greetingCache[userid] = greeting;

      // Half-duplex: mute wake while greeting plays.
      machine.context.playing = true;
      _followUpGen++;
      _sendAudio(Envelope.create(type: 'listen.stop'));
      _sendAudio(
        Envelope.create(type: 'wake.enable', data: {'enabled': false}),
      );
      final ttsSpan = Span('tts_total');
      final path = await tts.synthesizeToFile(greeting);
      _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
      ttsSpan.close();
      _noteSpeakDuration(path: path, text: greeting);
      final audioUrl = audioServer.registerFile(path);
      _beginSpeakWatchdog();
      _broadcastKiosk(
        Envelope.create(
          type: 'speak',
          data: {'text': greeting, 'audioUrl': audioUrl},
        ),
      );
      unawaited(_maybePlayLocal(audioUrl));
    } catch (e) {
      logWarn('greeter_failed', e.toString(), data: {'userid': userid});
      machine.context.playing = false;
      _sendAudio(
        Envelope.create(type: 'wake.enable', data: {'enabled': true}),
      );
    }
  }

  Future<void> _speakFallback(String line, String turnId) async {
    final canned = _lookupFallbackWav(line);
    final path = canned ?? await tts.synthesizeToFile(line);
    _noteSpeakDuration(path: path, text: line);
    final audioUrl = audioServer.registerFile(path);
    handle(ResponseReady(line, audioUrl));
  }

  String? _lookupFallbackWav(String line) {
    final dir = fallbackAudioDir;
    if (dir == null) return null;
    final lower = line.toLowerCase();
    final name = lower.contains('offline') || lower.contains('network')
        ? 'offline.wav'
        : lower.contains('sorry') || lower.contains('could not')
            ? 'sorry.wav'
            : 'error.wav';
    final path = p.join(dir, name);
    if (File(path).existsSync()) return path;
    return null;
  }

  Future<void> _maybePlayLocal(String audioUrl) async {
    // Prefer kiosk playback. Local paplay is fallback only — never both
    // (dual path echoes on the same HDMI sink).
    if (ws.hasRole('kiosk')) return;
    final allowLocal = Platform.environment['COMSTAR_LOCAL_SPEAKER'] == '1';
    if (!allowLocal) return;
    final path = audioServer.filePathForUrl(audioUrl);
    if (path == null) return;
    final sink = speakerSource();
    try {
      final paplayArgs = <String>[
        if (sink != null) ...['--device=$sink'],
        path,
      ];
      final paplay = await Process.run('paplay', paplayArgs);
      if (paplay.exitCode == 0) {
        logInfo('local_speaker', 'Played via paplay', data: {
          'path': path,
          'speaker_source': sink ?? 'default',
        });
        // Synthetic speak.ended if kiosk absent so follow-up can open.
        if (!ws.hasRole('kiosk')) {
          _cancelSpeakWatchdog();
          handle(const PlaybackEnded());
        }
        return;
      }
      final aplayArgs = <String>[
        if (sink != null) ...['-D', sink],
        path,
      ];
      final aplay = await Process.run('aplay', aplayArgs);
      if (aplay.exitCode == 0) {
        logInfo('local_speaker', 'Played via aplay', data: {
          'path': path,
          'speaker_source': sink ?? 'default',
        });
        if (!ws.hasRole('kiosk')) {
          _cancelSpeakWatchdog();
          handle(const PlaybackEnded());
        }
        return;
      }
      logWarn('local_speaker_failed', 'paplay/aplay failed', data: {
        'paplay': paplay.exitCode,
        'aplay': aplay.exitCode,
        'speaker_source': sink ?? 'default',
      });
    } catch (e) {
      logWarn('local_speaker_failed', e.toString());
    }
  }

  void _sendAudio(Envelope envelope) {
    final channel = _audioChannel;
    if (channel == null) {
      ws.sendToRole('audio', envelope);
      return;
    }
    try {
      channel.sink.add(envelope.encode());
    } on Object catch (e) {
      logWarn('audio_send_failed', e.toString());
    }
  }

  void _broadcastPhase(String phase, {String detail = ''}) {
    _broadcastKiosk(
      Envelope.create(
        type: 'phase',
        data: {
          'phase': phase,
          if (detail.isNotEmpty) 'detail': detail,
        },
      ),
    );
  }

  /// Push attention state + phase so a (re)connected kiosk matches the machine.
  void _syncKioskAttention() {
    final stateName = machine.state.name;
    _broadcastKiosk(
      Envelope.create(
        type: 'state',
        data: {
          'state': stateName,
          if (machine.context.cachedUserid != null)
            'userid': machine.context.cachedUserid,
          if (machine.context.cachedDisplayName != null)
            'displayName': machine.context.cachedDisplayName,
        },
      ),
    );
    switch (stateName) {
      case 'noticed':
        _broadcastPhase('noticed', detail: 'I see you…');
      case 'listening':
        _broadcastPhase('listening', detail: 'Listening…');
      case 'responding':
        break;
      case 'engaged':
        _broadcastPhase(
          'engaged',
          detail: machine.context.cachedDisplayName ??
              machine.context.cachedUserid ??
              '',
        );
      case 'ambient':
        _broadcastPhase('idle', detail: '');
      case 'sleeping':
        _broadcastPhase('sleeping', detail: 'Sleeping…');
      default:
        break;
    }
  }

  void _broadcastKiosk(Envelope envelope) {
    ws.sendToRole('kiosk', envelope);
  }
}
