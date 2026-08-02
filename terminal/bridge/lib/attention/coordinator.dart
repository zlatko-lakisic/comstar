import 'dart:async';
import 'dart:typed_data';

import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/effects.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:comstar_bridge/attention/machine.dart';
import 'package:comstar_bridge/attention/runner.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/envelope.dart';
import 'package:comstar_bridge/http_audio_server.dart';
import 'package:comstar_bridge/local_ws.dart';
import 'package:comstar_bridge/log.dart';
import 'package:comstar_bridge/session.dart';
import 'package:comstar_bridge/stt.dart';
import 'package:comstar_bridge/tts.dart';
import 'package:comstar_bridge/vision/vision_poller.dart' as vision;
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

  Timer? _tickTimer;
  vision.VisionPoller? _visionPoller;
  StreamSubscription<vision.VisionEvent>? _visionSub;

  final _captureBuffer = BytesBuilder(copy: false);
  var _captureSampleRate = 16000;
  WebSocketChannel? _audioChannel;

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
        unawaited(session.open(userid: userid, guest: guest));
      case CloseSession():
        unawaited(session.close());
      case StartListening(:final turnId):
        _captureBuffer.clear();
        _sendAudio(
          Envelope.create(
            type: 'listen.start',
            turnId: turnId,
            data: {
              'maxMs': config.audio.maxUtteranceSeconds * 1000,
            },
          ),
        );
      case StopListening():
        _sendAudio(Envelope.create(type: 'listen.stop'));
      case FinalizeCapture():
        break;
      case CallStt(:final turnId):
        unawaited(_runStt(turnId));
      case CallDirectAgent(:final text, :final turnId):
        unawaited(_runDirectAgent(text, turnId));
      case SetThinking(:final active):
        _broadcastKiosk(
          Envelope.create(type: 'thinking', data: {'active': active}),
        );
      case Speak(:final text, :final audioUrl, :final turnId):
        _broadcastKiosk(
          Envelope.create(
            type: 'speak',
            turnId: turnId,
            data: {'text': text, 'audioUrl': audioUrl},
          ),
        );
      case SpeakFallback(:final line, :final turnId):
        unawaited(_speakFallback(line, turnId));
      case PlayErrorTone():
        _sendAudio(Envelope.create(type: 'play', data: {'tone': 'error'}));
      case EnableWake(:final enabled):
        _sendAudio(
          Envelope.create(type: 'wake.enable', data: {'enabled': enabled}),
        );
      case OpenFollowUpWindow():
        logDebug('followup', 'Follow-up window opened');
      case RunGreeter(:final userid):
        unawaited(_runGreeter(userid));
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
        _captureBuffer.clear();
        _captureSampleRate =
            (envelope.data['sampleRate'] as num?)?.toInt() ?? 16000;
      case 'level':
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
    if (envelope.type == 'speak.ended') {
      handle(const PlaybackEnded());
    }
  }

  Future<void> _runStt(String turnId) async {
    final pcm = _captureBuffer.toBytes();
    final text = await stt.transcribe(
      Uint8List.fromList(pcm),
      sampleRate: _captureSampleRate,
    );
    handle(TranscriptReady(text));
  }

  Future<void> _runDirectAgent(String text, String turnId) async {
    try {
      final response = await session.directVoice(text);
      final path = await tts.synthesizeToFile(response);
      final audioUrl = audioServer.registerFile(path);
      handle(ResponseReady(response, audioUrl));
    } catch (e) {
      logWarn('direct_agent_failed', e.toString(), turnId: turnId);
      handle(const AttentionError('orchestration'));
    }
  }

  Future<void> _runGreeter(String userid) async {
    try {
      final greeting = await session.runGreeter(userid);
      if (greeting.trim().isEmpty) return;
      final path = await tts.synthesizeToFile(greeting);
      final audioUrl = audioServer.registerFile(path);
      _broadcastKiosk(
        Envelope.create(
          type: 'speak',
          data: {'text': greeting, 'audioUrl': audioUrl},
        ),
      );
    } catch (e) {
      logWarn('greeter_failed', e.toString(), data: {'userid': userid});
    }
  }

  Future<void> _speakFallback(String line, String turnId) async {
    final path = await tts.synthesizeToFile(line);
    final audioUrl = audioServer.registerFile(path);
    handle(ResponseReady(line, audioUrl));
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
