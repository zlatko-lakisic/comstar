import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/effects.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:comstar_bridge/attention/machine.dart';
import 'package:comstar_bridge/attention/runner.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/envelope.dart';
import 'package:comstar_bridge/http_audio_server.dart';
import 'package:comstar_bridge/local_ws.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/session.dart';
import 'package:comstar_bridge/stt.dart';
import 'package:comstar_bridge/tts.dart';
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
    Clock? clock,
    this.fallbackAudioDir,
  })  : clock = clock ?? SystemClock(),
        machine = AttentionMachine(
          config: config,
          clock: clock ?? SystemClock(),
        ),
        runner = EffectRunner();

  final ComstarConfig config;
  final LocalWs ws;
  final ComstarSession session;
  final SttClient stt;
  final TtsEngine tts;
  final HttpAudioServer audioServer;
  final Clock clock;
  final AttentionMachine machine;
  final EffectRunner runner;

  /// Directory of prebaked WAVs (`sorry.wav`, `offline.wav`, …). Optional.
  final String? fallbackAudioDir;

  Timer? _tickTimer;
  Timer? _speakWatchdog;
  Timer? _followUpTimer;
  vision.VisionPoller? _visionPoller;
  StreamSubscription<vision.VisionEvent>? _visionSub;
  Future<void>? _sessionOpenFuture;

  final _captureBuffer = BytesBuilder(copy: false);
  var _captureSampleRate = 16000;
  WebSocketChannel? _audioChannel;
  final Map<String, String> _greetingCache = {};
  DateTime? _speakStartedAt;
  Duration? _lastTtsTotal;

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
        _sessionOpenFuture = null;
        unawaited(session.close());
      case StartListening(:final turnId):
        _followUpTimer?.cancel();
        _followUpTimer = null;
        _captureBuffer.clear();
        _sendAudio(
          Envelope.create(
            type: 'listen.start',
            turnId: turnId,
            data: {
              'turn_id': turnId,
              'maxMs': config.audio.maxUtteranceSeconds * 1000,
            },
          ),
        );
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
      case Speak(:final text, :final audioUrl, :final turnId):
        machine.context.playing = true;
        _beginSpeakWatchdog();
        _broadcastKiosk(
          Envelope.create(
            type: 'speak',
            turnId: turnId,
            data: {'text': text, 'audioUrl': audioUrl},
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
      case LogAttention():
        break;
    }
  }

  void _openFollowUpWindow() {
    final seconds = config.audio.followupWindowSeconds;
    logInfo('followup', 'Follow-up window opened', data: {'seconds': seconds});
    final turnId = 'followup-${clock.nowMs}';
    machine.context.followUpOpen = true;
    machine.context.followUpListening = true;
    machine.context.followUpOpenedAtMs = clock.nowMs;
    machine.context.turnId = turnId;
    machine.context.listeningStartedAtMs = clock.nowMs;
    _captureBuffer.clear();
    _broadcastKiosk(
      Envelope.create(
        type: 'listening',
        data: {'active': true, 'followUp': true},
      ),
    );
    // Keep force-wake muted until TTS echo settles; VAD also settles in audio.
    _sendAudio(
      Envelope.create(type: 'wake.enable', data: {'enabled': false}),
    );
    // Stream mic so VAD can fire SpeechStart without a wake word.
    _sendAudio(
      Envelope.create(
        type: 'listen.start',
        turnId: turnId,
        data: {
          'turn_id': turnId,
          'maxMs': seconds * 1000,
        },
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (machine.context.turnId != turnId) return;
      if (machine.state is Engaged || machine.context.followUpListening) {
        machine.context.wakeEnabled = true;
        _sendAudio(
          Envelope.create(type: 'wake.enable', data: {'enabled': true}),
        );
        logInfo('followup', 'Follow-up mic armed after settle');
      }
    });
    _followUpTimer?.cancel();
    _followUpTimer = Timer(Duration(seconds: seconds), () {
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
        handle(FaceRecognized(userid, confidence));
      case vision.VisionFaceUnknown():
        handle(const FaceUnknown());
      case vision.VisionDegraded():
        handle(const VisionDegraded());
      case vision.VisionRecovered():
        handle(const VisionRecovered());
    }
  }

  void _handleAudioEnvelope(Envelope envelope) {
    switch (envelope.type) {
      case 'wake':
        final score = (envelope.data['score'] as num?)?.toDouble() ?? 0;
        handle(WakeWord(score));
      case 'vad.speech_start':
        handle(const SpeechStart());
      case 'vad.speech_end':
        final durationMs = (envelope.data['durationMs'] as num?)?.toInt() ?? 0;
        handle(SpeechEnd(durationMs));
      case 'audio.begin':
        // Keep pre-roll already buffered from listen.start; only reset sample rate.
        _captureSampleRate =
            (envelope.data['sampleRate'] as num?)?.toInt() ?? 16000;
      case 'audio.end':
        break;
      case 'level':
        // Only drive the avatar mic meter while we are actually capturing.
        // Broadcasting active=true on every RMS sample made the orb "listen"
        // continuously even after the follow-up window closed.
        final listening = machine.state is Listening ||
            machine.context.followUpListening;
        if (!listening) {
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

  void _handleKioskEnvelope(Envelope envelope) {
    switch (envelope.type) {
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
        handle(const PlaybackEnded());
        // Defensive: if machine did not open follow-up (wrong state), open it.
        if (machine.state is Engaged && !machine.context.followUpListening) {
          logWarn('followup_fallback', 'Opening follow-up after speak.ended');
          machine.context.followUpOpen = true;
          machine.context.followUpOpenedAtMs = clock.nowMs;
          _openFollowUpWindow();
        }
      default:
        break;
    }
  }

  void _beginSpeakWatchdog() {
    _cancelSpeakWatchdog();
    _speakStartedAt = DateTime.now();
    final ttsMs = _lastTtsTotal?.inMilliseconds ?? 3000;
    final timeout = Duration(milliseconds: ttsMs + 5000);
    _speakWatchdog = Timer(timeout, () {
      logWarn(
        'speak_watchdog',
        'kiosk speak.ended missing; forcing PlaybackEnded',
        data: {'timeout_ms': timeout.inMilliseconds},
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

  void _cancelSpeakWatchdog() {
    _speakWatchdog?.cancel();
    _speakWatchdog = null;
  }

  Future<void> _runStt(String turnId) async {
    final span = Span('stt');
    try {
      final pcm = _captureBuffer.toBytes();
      // One 320 ms frame is never enough for a real utterance — skip the
      // slow empty STT round-trip and let the machine reopen follow-up.
      if (pcm.length < 24000) {
        logWarn(
          'stt_too_short',
          'Capture too short for STT; reopening listen',
          data: {
            'turn_id': turnId,
            'bytes': pcm.length,
            'sample_rate': _captureSampleRate,
          },
        );
        handle(const TranscriptReady(''));
        return;
      }
      final text = await stt.transcribe(
        Uint8List.fromList(pcm),
        sampleRate: _captureSampleRate,
      );
      logInfo(
        'stt_result',
        text.trim().isEmpty ? 'Empty transcript' : 'Transcript ready',
        data: {
          'turn_id': turnId,
          'bytes': pcm.length,
          'sample_rate': _captureSampleRate,
          'text': text,
        },
      );
      handle(TranscriptReady(text));
    } finally {
      span.close();
    }
  }

  Future<void> _runDirectAgent(String text, String turnId) async {
    final turnSpan = Span('turn_total');
    try {
      final response = await session.directVoice(text);
      final ttsSpan = Span('tts_total');
      final path = await tts.synthesizeToFile(response);
      _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
      ttsSpan.close();
      final audioUrl = audioServer.registerFile(path);
      handle(ResponseReady(response, audioUrl));
    } catch (e) {
      logWarn('direct_agent_failed', e.toString(), turnId: turnId);
      handle(const AttentionError('orchestration'));
    } finally {
      turnSpan.close();
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
      final cached = _greetingCache[userid];
      final greeting = cached ?? await session.runGreeter(userid);
      if (greeting.trim().isEmpty) return;
      _greetingCache[userid] = greeting;

      // Half-duplex: mute wake while greeting plays.
      machine.context.playing = true;
      _sendAudio(
        Envelope.create(type: 'wake.enable', data: {'enabled': false}),
      );
      final ttsSpan = Span('tts_total');
      final path = await tts.synthesizeToFile(greeting);
      _lastTtsTotal = Duration(milliseconds: ttsSpan.elapsedMs);
      ttsSpan.close();
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
    try {
      final paplay = await Process.run('paplay', [path]);
      if (paplay.exitCode == 0) {
        logInfo('local_speaker', 'Played via paplay', data: {'path': path});
        // Synthetic speak.ended if kiosk absent so follow-up can open.
        if (!ws.hasRole('kiosk')) {
          _cancelSpeakWatchdog();
          handle(const PlaybackEnded());
        }
        return;
      }
      final aplay = await Process.run('aplay', [path]);
      if (aplay.exitCode == 0) {
        logInfo('local_speaker', 'Played via aplay', data: {'path': path});
        if (!ws.hasRole('kiosk')) {
          _cancelSpeakWatchdog();
          handle(const PlaybackEnded());
        }
        return;
      }
      logWarn('local_speaker_failed', 'paplay/aplay failed', data: {
        'paplay': paplay.exitCode,
        'aplay': aplay.exitCode,
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

  void _broadcastKiosk(Envelope envelope) {
    ws.sendToRole('kiosk', envelope);
  }
}
