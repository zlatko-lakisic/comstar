import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/attention/effects.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:comstar_bridge/config.dart';
import 'package:uuid/uuid.dart';

/// Mutable context tracked by the attention machine.
class MachineContext {
  MachineContext({
    required this.config,
    required this.clock,
    this.state = const Ambient(),
    this.sessionOpen = false,
    this.wakeEnabled = true,
    this.turnId,
    this.directAgentInFlight = false,
    this.playing = false,
    this.followUpOpen = false,
    this.followUpListening = false,
    this.followUpOpenedAtMs,
    this.absentFrames = 0,
    this.personPresent = false,
    this.gazeDetected = false,
    this.cachedUserid,
    this.identityExpiresAtMs,
    this.listeningStartedAtMs = 0,
    this.respondingStartedAtMs = 0,
    this.engagedEnteredAtMs = 0,
    this.sttPending = false,
  });

  final ComstarConfig config;
  final Clock clock;

  AttentionState state;
  bool sessionOpen;
  bool wakeEnabled;
  String? turnId;
  bool directAgentInFlight;
  bool playing;
  bool followUpOpen;
  /// Mic stream already running for the post-speak follow-up window.
  bool followUpListening;
  /// When the follow-up window opened (ignore echo for a short settle).
  int? followUpOpenedAtMs;
  int absentFrames;
  bool personPresent;
  bool gazeDetected;
  String? cachedUserid;
  int? identityExpiresAtMs;
  int listeningStartedAtMs;
  int respondingStartedAtMs;
  int engagedEnteredAtMs;
  bool sttPending;

  bool get halfDuplex => config.audio.duplex == 'half';

  bool get identityExpired =>
      identityExpiresAtMs == null || clock.nowMs >= identityExpiresAtMs!;

  /// Wait out HDMI TTS echo before treating mic energy as user speech.
  bool get followUpArmed =>
      followUpOpenedAtMs != null &&
      clock.nowMs - followUpOpenedAtMs! >= 1500;

  MachineContext copyForTransition() => MachineContext(
        config: config,
        clock: clock,
        state: state,
        sessionOpen: sessionOpen,
        wakeEnabled: wakeEnabled,
        turnId: turnId,
        directAgentInFlight: directAgentInFlight,
        playing: playing,
        followUpOpen: followUpOpen,
        followUpListening: followUpListening,
        followUpOpenedAtMs: followUpOpenedAtMs,
        absentFrames: absentFrames,
        personPresent: personPresent,
        gazeDetected: gazeDetected,
        cachedUserid: cachedUserid,
        identityExpiresAtMs: identityExpiresAtMs,
        listeningStartedAtMs: listeningStartedAtMs,
        respondingStartedAtMs: respondingStartedAtMs,
        engagedEnteredAtMs: engagedEnteredAtMs,
        sttPending: sttPending,
      );
}

class Transition {
  Transition({
    required this.from,
    required this.to,
    required this.effects,
    required this.context,
  });

  final AttentionState from;
  final AttentionState to;
  final List<Effect> effects;
  final MachineContext context;
}

/// Pure attention state machine (CONTRACTS §8).
class AttentionMachine {
  AttentionMachine({
    required ComstarConfig config,
    required Clock clock,
    MachineContext? initial,
    Uuid? uuid,
  })  : _uuid = uuid ?? const Uuid(),
        context = initial ??
            MachineContext(
              config: config,
              clock: clock,
            );

  final Uuid _uuid;
  final MachineContext context;

  AttentionState get state => context.state;

  Transition handle(AttentionEvent event) {
    final from = context.state;
    final effects = <Effect>[];

    if (event is AttentionError && event.fatal) {
      return _fatalError(from, effects);
    }

    switch (context.state) {
      case Ambient():
        _handleAmbient(event, effects);
      case Noticed():
        _handleNoticed(event, effects);
      case Engaged():
        _handleEngaged(event, effects);
      case Listening():
        _handleListening(event, effects);
      case Responding():
        _handleResponding(event, effects);
    }

    _handleGlobalVision(event, effects);

    final to = context.state;
    if (from.name != to.name) {
      effects.add(
        EmitState(
          to.name,
          userid: context.cachedUserid,
          displayName: context.cachedUserid,
        ),
      );
    }

    return Transition(from: from, to: to, effects: effects, context: context);
  }

  void _handleGlobalVision(AttentionEvent event, List<Effect> effects) {
    switch (event) {
      case VisionDegraded():
        effects.add(SetVisionFps(context.config.vision.ambientFps));
      case VisionRecovered():
        break;
      default:
        break;
    }
  }

  void _handleAmbient(AttentionEvent event, List<Effect> effects) {
    switch (event) {
      case PersonDetected(:final confidence):
        context.personPresent = true;
        context.absentFrames = 0;
        if (confidence >= context.config.vision.personConfidence) {
          context.state = const Noticed();
          effects.add(SetVisionFps(context.config.vision.engagedFps));
        }
      case PersonAbsent():
        context.personPresent = false;
        context.absentFrames++;
      case WakeWord():
        // Prefer face engagement before opening a guest listen session.
        // Energy/force wake must not race Ambient → guest Listening.
        break;
      default:
        break;
    }
  }

  void _handleNoticed(AttentionEvent event, List<Effect> effects) {
    switch (event) {
      case PersonDetected(:final confidence):
        context.personPresent = true;
        context.absentFrames = 0;
        if (confidence < context.config.vision.personConfidence) {
          context.personPresent = false;
        }
      case PersonAbsent():
        context.personPresent = false;
        context.absentFrames++;
        if (context.absentFrames >= 3) {
          context.state = const Ambient();
          context.absentFrames = 0;
          effects.add(SetVisionFps(context.config.vision.ambientFps));
        }
      case FaceRecognized(:final userid, :final confidence):
        if (confidence >= context.config.vision.faceConfidence) {
          _enterEngaged(effects, userid: userid, guest: false);
        }
      case FaceUnknown():
        switch (context.config.attention.strangerMode) {
          case 'greet':
            _enterEngaged(effects, userid: 'guest', guest: true);
          case 'restricted' || 'ignore':
            break;
        }
      case WakeWord():
        // Same as Ambient — wait until Engaged (known face) before listening.
        break;
      default:
        break;
    }
  }

  void _handleEngaged(AttentionEvent event, List<Effect> effects) {
    switch (event) {
      case PersonDetected():
        context.personPresent = true;
        context.absentFrames = 0;
      case PersonAbsent():
        context.personPresent = false;
        context.absentFrames++;
      case FaceRecognized(:final userid, :final confidence):
        if (confidence >= context.config.vision.faceConfidence) {
          _cacheIdentity(userid);
        }
      case WakeWord():
        // Ignore mic triggers while we are still playing (HDMI echo of TTS).
        if (context.playing) {
          break;
        }
        // Follow-up already streams the mic — wait for VAD SpeechStart.
        // Energy/force wake false-triggers on room noise right after arming.
        if (context.followUpListening) {
          break;
        }
        _enterListening(effects);
      case SpeechStart():
        if (context.playing) {
          break;
        }
        if (context.followUpOpen ||
            (context.config.attention.faceAttentionTrigger &&
                context.gazeDetected)) {
          if (context.followUpListening) {
            if (!context.followUpArmed) {
              break;
            }
            _promoteFollowUpListening(effects);
          } else {
            _enterListening(effects);
          }
        }
      case PlaybackEnded():
        // Greeter (and any Engaged-time speak) finishes here — open follow-up
        // so the user can talk without a wake word for a few seconds.
        context.playing = false;
        context.followUpOpen = true;
        context.followUpOpenedAtMs = context.clock.nowMs;
        // Keep wake muted during settle — OpenFollowUpWindow re-enables it.
        effects.add(const OpenFollowUpWindow());
      case Tick():
        if (context.identityExpired && !context.personPresent) {
          _returnAmbient(effects, closeSession: true);
        }
      default:
        break;
    }
  }

  void _handleListening(AttentionEvent event, List<Effect> effects) {
    switch (event) {
      case PersonDetected():
        context.personPresent = true;
        context.absentFrames = 0;
      case PersonAbsent():
        context.personPresent = false;
        context.absentFrames++;
      case SpeechEnd():
        if (!context.sttPending) {
          context.sttPending = true;
          effects.add(FinalizeCapture());
          effects.add(CallStt(context.turnId!));
        }
      case PlaybackEnded():
        // TTS finished after an echo/false wake pulled us into Listening.
        // Drop the bad turn and open a real follow-up window.
        context.playing = false;
        context.sttPending = false;
        _leaveListeningToEngaged(effects);
        effects.add(const StopListening());
        context.followUpOpen = true;
        context.followUpOpenedAtMs = context.clock.nowMs;
        effects.add(const OpenFollowUpWindow());
      case TranscriptReady(:final text):
        context.sttPending = false;
        if (text.trim().isEmpty) {
          // Missed / too-short capture — keep the conversation open so the
          // user can speak again without waiting for another face engage.
          _leaveListeningToEngaged(effects);
          effects.add(const StopListening());
          context.followUpOpen = true;
          context.followUpOpenedAtMs = context.clock.nowMs;
          effects.add(const OpenFollowUpWindow());
        } else {
          context.state = const Responding();
          context.respondingStartedAtMs = context.clock.nowMs;
          context.directAgentInFlight = true;
          context.wakeEnabled = true;
          effects.add(const EnableWake(true));
          effects.add(const SetThinking(true));
          effects.add(CallDirectAgent(text, context.turnId!));
        }
      case Tick():
        final elapsedMs =
            context.clock.nowMs - context.listeningStartedAtMs;
        final maxMs = context.config.audio.maxUtteranceSeconds * 1000;
        if (elapsedMs > maxMs && !context.sttPending) {
          // Stay in Listening until STT returns — do not jump to Responding
          // early or TranscriptReady will be dropped.
          context.sttPending = true;
          effects.add(FinalizeCapture());
          effects.add(CallStt(context.turnId!));
        }
      default:
        break;
    }
  }

  void _handleResponding(AttentionEvent event, List<Effect> effects) {
    switch (event) {
      case ResponseReady(:final text, :final audioUrl):
        context.directAgentInFlight = false;
        context.playing = context.halfDuplex;
        if (context.halfDuplex) {
          context.wakeEnabled = false;
          effects.add(const EnableWake(false));
        }
        effects.add(
          Speak(
            text: text,
            audioUrl: audioUrl,
            turnId: context.turnId!,
          ),
        );
      case PlaybackEnded():
        context.playing = false;
        context.followUpOpen = true;
        context.followUpOpenedAtMs = context.clock.nowMs;
        _leaveRespondingToEngaged(effects);
        effects.add(const OpenFollowUpWindow());
      case Tick():
        if (context.directAgentInFlight) {
          final elapsedMs =
              context.clock.nowMs - context.respondingStartedAtMs;
          final timeoutMs =
              context.config.orchestration.timeoutSeconds * 1000;
          if (elapsedMs > timeoutMs) {
            context.directAgentInFlight = false;
            effects.add(
              SpeakFallback(
                'Sorry, I could not get an answer in time.',
                context.turnId!,
              ),
            );
            _leaveRespondingToEngaged(effects);
            if (context.halfDuplex) {
              context.wakeEnabled = true;
              effects.add(const EnableWake(true));
            }
          }
        }
      default:
        break;
    }
  }

  Transition _fatalError(AttentionState from, List<Effect> effects) {
    effects.add(const LogAttention('fatal_error', 'Fatal error, resetting'));
    _returnAmbient(effects, closeSession: true);
    context.wakeEnabled = true;
    effects.add(const EnableWake(true));
    return Transition(
      from: from,
      to: context.state,
      effects: effects,
      context: context,
    );
  }

  void _enterEngaged(
    List<Effect> effects, {
    required String userid,
    required bool guest,
  }) {
    context.state = const Engaged();
    context.engagedEnteredAtMs = context.clock.nowMs;
    _cacheIdentity(guest ? null : userid);
    context.sessionOpen = true;
    // Block wake/VAD until greeter TTS finishes (HDMI echo otherwise
    // pulls us into Listening and swallows speak.ended).
    if (!guest) {
      context.playing = true;
    }
    effects.add(OpenSession(userid: userid, guest: guest));
    if (!guest) {
      effects.add(RunGreeter(userid));
    }
    effects.add(SetVisionFps(context.config.vision.engagedFps));
  }

  void _enterListening(
    List<Effect> effects, {
    bool openGuestSession = false,
    String? userid,
  }) {
    context.state = const Listening();
    context.turnId = _uuid.v4();
    context.listeningStartedAtMs = context.clock.nowMs;
    context.sttPending = false;
    context.followUpOpen = false;
    context.followUpListening = false;

    if (openGuestSession) {
      context.sessionOpen = true;
      context.cachedUserid = userid;
      effects.add(OpenSession(userid: userid ?? 'guest', guest: true));
    } else if (!context.sessionOpen) {
      context.sessionOpen = true;
      effects.add(
        OpenSession(
          userid: context.cachedUserid ?? 'guest',
          guest: context.cachedUserid == null,
        ),
      );
    }

    if (context.halfDuplex) {
      context.wakeEnabled = false;
      effects.add(const EnableWake(false));
    }

    effects.add(StartListening(context.turnId!));
  }

  /// Follow-up window already started the mic — flip to Listening without
  /// clearing PCM / restarting the streamer.
  void _promoteFollowUpListening(List<Effect> effects) {
    context.state = const Listening();
    context.sttPending = false;
    context.followUpOpen = false;
    context.followUpListening = false;
    context.listeningStartedAtMs = context.clock.nowMs;
    if (context.turnId == null) {
      context.turnId = _uuid.v4();
    }
    if (context.halfDuplex) {
      context.wakeEnabled = false;
      effects.add(const EnableWake(false));
    }
    effects.add(const PromoteListening());
    effects.add(
      EmitState(
        context.state.name,
        userid: context.cachedUserid,
        displayName: context.cachedUserid,
      ),
    );
  }

  void _leaveListeningToEngaged(List<Effect> effects) {
    context.state = const Engaged();
    context.turnId = null;
    context.sttPending = false;
    context.followUpListening = false;
    if (context.halfDuplex) {
      context.wakeEnabled = true;
      effects.add(const EnableWake(true));
    }
  }

  void _leaveRespondingToEngaged(List<Effect> effects) {
    context.state = const Engaged();
    context.turnId = null;
    context.playing = false;
    effects.add(const SetThinking(false));
  }

  void _returnAmbient(List<Effect> effects, {required bool closeSession}) {
    context.state = const Ambient();
    context.turnId = null;
    context.sttPending = false;
    context.playing = false;
    context.followUpOpen = false;
    context.directAgentInFlight = false;
    context.absentFrames = 0;
    if (closeSession && context.sessionOpen) {
      context.sessionOpen = false;
      context.cachedUserid = null;
      context.identityExpiresAtMs = null;
      effects.add(const CloseSession());
    }
    effects.add(SetVisionFps(context.config.vision.ambientFps));
  }

  void _cacheIdentity(String? userid) {
    if (userid == null) return;
    context.cachedUserid = userid;
    context.identityExpiresAtMs = context.clock.nowMs +
        context.config.vision.identityTtlSeconds * 1000;
  }
}
