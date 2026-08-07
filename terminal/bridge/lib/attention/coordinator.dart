import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:comstar_bridge/announce/gate.dart';
import 'package:comstar_bridge/announce/service.dart';
import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/effects.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:comstar_bridge/attention/machine.dart';
import 'package:comstar_bridge/attention/runner.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/clock_intent.dart';
import 'package:comstar_bridge/conversation_memory.dart';
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
import 'package:comstar_bridge/house_presence.dart';
import 'package:comstar_bridge/presence_location_service.dart';
import 'package:comstar_bridge/http_audio_server.dart';
import 'package:comstar_bridge/sentiment.dart';
import 'package:comstar_bridge/local_ws.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/phrase_bank.dart';
import 'package:comstar_bridge/session.dart';
import 'package:comstar_bridge/social_intent.dart';
import 'package:comstar_bridge/spoken_language.dart';
import 'package:comstar_bridge/stt.dart';
import 'package:comstar_bridge/utterance_gate.dart';
import 'package:comstar_bridge/admin_ops.dart';
import 'package:comstar_bridge/heal_summary.dart';
import 'package:comstar_bridge/identity_intent.dart';
import 'package:comstar_bridge/terminal_control.dart';
import 'package:comstar_bridge/terminal_intent.dart';
import 'package:comstar_bridge/tts.dart';
import 'package:comstar_bridge/vision_mcp_client.dart';
import 'package:comstar_bridge/vision_visit_intent.dart';
import 'package:comstar_bridge/wake_phrase.dart';
import 'package:comstar_bridge/wav_duration.dart';
import 'package:comstar_bridge/net/service.dart';
import 'package:comstar_bridge/working_ack.dart';
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
    ConversationMemory? conversationMemory,
    this.network,
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
        conversationMemory =
            conversationMemory ?? ConversationMemory.fromConfig(config),
        machine = AttentionMachine(
          config: config,
          clock: clock ?? SystemClock(),
        ),
        runner = EffectRunner() {
    phraseBank = PhraseBank();
    phraseBank.load();
    this.control.loadPersistedVolume();
    audioServer.control = this.control;
    audioServer.onSleepAction = _onSleepHttp;
    audioServer.onAvatarOptions = applyAvatarOptions;
  }

  final ComstarConfig config;
  final LocalWs ws;
  final NetworkService? network;
  final ComstarSession session;
  final SttClient stt;
  final TtsEngine tts;
  final HttpAudioServer audioServer;
  final TerminalControl control;
  final GoogleTokenStore googleTokens;
  final GoogleDevicePairing googleOAuth;
  final GoogleDesktopUpgrade googleDesktop;
  final DirectoryResolver directory;
  final ConversationMemory conversationMemory;
  final Clock clock;
  AnnounceService? announce;

  /// Snapshot for local health checks / auto-heal (inject `/health`).
  Map<String, Object?> healthStatus() => {
        'ok': true,
        'state': machine.state.name,
        'session_flag': machine.context.sessionOpen,
        'reach_active': session.isOpen,
        'session_open': machine.context.sessionOpen && session.isOpen,
        'userid': session.userid,
        'guest': session.guest,
        'wake_enabled': machine.context.wakeEnabled,
        'playing': machine.context.playing,
        'followup_listening': machine.context.followUpListening,
        'kiosk_connected': ws.hasRole('kiosk'),
        'audio_connected': ws.hasRole('audio'),
        'sleeping': machine.state is Sleeping,
        'announce': announce != null,
        'phrase_bank': {
          for (final c in PhraseCategory.all) c: phraseBank.count(c),
          'updated_at': phraseBank.updatedAt?.toUtc().toIso8601String(),
        },
        'memory': {
          'enabled': conversationMemory.enabled,
          'userid': _memoryUserid,
        },
      };
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

  /// Last successful where-is / leave person for pronoun follow-ups ("when did they leave?").
  String? _lastPresencePersonName;

  final _captureBuffer = BytesBuilder(); // copy:true — toBytes() must not wipe PCM
  var _capturePeakRms = 0.0;
  var _loudFrameCount = 0;
  var _totalFrameCount = 0;
  var _deferRestartCount = 0;
  var _lastDeferRestartAtMs = 0;

  var _captureSampleRate = 16000;
  WebSocketChannel? _audioChannel;
  late final PhraseBank phraseBank;
  Timer? _phraseRefreshTimer;
  var _phraseRefreshInFlight = false;
  DateTime? _speakStartedAt;
  Duration? _lastTtsTotal;
  /// WAV (or text-estimate) play length for the in-flight speak — not TTS synth time.
  int _lastSpeakDurationMs = 3000;

  /// One-shot "working on it" while AO is slow (see [shouldArmWorkingAck]).
  Timer? _workingAckTimer;
  String? _workingAckSpokenTurnId;
  Completer<void>? _workingAckPlayback;

  /// Wait for the current speak to finish (speak.ended / watchdog / local play).
  Completer<void>? _playbackWait;

  /// Force-wake while Sleeping: capture + STT must match hey/hello comstar.
  var _sleepWakeVerifyInFlight = false;
  double _sleepWakeScore = 0.8;
  Timer? _sleepWakeTimer;
  Timer? _adminQrTimer;
  bool _kioskWantsAdminQr = false;
  var _sleepWakeRestartCount = 0;
  var _sleepWakeRestarting = false;
  var _announceTickCounter = 0;

  Future<void> start({vision.VisionPoller? visionPoller}) async {
    await audioServer.start();
    if (config.announce.enabled) {
      announce = AnnounceService(
        config: config,
        machine: machine,
        onEvent: handle,
      )..start();
    }
    _tickTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => handle(const Tick()),
    );
    if (visionPoller != null) {
      _visionPoller = visionPoller;
      await visionPoller.start();
      _visionSub = visionPoller.events.listen(_onVisionEvent);
    }
    _armPhraseBankRefresh();
  }

  Future<void> stop() async {
    _tickTimer?.cancel();
    _tickTimer = null;
    _phraseRefreshTimer?.cancel();
    _phraseRefreshTimer = null;
    _cancelSpeakWatchdog();
    _followUpTimer?.cancel();
    _followUpTimer = null;
    _cancelSleepWakeVerify(stopListen: true);
    await announce?.stop();
    announce = null;
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
      if (envelope.type == 'ready') {
        // Audio reconnect defaults wake_enabled=true locally; sync from machine.
        _syncAudioWakeGate();
      }
      _handleAudioEnvelope(envelope);
      return;
    }
    if (role == 'kiosk') {
      _handleKioskEnvelope(envelope);
    }
  }

  void _syncAudioWakeGate() {
    final halfMute = machine.context.halfDuplex && machine.context.playing;
    final enabled = machine.context.wakeEnabled && !halfMute;
    _sendAudio(
      Envelope.create(type: 'wake.enable', data: {'enabled': enabled}),
    );
    logInfo('wake_sync', 'Synced wake gate to audio', data: {
      'enabled': enabled,
      'state': machine.state.name,
      'playing': machine.context.playing,
      'duplex': config.audio.duplex,
    });
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
    if (event is Tick) {
      _announceTickCounter++;
      // ~1 Hz gate evaluation while engaged and idle.
      if (_announceTickCounter % 10 == 0 &&
          machine.state is Engaged &&
          !machine.context.playing &&
          !machine.context.announcedThisEngage) {
        unawaited(announce?.evaluateAndMaybeDeliver());
      }
    }
  }

  void _handleEffect(Effect effect) {
    switch (effect) {
      case SetVisionFps(:final fps):
        _visionPoller?.setTargetFps(fps);
        final id = _visionPoller?.identity;
        if (id != null) {
          final engagedLike = machine.state is Engaged ||
              machine.state is Listening ||
              machine.state is Responding ||
              machine.state is Noticed;
          id.continuousRecognize =
              fps >= config.vision.engagedFps - 0.001 ||
                  (machine.context.personPresent && engagedLike);
        }
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
      case Speak(:final text, :final audioUrl, :final turnId, :final mood):
        if (audioUrl.startsWith('announce://')) {
          unawaited(_speakAnnouncementText(text, turnId, mood));
          break;
        }
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
        if (machine.context.halfDuplex) {
          _sendAudio(
            Envelope.create(type: 'wake.enable', data: {'enabled': false}),
          );
        }
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
        final speakMood = resolveSpeakMood(text, explicit: mood);
        if (text.trim().isNotEmpty) {
          logInfo('speak', 'Sending reply to kiosk', data: {
            'turn_id': turnId,
            'chars': text.length,
            'audioUrl': audioUrl,
            'mood': speakMood,
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
              'mood': speakMood,
              if (sleepAck) 'keepSleeping': true,
              ..._kioskSpeakAudioFlags(),
            },
          ),
        );
        unawaited(_maybePlayLocal(audioUrl));
      case CancelSpeak():
        _cancelSpeakWatchdog();
        machine.context.playing = false;
        _broadcastKiosk(Envelope.create(type: 'speak.cancel', data: {}));
        _sendAudio(Envelope.create(type: 'listen.stop'));
        logInfo('barge_in', 'Cancelled speak for full-duplex barge-in');
      case EmitPresence(:final people, :final primaryUserid):
        logInfo('presence_set', 'Terminal presence updated', data: {
          'count': people.length,
          'primary': primaryUserid,
          'people': people,
        });
      case SpeakFallback(:final line, :final turnId):
        unawaited(_speakFallback(line, turnId));
      case PlayErrorTone():
        _sendAudio(Envelope.create(type: 'play', data: {'tone': 'error'}));
      case EnableWake(:final enabled):
        _sendAudio(
          Envelope.create(type: 'wake.enable', data: {'enabled': enabled}),
        );
      case OpenFollowUpWindow(:final settleMs):
        _openFollowUpWindow(settleMs: settleMs);
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

  void _openFollowUpWindow({int settleMs = 1500}) {
    final seconds = config.audio.followupWindowSeconds;
    final gen = ++_followUpGen;
    logInfo('followup', 'Follow-up window opened', data: {
      'seconds': seconds,
      'settle_ms': settleMs,
    });
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
    // Keep force-wake muted until settle (TTS echo) completes.
    _sendAudio(
      Envelope.create(type: 'wake.enable', data: {'enabled': false}),
    );
    _sendAudio(Envelope.create(type: 'listen.stop'));
    void armMic() {
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
    }

    // Delay mic start after TTS so the first VAD speech_start cannot race the
    // arm window. After sleep wake, settleMs is 0 — arm on next microtask so we
    // are not nested inside WakeWord effect dispatch.
    if (settleMs <= 0) {
      scheduleMicrotask(armMic);
    } else {
      Future<void>.delayed(Duration(milliseconds: settleMs), armMic);
    }
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
          if (machine.context.playing) {
            logInfo('sleep_wake_ignored', 'Energy wake while TTS playing', data: {
              'score': score,
              'model': model,
            });
            break;
          }
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
          // Pre-roll counts toward maxMs in the streamer — leave headroom so
          // we still capture ~4s of live audio after the energy spike (TV ads
          // were ending verify in ~2s with only commercial in the buffer).
          'maxMs': 7500,
          'preRollMs': 2500,
          // VAD starts after pre-roll flush so silence after "hey comstar" ends.
          'vadSettleMs': 2600,
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
            'maxMs': 7500,
            'preRollMs': 2500,
            'vadSettleMs': 2600,
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
        final residual = residualAfterWakePhrase(text).trim();
        // Machine exits sleep. With a residual prompt, run it as the turn
        // (no empty follow-up listen / sleep-wake greeting).
        handle(WakeWord(score, prompt: residual.isEmpty ? null : residual));
        if (residual.isEmpty) {
          // Defer greeting until mic is armed so we do not cancel follow-up gen.
          unawaited(_speakSleepWakeLineWhenReady());
        }
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
    // Reject / abort paths mute wake for verify; restore after a short cooldown
    // so continuous TV energy cannot immediately re-enter sleep-verify.
    if (machine.state is Sleeping && !machine.context.playing) {
      Timer(const Duration(milliseconds: 2500), () {
        if (machine.state is! Sleeping || machine.context.playing) return;
        if (_sleepWakeVerifyInFlight) return;
        machine.context.wakeEnabled = true;
        _sendAudio(
          Envelope.create(type: 'wake.enable', data: {'enabled': true}),
        );
      });
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
        final debugUi = envelope.data['debugUi'] == true ||
            Platform.environment['COMSTAR_ENV'] == 'dev';
        _kioskWantsAdminQr = debugUi;
        unawaited(_refreshAdminQr(force: true));
        _adminQrTimer?.cancel();
        if (debugUi) {
          _adminQrTimer = Timer.periodic(
            const Duration(seconds: 30),
            (_) => unawaited(_refreshAdminQr()),
          );
        } else {
          _broadcastKiosk(
            Envelope.create(type: 'admin.qr', data: {'active': false}),
          );
        }
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
        // Progress line while still working (AO working-ack or heal check).
        final holdingReply = machine.state is Responding &&
            machine.context.directAgentInFlight;
        final alreadyFollowUp = machine.context.followUpListening ||
            machine.context.followUpOpen;
        final micNeverArmed = machine.context.followUpMicArmedAtMs == null;
        handle(const PlaybackEnded());
        _signalPlaybackDone();
        if (holdingReply) {
          _completeWorkingAckPlayback();
          // Keep thinking UI; do not open follow-up until the final reply.
          _broadcastKiosk(
            Envelope.create(type: 'thinking', data: {'active': true}),
          );
          _broadcastPhase('thinking', detail: 'Working…');
          break;
        }
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
          _syncAudioWakeGate();
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
      final holdingReply = machine.state is Responding &&
          machine.context.directAgentInFlight;
      // Greeter speaks while Engaged — mirror speak.ended wake restore.
      if (machine.state is! Responding) {
        _sendAudio(
          Envelope.create(type: 'wake.enable', data: {'enabled': true}),
        );
      }
      handle(const PlaybackEnded());
      _signalPlaybackDone();
      if (holdingReply) {
        _completeWorkingAckPlayback();
        _broadcastKiosk(
          Envelope.create(type: 'thinking', data: {'active': true}),
        );
        _broadcastPhase('thinking', detail: 'Working…');
      }
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
        _broadcastPhase('missed', detail: "Didn't catch that — try again");
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

  /// CrewAI / AO tool-loop stalls that must not be spoken aloud.
  bool _looksLikeToolStallProse(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return false;
    return t.contains('provide the tool result') ||
        t.contains('tool result for analysis') ||
        t.contains('waiting for the tool') ||
        t.contains('need the tool output') ||
        t.contains('share the tool result');
  }

  Future<void> _runDirectAgent(String text, String turnId) async {
    final turnSpan = Span('turn_total');
    try {
      final local = await _tryTerminalIntent(text, turnId);
      if (local) return;

      final identity = await _tryIdentityIntent(text, turnId);
      if (identity) return;

      final clock = await _tryClockIntent(text, turnId);
      if (clock) return;

      final social = await _trySocialIntent(text, turnId);
      if (social) return;

      final google = await _tryGoogleIntent(text, turnId);
      if (google) return;

      final googleData = await _tryGoogleDataIntent(text, turnId);
      if (googleData) return;

      final homeData = await _tryHomeDataIntent(text, turnId);
      if (homeData) return;

      final visionVisit = await _tryVisionVisitIntent(text, turnId);
      if (visionVisit) return;

      final mcp = session.mcpProvidersForVoice(utterance: text);
      final clipped =
          text.length > 500 ? '${text.substring(0, 500)}…' : text;
      final memoryUser = _memoryUserid;
      final agentText = memoryUser != null
          ? await conversationMemory.wrapForAgent(memoryUser, text)
          : text;
      logInfo('direct_agent', 'Calling voice agent', data: {
        'turn_id': turnId,
        'text': clipped,
        'memory': memoryUser != null,
        'mcp': mcp,
      });
      _armWorkingAck(turnId: turnId, mcpProviders: mcp, utterance: text);
      var response = await session.directVoice(agentText);
      _cancelWorkingAckTimer();
      if (_looksLikeToolStallProse(response)) {
        logWarn('direct_agent_tool_stall', 'AO returned tool-loop stall prose', data: {
          'turn_id': turnId,
          'preview': response.length > 80
              ? '${response.substring(0, 80)}…'
              : response,
        });
        // Prefer real HA entity reads over speaking stall text.
        final haFallback = await _tryHomeDataIntent(text, turnId);
        if (haFallback) return;
        await _speakFallback(
          "I reached Home Assistant, but didn't get a usable reading back.",
          turnId,
        );
        return;
      }
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
      if (shouldRejectForeignScriptReply(response)) {
        logWarn('direct_agent_foreign_script', 'AO reply not English — speaking fallback', data: {
          'turn_id': turnId,
          'preview': response.length > 80
              ? '${response.substring(0, 80)}…'
              : response,
        });
        await _speakFallback(
          "I got a garbled reply — try that again in a moment.",
          turnId,
        );
        return;
      }
      final ackSpoken = _workingAckSpokenTurnId == turnId;
      if (ackSpoken) {
        await _awaitWorkingAckPlayback();
        final preface = _phraseFor(
          PhraseCategory.resultReady,
          fallback: 'I have what you asked for.',
        );
        response = prefixResultReady(response, preface: preface);
      }
      logInfo('direct_agent_ok', 'AO reply ready', data: {
        'turn_id': turnId,
        'chars': response.length,
        'working_ack': ackSpoken,
        'preview': response.length > 80
            ? '${response.substring(0, 80)}…'
            : response,
      });
      unawaited(_rememberExchange(userText: text, assistantText: response));
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
      _cancelWorkingAckTimer();
      turnSpan.close();
    }
  }

  void _armWorkingAck({
    required String turnId,
    required List<String> mcpProviders,
    required String utterance,
  }) {
    _cancelWorkingAckTimer();
    if (_workingAckSpokenTurnId == turnId) return;
    if (!shouldArmWorkingAck(
      mcpProviders: mcpProviders,
      workingAckOnTools: config.attention.workingAckOnTools,
      workingAckMs: config.attention.workingAckMs,
      utterance: utterance,
    )) {
      return;
    }
    final delayMs = config.attention.workingAckMs;
    _workingAckTimer = Timer(Duration(milliseconds: delayMs), () {
      if (machine.context.turnId != turnId) return;
      if (!machine.context.directAgentInFlight) return;
      if (machine.state is! Responding) return;
      unawaited(_speakWorkingAck(turnId));
    });
  }

  void _cancelWorkingAckTimer() {
    _workingAckTimer?.cancel();
    _workingAckTimer = null;
  }

  void _completeWorkingAckPlayback() {
    final c = _workingAckPlayback;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> _awaitWorkingAckPlayback() async {
    final c = _workingAckPlayback;
    if (c == null || c.isCompleted) return;
    try {
      await c.future.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      logWarn('working_ack_wait', 'Timed out waiting for working-ack playback');
      _completeWorkingAckPlayback();
    }
  }

  /// One-shot progress line while AO is still in flight. Does not complete the
  /// turn; [PlaybackEnded] for this speak is ignored for follow-up while
  /// `directAgentInFlight` remains true.
  Future<void> _speakWorkingAck(String turnId) async {
    if (_workingAckSpokenTurnId == turnId) return;
    if (!machine.context.directAgentInFlight) return;
    if (machine.state is! Responding) return;
    if (machine.context.turnId != turnId) return;

    final line = _phraseFor(
      PhraseCategory.working,
      fallback: 'Working on that — it might take a minute.',
    );
    _workingAckSpokenTurnId = turnId;
    _workingAckPlayback = Completer<void>();
    logInfo('working_ack', 'Speaking progress ack', data: {
      'turn_id': turnId,
      'text': line,
    });
    try {
      machine.context.playing = true;
      final ttsSpan = Span('tts_total');
      final path = await tts.synthesizeToFile(line);
      _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
      ttsSpan.close();
      if (!machine.context.directAgentInFlight ||
          machine.context.turnId != turnId) {
        _completeWorkingAckPlayback();
        return;
      }
      _noteSpeakDuration(path: path, text: line);
      final audioUrl = audioServer.registerFile(path);
      _beginSpeakWatchdog();
      _broadcastPhase('speaking', detail: line);
      _broadcastKiosk(
        Envelope.create(
          type: 'speak',
          turnId: turnId,
          data: {
            'text': line,
            'audioUrl': audioUrl,
            ..._kioskSpeakAudioFlags(),
          },
        ),
      );
      unawaited(_maybePlayLocal(audioUrl));
      _rememberSpoken(line);
    } catch (e) {
      logWarn('working_ack_failed', e.toString(), data: {'turn_id': turnId});
      machine.context.playing = false;
      _completeWorkingAckPlayback();
    }
  }

  String? get _memoryUserid {
    if (session.guest) return null;
    final id = session.userid ?? machine.context.cachedUserid;
    return ConversationMemory.isMemoryUser(id) ? id : null;
  }

  Future<void> _rememberExchange({
    required String userText,
    required String assistantText,
  }) async {
    final uid = _memoryUserid;
    if (uid == null) return;
    try {
      await conversationMemory.recordExchange(
        userid: uid,
        userText: userText,
        assistantText: assistantText,
      );
    } catch (e) {
      logWarn('memory_record_failed', e.toString());
    }
  }

  /// Log any spoken COMSTAR line into rolling conversation memory.
  ///
  /// [userText] may be empty for unsolicited lines (greeter, sleep-wake).
  void _rememberSpoken(String spoken, {String userText = ''}) {
    final text = spoken.trim();
    if (text.isEmpty) return;
    unawaited(
      _rememberExchange(userText: userText, assistantText: text),
    );
  }

  /// Frigate visitor history / last-seen via Ada vision MCP HTTP — not AO/qwen.
  /// Qwen invents names from conversation memory (e.g. Adna ← Zlatko times).
  Future<bool> _tryVisionVisitIntent(String text, String turnId) async {
    final intent = parseVisionVisitIntent(text);
    if (intent == null) return false;
    if (!VisionMcpClient.isConfigured) {
      // Fall through to AO vision_comstar (flaky tool calling).
      return false;
    }

    _armWorkingAck(
      turnId: turnId,
      mcpProviders: const ['vision_comstar'],
      utterance: text,
    );
    final client = VisionMcpClient();
    try {
      final String? hint;
      switch (intent.kind) {
        case VisionVisitIntentKind.whoVisited:
          hint = await client.whoVisitedSpoken(
            camera: intent.camera,
            since: intent.since,
          );
        case VisionVisitIntentKind.personLastSeen:
          final name = intent.personName?.trim() ?? '';
          if (name.isEmpty) {
            _cancelWorkingAckTimer();
            return false;
          }
          hint = await client.personLastSeenSpoken(
            name: name,
            since: intent.since,
            camera: intent.camera.isEmpty ? null : intent.camera,
          );
      }
      _cancelWorkingAckTimer();
      if (hint == null || hint.trim().isEmpty) {
        logWarn('vision_visit_intent', 'vision tool empty', data: {
          'turn_id': turnId,
          'kind': intent.kind.name,
          'camera': intent.camera,
          'since': intent.since,
          'name': intent.personName,
        });
        return false;
      }
      var spoken = clipSpokenHint(hint);
      final ackSpoken = _workingAckSpokenTurnId == turnId;
      if (ackSpoken) {
        await _awaitWorkingAckPlayback();
        final preface = _phraseFor(
          PhraseCategory.resultReady,
          fallback: 'I have what you asked for.',
        );
        spoken = prefixResultReady(spoken, preface: preface);
      }
      logInfo('vision_visit_ok', 'Answered from vision MCP', data: {
        'turn_id': turnId,
        'kind': intent.kind.name,
        'camera': intent.camera,
        'since': intent.since,
        'name': intent.personName,
        'chars': spoken.length,
        'working_ack': ackSpoken,
        'preview': spoken.length > 160 ? '${spoken.substring(0, 160)}…' : spoken,
      });
      await _speakText(spoken, turnId, rememberUserText: text);
      return true;
    } catch (e) {
      _cancelWorkingAckTimer();
      logWarn('vision_visit_failed', e.toString(), data: {
        'turn_id': turnId,
        'kind': intent.kind.name,
        'camera': intent.camera,
        'since': intent.since,
        'name': intent.personName,
      });
      return false;
    } finally {
      client.close();
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
      case HomeDataIntentKind.irrigationSummary:
        spoken = await HaAgentClient().irrigationSpokenSummary();
      case HomeDataIntentKind.networkSummary:
        spoken = await HaAgentClient()
            .networkSpokenSummary(query: intent.query);
      case HomeDataIntentKind.presenceHome:
        spoken = await HousePresenceService(
          config: config.presence,
          clock: clock,
        ).spokenSummary();
      case HomeDataIntentKind.whereIsPerson:
        spoken = await _spokenWhereIsPerson(intent.personName);
      case HomeDataIntentKind.whenPersonLeft:
        spoken = await _spokenWhenPersonLeft(intent.personName);
    }
    if (spoken == null || spoken.trim().isEmpty) {
      logWarn('home_data_intent', 'HA agent returned empty', data: {
        'turn_id': turnId,
        'kind': intent.kind.name,
        if (intent.personName != null) 'name': intent.personName,
      });
      return false;
    }
    logInfo('home_data_intent', 'Answered from HA agent', data: {
      'turn_id': turnId,
      'kind': intent.kind.name,
      if (intent.personName != null) 'name': intent.personName,
      'chars': spoken.length,
      'preview': spoken.length > 160 ? '${spoken.substring(0, 160)}…' : spoken,
    });
    await _speakText(spoken, turnId, rememberUserText: text);
    return true;
  }

  /// HA person location first; Frigate last-seen when live location is unknown.
  Future<String?> _spokenWhereIsPerson(String? nameQuery) async {
    final name = (nameQuery ?? _lastPresencePersonName)?.trim() ?? '';
    if (name.isEmpty) {
      return 'Who should I look up?';
    }
    final lookup = await PresenceLocationService(
      config: config.presence,
      clock: clock,
    ).whereIs(name);

    if (lookup.matched) {
      _lastPresencePersonName = lookup.displayName.split(' ').first;
    }

    if (!lookup.matched) return lookup.spoken;
    if (lookup.liveKnown) return lookup.spoken;

    // HA unknown → optional camera history (do not invent driveway times).
    if (!VisionMcpClient.isConfigured) return lookup.spoken;
    final client = VisionMcpClient();
    try {
      final hint = await client.personLastSeenSpoken(name: name);
      if (hint == null || hint.trim().isEmpty) return lookup.spoken;
      return '${lookup.spoken} ${clipSpokenHint(hint)}';
    } catch (e) {
      logWarn('where_is_frigate_fallback', e.toString(), data: {'name': name});
      return lookup.spoken;
    } finally {
      client.close();
    }
  }

  Future<String?> _spokenWhenPersonLeft(String? nameQuery) async {
    final name = (nameQuery ?? _lastPresencePersonName)?.trim() ?? '';
    if (name.isEmpty) {
      return 'Who left — say a name, or ask where someone is first.';
    }
    final lookup = await PresenceLocationService(
      config: config.presence,
      clock: clock,
    ).whenLeft(name);
    if (lookup.matched) {
      _lastPresencePersonName = lookup.displayName.split(' ').first;
    }
    return lookup.spoken;
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
      await _speakText(spoken, turnId, rememberUserText: text);
      return true;
    } catch (e) {
      logWarn('google_data_failed', e.toString(), data: {
        'turn_id': turnId,
        'kind': intent.kind.name,
      });
      await _speakText(
        'I could not read that from Google right now. Try again in a moment.',
        turnId,
        rememberUserText: text,
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
  Future<void> _speakText(
    String spoken,
    String turnId, {
    String? rememberUserText,
  }) async {
    final ttsSpan = Span('tts_total');
    final path = await tts.synthesizeToFile(spoken);
    _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
    ttsSpan.close();
    _noteSpeakDuration(path: path, text: spoken);
    final audioUrl = audioServer.registerFile(path);
    handle(ResponseReady(spoken, audioUrl));
    // Always log assistant speech so follow-ups like "which button?" have context.
    _rememberSpoken(spoken, userText: rememberUserText ?? '');
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
          data: {
            'text': spoken,
            'audioUrl': audioUrl,
            ..._kioskSpeakAudioFlags(),
          },
        ),
      );
      unawaited(_maybePlayLocal(audioUrl));
      _rememberSpoken(spoken);
    } catch (e) {
      logWarn('google_announce', e.toString());
      machine.context.playing = false;
      _sendAudio(
        Envelope.create(type: 'wake.enable', data: {'enabled': true}),
      );
    }
  }

  /// Sleep / volume / self-care without AO MCP.
  Future<bool> _tryTerminalIntent(String text, String turnId) async {
    final intent = parseTerminalIntent(text);
    if (intent == null) return false;

    late final Map<String, dynamic> result;
    late final String spoken;
    switch (intent.kind) {
      case TerminalIntentKind.sleepEnter:
        handle(const EnterSleep());
        result = control.sleepStatus();
        spoken = _phraseFor(
          PhraseCategory.sleepEnter,
          fallback:
              'Okay, entering sleep mode. Say hey comstar when you need me.',
        );
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
      case TerminalIntentKind.healthStatus:
        result = Map<String, dynamic>.from(healthStatus());
        spoken = _spokenHealthSummary(result);
      case TerminalIntentKind.healSelf:
        if (session.guest) {
          result = {'ok': false, 'error': 'guest_denied'};
          spoken =
              "I can't restart, reboot, or heal while you're a guest. Ask a known person.";
          break;
        }
        // Hold Responding (mic off) through progress + heal + final reply.
        // Do not use ResponseReady for the checking line — that clears
        // directAgentInFlight and opens follow-up before the answer exists.
        final heal = await _runHealSelfHeld(text: text, turnId: turnId);
        result = heal;
        spoken = heal['spoken']?.toString() ??
            'I could not complete that self-care action.';
      case TerminalIntentKind.restartSelf:
      case TerminalIntentKind.restartAudio:
      case TerminalIntentKind.restartKiosk:
      case TerminalIntentKind.rebootHost:
        if (session.guest) {
          result = {'ok': false, 'error': 'guest_denied'};
          spoken =
              "I can't restart, reboot, or heal while you're a guest. Ask a known person.";
          break;
        }
        final outcome = await _runSelfCareAction(intent.kind);
        result = outcome;
        spoken = outcome['spoken']?.toString() ??
            'I could not complete that self-care action.';
    }

    logInfo('terminal_intent', 'Handled device control locally', data: {
      'turn_id': turnId,
      'kind': intent.kind.name,
      'result': result,
    });

    final deferDestructive = !session.guest &&
        result['ok'] == true &&
        (intent.kind == TerminalIntentKind.restartSelf ||
            intent.kind == TerminalIntentKind.rebootHost);

    _armPlaybackWait();
    try {
      final ttsSpan = Span('tts_total');
      final path = await tts.synthesizeToFile(spoken);
      _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
      ttsSpan.close();
      _noteSpeakDuration(path: path, text: spoken);
      final audioUrl = audioServer.registerFile(path);
      handle(ResponseReady(spoken, audioUrl));
      unawaited(_rememberExchange(userText: text, assistantText: spoken));
    } catch (e) {
      logWarn('terminal_intent_speak_failed', e.toString(), data: {
        'turn_id': turnId,
        'kind': intent.kind.name,
      });
      await _speakFallback(
        spoken.trim().isEmpty
            ? 'I finished that, but could not speak the result.'
            : spoken,
        turnId,
      );
    }

    // Always finish the spoken line before restart/reboot so TTS is not cut off.
    if (deferDestructive) {
      await _awaitPlayback();
      if (intent.kind == TerminalIntentKind.restartSelf) {
        await _restartUnit('bridge');
      } else if (intent.kind == TerminalIntentKind.rebootHost) {
        await _rebootHost();
      }
    }
    return true;
  }

  void _armPlaybackWait() {
    _playbackWait = Completer<void>();
  }

  void _signalPlaybackDone() {
    final c = _playbackWait;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> _awaitPlayback() async {
    final c = _playbackWait;
    if (c == null || c.isCompleted) return;
    final playMs = _lastSpeakDurationMs > 0 ? _lastSpeakDurationMs : 3000;
    try {
      await c.future.timeout(Duration(milliseconds: playMs + 5000));
    } on TimeoutException {
      logWarn('speak_await_timeout', 'Timed out waiting for speak.ended');
      _signalPlaybackDone();
    }
  }

  String _spokenHealthSummary(Map<String, dynamic> h) {
    final state = h['state']?.toString() ?? 'unknown';
    final kiosk = h['kiosk_connected'] == true ? 'up' : 'down';
    final audio = h['audio_connected'] == true ? 'up' : 'down';
    final reach = h['reach_active'] == true ? 'connected' : 'down';
    final sleeping = h['sleeping'] == true ? ' I am in sleep mode.' : '';
    final who = h['userid']?.toString();
    final whoBit = (who != null && who.isNotEmpty)
        ? ' I currently know you as $who.'
        : ' I do not have a recognized person right now.';
    return 'I am in $state. Kiosk is $kiosk, audio is $audio, '
        'and Reach is $reach.$sleeping$whoBit';
  }

  Future<Map<String, dynamic>> _runSelfCareAction(TerminalIntentKind kind) async {
    switch (kind) {
      case TerminalIntentKind.restartSelf:
        return {
          'ok': true,
          'unit': 'bridge',
          'spoken':
              'Okay — restarting my bridge now. I will be quiet for a few seconds.',
        };
      case TerminalIntentKind.rebootHost:
        return {
          'ok': true,
          'spoken':
              'Okay — rebooting the whole terminal now. I will be offline until I come back up.',
        };
      case TerminalIntentKind.restartAudio:
        final ok = await _restartUnit('audio');
        return {
          'ok': ok,
          'unit': 'audio',
          'spoken': ok
              ? 'Okay, I restarted the audio service.'
              : 'I could not restart audio.',
        };
      case TerminalIntentKind.restartKiosk:
        final ok = await _restartUnit('kiosk');
        return {
          'ok': ok,
          'unit': 'kiosk',
          'spoken': ok
              ? 'Okay, I restarted the kiosk display.'
              : 'I could not restart the kiosk.',
        };
      case TerminalIntentKind.healSelf:
        return _runHealWithSummary();
      default:
        return {'ok': false, 'spoken': 'I do not know that self-care action.'};
    }
  }

  Future<bool> _restartUnit(String key) async {
    final unit = resolveAdminUnit(key);
    if (unit == null || unit == 'all') return false;
    try {
      final r = await Process.run('systemctl', ['--user', 'restart', unit]);
      logInfo('self_care_restart', 'Restarted unit', data: {
        'unit': unit,
        'code': r.exitCode,
      });
      return r.exitCode == 0;
    } catch (e) {
      logWarn('self_care_restart_failed', e.toString(), data: {'unit': key});
      return false;
    }
  }

  Future<bool> _rebootHost() async {
    try {
      logWarn('self_care_reboot', 'Host reboot requested via voice');
      final r = await Process.run('sudo', ['/sbin/reboot']);
      return r.exitCode == 0;
    } catch (e) {
      logWarn('self_care_reboot_failed', e.toString());
      return false;
    }
  }

  /// Progress line while [directAgentInFlight] stays true — does not complete
  /// the turn or open follow-up (same half-duplex hold as AO working-ack).
  Future<void> _speakHoldingLine(String line, String turnId) async {
    _armPlaybackWait();
    try {
      machine.context.playing = true;
      machine.context.followUpListening = false;
      machine.context.followUpOpen = false;
      _followUpGen++;
      _followUpTimer?.cancel();
      _followUpTimer = null;
      _sendAudio(Envelope.create(type: 'listen.stop'));
      if (machine.context.halfDuplex) {
        machine.context.wakeEnabled = false;
        _syncAudioWakeGate();
      }
      final ttsSpan = Span('tts_total');
      final path = await tts.synthesizeToFile(line);
      _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
      ttsSpan.close();
      _noteSpeakDuration(path: path, text: line);
      final audioUrl = audioServer.registerFile(path);
      _beginSpeakWatchdog();
      _broadcastPhase('speaking', detail: line);
      _broadcastKiosk(
        Envelope.create(
          type: 'speak',
          turnId: turnId,
          data: {
            'text': line,
            'audioUrl': audioUrl,
            ..._kioskSpeakAudioFlags(),
          },
        ),
      );
      unawaited(_maybePlayLocal(audioUrl));
    } catch (e) {
      logWarn('holding_speak_failed', e.toString(), data: {'turn_id': turnId});
      machine.context.playing = false;
      _signalPlaybackDone();
    }
  }

  /// Heal self: speak "checking…", keep mic off, always return a spoken result.
  Future<Map<String, dynamic>> _runHealSelfHeld({
    required String text,
    required String turnId,
  }) async {
    machine.context.directAgentInFlight = true;
    machine.context.respondingStartedAtMs = clock.nowMs;
    _broadcastKiosk(
      Envelope.create(type: 'thinking', data: {'active': true}),
    );
    _broadcastPhase('thinking', detail: 'Checking systems…');

    const checking =
        'Okay — checking my systems now. I will tell you what I find.';
    await _speakHoldingLine(checking, turnId);
    _rememberSpoken(checking, userText: text);
    await _awaitPlayback();

    // Still holding — refresh timeout so Tick does not SpeakFallback mid-heal.
    machine.context.directAgentInFlight = true;
    machine.context.respondingStartedAtMs = clock.nowMs;
    _broadcastKiosk(
      Envelope.create(type: 'thinking', data: {'active': true}),
    );
    _broadcastPhase('thinking', detail: 'Checking systems…');

    try {
      return await _runHealWithSummary();
    } catch (e) {
      logWarn('self_care_heal_failed', e.toString());
      return {
        'ok': false,
        'spoken':
            'I ran into a problem while checking my systems. Try asking for my health status.',
      };
    }
  }

  Future<Map<String, dynamic>> _runHealWithSummary() async {
    final candidates = <String>[
      if (Platform.environment['COMSTAR_HEALTH_SCRIPT']?.trim().isNotEmpty ==
          true)
        Platform.environment['COMSTAR_HEALTH_SCRIPT']!.trim(),
      if (Platform.environment['COMSTAR_ROOT']?.trim().isNotEmpty == true)
        p.join(
          Platform.environment['COMSTAR_ROOT']!.trim(),
          'scripts',
          'comstar_health.sh',
        ),
      '/opt/comstar/src/scripts/comstar_health.sh',
    ];
    String? path;
    for (final c in candidates) {
      if (c.isNotEmpty && File(c).existsSync()) {
        path = c;
        break;
      }
    }
    if (path == null) {
      return {
        'ok': false,
        'spoken': 'I could not find my health heal script.',
      };
    }

    try {
      final r = await Process.run(
        'bash',
        [path],
        environment: {
          ...Platform.environment,
          'COMSTAR_HEALTH_HEAL': '1',
        },
      ).timeout(const Duration(seconds: 90));
      final out = '${r.stdout}\n${r.stderr}';
      logInfo('self_care_heal', 'Heal finished', data: {
        'code': r.exitCode,
        'chars': out.length,
      });
      return {'ok': true, 'spoken': summarizeHealOutput(out), 'exit': r.exitCode};
    } on TimeoutException {
      return {
        'ok': false,
        'spoken':
            'My health check took too long and timed out. Try asking for my health status.',
      };
    } catch (e) {
      logWarn('self_care_heal_failed', e.toString());
      return {
        'ok': false,
        'spoken': 'I could not run my health heal.',
      };
    }
  }

  /// Who-am-I / recognize-me — force CPAI pass and speak identity.
  Future<bool> _tryIdentityIntent(String text, String turnId) async {
    final intent = parseIdentityIntent(text);
    if (intent == null) return false;

    final beforeUid = machine.context.cachedUserid;

    if (intent.kind == IdentityIntentKind.recognizeMe ||
        beforeUid == null ||
        beforeUid == 'guest') {
      _visionPoller?.identity.requestReidentify();
      final id = _visionPoller?.identity;
      if (id != null) id.continuousRecognize = true;
      _visionPoller?.setTargetFps(config.vision.engagedFps);

      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final uid = machine.context.cachedUserid;
        if (uid != null && uid.isNotEmpty && uid != 'guest') {
          // Prefer a fresh resolve after we cleared the vote cache.
          if (intent.kind == IdentityIntentKind.recognizeMe && i < 5) {
            continue;
          }
          break;
        }
      }
    }

    final uid = machine.context.cachedUserid;
    final name = machine.context.cachedDisplayName ?? uid;

    late final String spoken;
    if (uid == null || uid.isEmpty) {
      spoken =
          "I cannot see a face I know yet. Stand in front of me and say recognize me again.";
    } else if (uid == 'guest' || session.guest) {
      spoken =
          "I see you, but I do not recognize you as a household member. You are in guest mode.";
    } else if (intent.kind == IdentityIntentKind.recognizeMe) {
      spoken = name != null && name != uid
          ? 'Okay — I recognize you as $name.'
          : 'Okay — I recognize you as $uid.';
    } else {
      spoken = name != null && name != uid
          ? 'You are $name.'
          : 'You are $uid.';
    }

    logInfo('identity_intent', 'Answered identity locally', data: {
      'turn_id': turnId,
      'kind': intent.kind.name,
      'userid': uid,
      'before': beforeUid,
    });
    await _speakText(spoken, turnId, rememberUserText: text);
    return true;
  }

  /// Time / date / season / timezone from this terminal's system clock.
  Future<bool> _tryClockIntent(String text, String turnId) async {
    final intent = parseClockIntent(text);
    if (intent == null) return false;

    final tzLabel = Platform.environment['COMSTAR_TZ']?.trim().isNotEmpty == true
        ? Platform.environment['COMSTAR_TZ']!.trim()
        : config.attention.timezone.trim();
    final spoken = formatClockAnswer(
      intent,
      timezoneLabel: tzLabel.isEmpty ? null : tzLabel,
    );
    logInfo('clock_intent', 'Answered from terminal clock', data: {
      'turn_id': turnId,
      'kind': intent.kind.name,
      'spoken': spoken,
    });
    await _speakText(spoken, turnId, rememberUserText: text);
    return true;
  }

  /// Social check-ins answered locally (phrase bank + templates).
  Future<bool> _trySocialIntent(String text, String turnId) async {
    final intent = parseSocialIntent(text);
    if (intent == null) return false;

    final name =
        machine.context.cachedDisplayName ?? machine.context.cachedUserid;
    final bankLine = config.phrases.enabled
        ? phraseBank.pick(PhraseCategory.social, name: name)
        : null;
    final spoken = formatSocialAnswer(
      intent,
      bankLine: bankLine,
      name: name,
    );
    logInfo('social_intent', 'Answered social locally', data: {
      'turn_id': turnId,
      'kind': intent.kind.name,
      'from_bank': bankLine != null && bankLine.trim().isNotEmpty,
      'spoken': spoken.length > 80 ? '${spoken.substring(0, 80)}…' : spoken,
    });
    await _speakText(spoken, turnId, rememberUserText: text);
    return true;
  }

  /// TTS + kiosk speak for gate-delivered announcements (M10.4).
  Future<void> _speakAnnouncementText(
    String text,
    String turnId,
    String mood,
  ) async {
    try {
      machine.context.playing = true;
      _followUpGen++;
      _followUpTimer?.cancel();
      _followUpTimer = null;
      machine.context.followUpListening = false;
      machine.context.followUpOpen = false;
      _sendAudio(Envelope.create(type: 'listen.stop'));
      if (machine.context.halfDuplex) {
        _sendAudio(
          Envelope.create(type: 'wake.enable', data: {'enabled': false}),
        );
      }
      final path = await tts.synthesizeToFile(text);
      _noteSpeakDuration(path: path, text: text);
      final audioUrl = audioServer.registerFile(path);
      _beginSpeakWatchdog();
      final speakMood = resolveSpeakMood(text, explicit: mood);
      _broadcastPhase('speaking', detail: text);
      _broadcastKiosk(
        Envelope.create(
          type: 'speak',
          turnId: turnId,
          data: {
            'text': text,
            'audioUrl': audioUrl,
            'mood': speakMood,
            ..._kioskSpeakAudioFlags(),
          },
        ),
      );
      unawaited(_maybePlayLocal(audioUrl));
      _rememberSpoken(text);
    } catch (e) {
      logWarn('announce_speak_failed', e.toString());
      machine.context.playing = false;
      handle(const PlaybackEnded());
    }
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
      final name = machine.context.cachedDisplayName ?? userid;
      var greeting = phraseBank.pick(PhraseCategory.engage, name: name);
      if (greeting == null || greeting.trim().isEmpty) {
        greeting = await session.runGreeter(userid);
        if (greeting.trim().isEmpty) return;
        // Only seed templates; concrete names would pollute the shared bank.
        if (greeting.contains(PhraseBank.nameSlot) || greeting.contains('{name}')) {
          phraseBank.replaceCategory(PhraseCategory.engage, [greeting]);
          phraseBank.save();
        }
        greeting = PhraseBank.fillName(greeting, name);
      }

      // M10.5 — fold due announcements into the same greeter utterance.
      final fold = announce?.peekForGreeter(userid) ?? const [];
      if (fold.isNotEmpty) {
        final extra = coalesceAnnouncementText(fold);
        if (extra.isNotEmpty) {
          greeting = greeting.trimRight();
          if (!greeting.endsWith('.') && !greeting.endsWith('!')) {
            greeting = '$greeting.';
          }
          greeting = '$greeting $extra';
          announce?.markGreeterFoldDelivered(fold, greeting);
          logInfo('announce_greeter_fold', 'Folded announcements into greeter', data: {
            'count': fold.length,
            'userid': userid,
          });
        }
      }

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
          data: {
            'text': greeting,
            'audioUrl': audioUrl,
            ..._kioskSpeakAudioFlags(),
          },
        ),
      );
      unawaited(_maybePlayLocal(audioUrl));
      _rememberSpoken(greeting);
    } catch (e) {
      logWarn('greeter_failed', e.toString(), data: {'userid': userid});
      machine.context.playing = false;
      _sendAudio(
        Envelope.create(type: 'wake.enable', data: {'enabled': true}),
      );
    }
  }

  String _phraseFor(
    String category, {
    required String fallback,
    String? name,
  }) {
    if (!config.phrases.enabled) return fallback;
    return phraseBank.pick(category, name: name) ?? fallback;
  }

  /// Short line after confirmed sleep wake; skip if bank empty.
  ///
  /// Waits for follow-up mic arm first so we do not bump `_followUpGen` and
  /// cancel the post-wake listen window before it starts.
  Future<void> _speakSleepWakeLineWhenReady() async {
    if (!config.phrases.enabled) return;
    for (var i = 0; i < 40; i++) {
      if (machine.context.followUpMicArmedAtMs != null) break;
      if (machine.state is! Engaged) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await _speakSleepWakeLine();
  }

  Future<void> _speakSleepWakeLine() async {
    if (!config.phrases.enabled) return;
    if (machine.state is! Engaged) return;
    final name = machine.context.cachedDisplayName ?? machine.context.cachedUserid;
    final line = phraseBank.pick(PhraseCategory.sleepWake, name: name);
    if (line == null || line.trim().isEmpty) return;
    try {
      machine.context.playing = true;
      _followUpGen++;
      _sendAudio(Envelope.create(type: 'listen.stop'));
      _sendAudio(
        Envelope.create(type: 'wake.enable', data: {'enabled': false}),
      );
      final ttsSpan = Span('tts_total');
      final path = await tts.synthesizeToFile(line);
      _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
      ttsSpan.close();
      _noteSpeakDuration(path: path, text: line);
      final audioUrl = audioServer.registerFile(path);
      _beginSpeakWatchdog();
      _broadcastPhase('speaking', detail: line);
      _broadcastKiosk(
        Envelope.create(
          type: 'speak',
          turnId: 'sleep-wake',
          data: {
            'text': line,
            'audioUrl': audioUrl,
            ..._kioskSpeakAudioFlags(),
          },
        ),
      );
      unawaited(_maybePlayLocal(audioUrl));
      _rememberSpoken(line);
    } catch (e) {
      logWarn('sleep_wake_phrase_failed', e.toString());
      machine.context.playing = false;
      _sendAudio(
        Envelope.create(type: 'wake.enable', data: {'enabled': true}),
      );
    }
  }

  void _armPhraseBankRefresh() {
    _phraseRefreshTimer?.cancel();
    _phraseRefreshTimer = null;
    if (!config.phrases.enabled) return;
    // Soon after start, then on the configured cadence.
    _phraseRefreshTimer = Timer(const Duration(seconds: 45), () {
      unawaited(_refreshPhraseBanksIfNeeded(force: false));
      _phraseRefreshTimer = Timer.periodic(
        config.phrases.refreshEvery,
        (_) => unawaited(_refreshPhraseBanksIfNeeded(force: false)),
      );
    });
  }

  bool get _phraseRefreshBusy {
    // Only avoid colliding with an in-flight speak or AO voice turn.
    return machine.context.playing ||
        machine.context.directAgentInFlight ||
        machine.context.sttPending ||
        machine.state is Responding ||
        _sleepWakeVerifyInFlight;
  }

  Future<void> _refreshPhraseBanksIfNeeded({required bool force}) async {
    if (!config.phrases.enabled) return;
    if (_phraseRefreshInFlight) return;
    if (!force && !phraseBank.needsRefresh(config.phrases.refreshEvery)) {
      return;
    }
    if (_phraseRefreshBusy) {
      logInfo('phrase_bank_refresh_deferred', 'Busy; will retry later', data: {
        'state': machine.state.name,
        'playing': machine.context.playing,
        'stt_pending': machine.context.sttPending,
        'direct_agent': machine.context.directAgentInFlight,
      });
      Timer(const Duration(seconds: 90), () {
        unawaited(_refreshPhraseBanksIfNeeded(force: force));
      });
      return;
    }

    _phraseRefreshInFlight = true;
    final openedForRefresh = !session.isOpen;
    try {
      if (openedForRefresh) {
        await session.open(userid: 'phrase-bank', guest: true);
      } else {
        await session.ensureReady(quiet: true);
      }

      final counts = <String, int>{};
      for (final category in PhraseCategory.all) {
        final lines = await session.runPhraseBank(
          category: category,
          count: config.phrases.bankSize,
        );
        if (lines.isNotEmpty) {
          phraseBank.replaceCategory(category, lines);
          counts[category] = phraseBank.count(category);
        } else {
          counts[category] = phraseBank.count(category);
          logWarn('phrase_bank_empty', 'AO returned no lines', data: {
            'category': category,
          });
        }
      }
      phraseBank.save();
      logInfo('phrase_bank_refreshed', 'Phrase banks updated', data: {
        'counts': counts,
        'path': phraseBank.path.path,
        'opened_guest': openedForRefresh,
      });
    } catch (e) {
      logWarn('phrase_bank_refresh_failed', e.toString());
    } finally {
      if (openedForRefresh &&
          session.isOpen &&
          session.userid == 'phrase-bank' &&
          !_phraseRefreshBusy &&
          machine.state is! Engaged &&
          machine.state is! Listening &&
          machine.state is! Responding) {
        try {
          await session.close();
          machine.context.sessionOpen = false;
        } catch (_) {}
      }
      _phraseRefreshInFlight = false;
    }
  }

  Future<void> _speakFallback(String line, String turnId) async {
    // Clear in-flight / thinking so PlaybackEnded can leave Responding.
    // Otherwise a failed AO turn speaks the sorry line but stays stuck in
    // Responding with the thinking HUD forever.
    machine.context.directAgentInFlight = false;
    _broadcastKiosk(
      Envelope.create(type: 'thinking', data: {'active': false}),
    );
    // Speak directly — do not route through ResponseReady. Orchestration
    // timeout may already have left Responding → Engaged, which previously
    // dropped ResponseReady and left the user with silence.
    try {
      await _announceEngaged(line);
    } catch (e) {
      logWarn('speak_fallback_failed', e.toString(), data: {'turn_id': turnId});
      final canned = _lookupFallbackWav(line);
      final path = canned ?? await tts.synthesizeToFile(line);
      _noteSpeakDuration(path: path, text: line);
      final audioUrl = audioServer.registerFile(path);
      machine.context.playing = true;
      _beginSpeakWatchdog();
      _broadcastPhase('speaking', detail: line);
      _broadcastKiosk(
        Envelope.create(
          type: 'speak',
          turnId: turnId,
          data: {
            'text': line,
            'audioUrl': audioUrl,
            ..._kioskSpeakAudioFlags(),
          },
        ),
      );
      unawaited(_maybePlayLocal(audioUrl));
      _rememberSpoken(line);
    }
  }

  /// When paplay owns the speakers, tell the kiosk to decode for timing /
  /// analyser only — no WebAudio → destination (avoids HDMI double-play).
  Map<String, Object> _kioskSpeakAudioFlags() {
    if (Platform.environment['COMSTAR_LOCAL_SPEAKER'] == '1') {
      return const {'muteOutput': true};
    }
    return const {};
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
    // Local paplay when COMSTAR_LOCAL_SPEAKER=1. Kiosk still decodes the WAV for
    // speak.ended / emblem pulse, but speak envelopes set muteOutput so Chromium
    // does not also drive HDMI (dual output).
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
          'kiosk': ws.hasRole('kiosk'),
        });
        // Synthetic speak.ended if kiosk absent so follow-up can open.
        if (!ws.hasRole('kiosk')) {
          final holdingReply = machine.state is Responding &&
              machine.context.directAgentInFlight;
          _cancelSpeakWatchdog();
          handle(const PlaybackEnded());
          _signalPlaybackDone();
          if (holdingReply) {
            _completeWorkingAckPlayback();
            _broadcastKiosk(
              Envelope.create(type: 'thinking', data: {'active': true}),
            );
            _broadcastPhase('thinking', detail: 'Working…');
          }
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
          'kiosk': ws.hasRole('kiosk'),
        });
        if (!ws.hasRole('kiosk')) {
          final holdingReply = machine.state is Responding &&
              machine.context.directAgentInFlight;
          _cancelSpeakWatchdog();
          handle(const PlaybackEnded());
          _signalPlaybackDone();
          if (holdingReply) {
            _completeWorkingAckPlayback();
            _broadcastKiosk(
              Envelope.create(type: 'thinking', data: {'active': true}),
            );
            _broadcastPhase('thinking', detail: 'Working…');
          }
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

  Future<void> _refreshAdminQr({bool force = false}) async {
    if (!_kioskWantsAdminQr && !force) return;
    if (!_kioskWantsAdminQr) {
      _broadcastKiosk(
        Envelope.create(type: 'admin.qr', data: {'active': false}),
      );
      return;
    }
    final token = config.adminAuthToken;
    if (token.isEmpty) {
      _broadcastKiosk(
        Envelope.create(type: 'admin.qr', data: {'active': false}),
      );
      return;
    }
    final net = network;
    if (net == null) return;
    try {
      final lan = await net.preferredLanIpv4();
      final ip = lan.ip;
      if (ip == null || ip.isEmpty) {
        _broadcastKiosk(
          Envelope.create(type: 'admin.qr', data: {'active': false}),
        );
        return;
      }
      const port = 8781;
      final url =
          'http://$ip:$port/admin/?token=${Uri.encodeQueryComponent(token)}';
      _broadcastKiosk(
        Envelope.create(
          type: 'admin.qr',
          data: {
            'active': true,
            'url': url,
            'qrSvg': qrSvg(url, moduleSize: 4, quietZone: 2),
            'ip': ip,
            'iface': lan.device,
            'type': lan.type,
            'port': port,
          },
        ),
      );
      logInfo('admin_qr_push', 'Pushed admin QR to kiosk', data: {
        'ip': ip,
        'iface': lan.device,
        'type': lan.type,
      });
    } on Object catch (e) {
      logWarn('admin_qr_failed', e.toString());
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

  Future<Map<String, dynamic>?> applyAvatarOptions(
    Map<String, dynamic> options,
  ) async {
    final data = Map<String, dynamic>.from(options)
      ..remove('tier')
      ..remove('max_tier')
      ..remove('cpu_ema')
      ..remove('source');
    _broadcastKiosk(
      Envelope.create(type: 'avatar.options', data: data),
    );
    logInfo('avatar_options_push', 'Pushed avatar options to kiosk', data: {
      'bloom': options['bloom'],
      'fps': options['fps'],
      'scale': options['scale'],
      'emblem': options['emblem'],
      'source': options['source'] ?? 'manual',
      'tier': options['tier'],
      'cpu_ema': options['cpu_ema'],
    });
    return options;
  }
}
