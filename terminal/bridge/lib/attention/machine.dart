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
    this.followUpMicArmedAtMs,
    this.absentFrames = 0,
    this.personPresent = false,
    this.gazeDetected = false,
    this.cachedUserid,
    this.cachedDisplayName,
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
  /// When follow-up listen.start was sent — SpeechStart ignored until settle after this.
  int? followUpMicArmedAtMs;
  int absentFrames;
  bool personPresent;
  bool gazeDetected;
  String? cachedUserid;
  String? cachedDisplayName;
  int? identityExpiresAtMs;
  int listeningStartedAtMs;
  int respondingStartedAtMs;
  int engagedEnteredAtMs;
  bool sttPending;

  bool get halfDuplex => config.audio.duplex == 'half';

  bool get identityExpired =>
      identityExpiresAtMs == null || clock.nowMs >= identityExpiresAtMs!;

  /// Mic is live and VAD settle has elapsed — safe to promote on SpeechStart.
  bool get followUpArmed =>
      followUpMicArmedAtMs != null &&
      clock.nowMs - followUpMicArmedAtMs! >= 2000;

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
        followUpMicArmedAtMs: followUpMicArmedAtMs,
        absentFrames: absentFrames,
        personPresent: personPresent,
        gazeDetected: gazeDetected,
        cachedUserid: cachedUserid,
        cachedDisplayName: cachedDisplayName,
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

    if (event is EnterSleep) {
      if (context.state is! Sleeping) {
        _enterSleep(effects);
      }
    } else {
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
        case Sleeping():
          _handleSleeping(event, effects);
      }

      if (context.state is! Sleeping) {
        _handleGlobalVision(event, effects);
      }
    }

    final to = context.state;
    if (from.name != to.name) {
      effects.add(
        EmitState(
          to.name,
          userid: context.cachedUserid,
          displayName: context.cachedDisplayName ?? context.cachedUserid,
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
      case FaceRecognized(:final userid, :final confidence, :final displayName):
        if (confidence >= context.config.vision.faceConfidence) {
          _enterEngaged(
            effects,
            userid: userid,
            guest: false,
            displayName: displayName,
          );
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
      case FaceRecognized(:final userid, :final confidence, :final displayName):
        if (confidence >= context.config.vision.faceConfidence) {
          _cacheIdentity(userid, displayName: displayName);
        }
      case WakeWord():
        // Ignore mic triggers while we are still playing (HDMI echo of TTS).
        if (context.playing) {
          break;
        }
        // Mic already armed while face-engaged — wait for VAD SpeechStart.
        // Energy/force wake false-triggers on room noise right after arming.
        if (context.followUpListening) {
          break;
        }
        _enterListening(effects);
      case SpeechStart():
        // Face-engaged = addressable. Real speech (not greeter) starts a turn.
        if (context.playing) {
          break;
        }
        if (context.followUpListening) {
          if (!context.followUpArmed) {
            break;
          }
          _promoteFollowUpListening(effects);
        } else {
          _enterListening(effects);
        }
      case PlaybackEnded():
        // Greeter/reply finished — arm the mic for VAD only. Do not treat
        // greeter as a listen trigger; SpeechStart from the camera+mic path does.
        context.playing = false;
        if (context.halfDuplex) {
          context.wakeEnabled = true;
          effects.add(const EnableWake(true));
        }
        // Ignore duplicate speak.ended after watchdog / settle already armed.
        if (!context.followUpListening && !context.followUpOpen) {
          context.followUpOpen = true;
          context.followUpOpenedAtMs = context.clock.nowMs;
          effects.add(const OpenFollowUpWindow());
        }
      case ResponseReady(:final text, :final audioUrl):
        // Late AO / fallback reply after timeout already left Responding.
        if (context.playing) break;
        context.turnId ??= _uuid.v4();
        context.playing = context.halfDuplex;
        if (context.halfDuplex) {
          context.wakeEnabled = false;
          effects.add(const EnableWake(false));
        }
        context.state = const Responding();
        effects.add(
          Speak(
            text: text,
            audioUrl: audioUrl,
            turnId: context.turnId!,
          ),
        );
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
        // Drop the bad turn and re-arm VAD while face-engaged.
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
          // Silence/miss — stay face-engaged and re-arm VAD (no greeter gate).
          _leaveListeningToEngaged(effects);
          effects.add(const StopListening());
          context.followUpOpen = true;
          context.followUpOpenedAtMs = context.clock.nowMs;
          effects.add(const OpenFollowUpWindow());
        } else {
          context.state = const Responding();
          context.respondingStartedAtMs = context.clock.nowMs;
          context.directAgentInFlight = true;
          // Mic off for the whole think+speak half-duplex turn. Wake stays
          // armed per invariants until ResponseReady sets playing.
          context.wakeEnabled = true;
          effects.add(const EnableWake(true));
          effects.add(const StopListening());
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
          // AO + Home Assistant tool turns often exceed the chat timeout (15s).
          // Keep waiting long enough that SpeakFallback does not fire mid-call
          // and leave Responding before the real reply arrives.
          final configuredMs =
              context.config.orchestration.timeoutSeconds * 1000;
          final timeoutMs =
              configuredMs < 90000 ? 90000 : configuredMs;
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

  void _handleSleeping(AttentionEvent event, List<Effect> effects) {
    switch (event) {
      case WakeWord():
        // Confirmed hey comstar — leave sleep and arm Listening for the prompt
        // (verify already consumed the wake utterance).
        effects.add(const ExitedSleep());
        _wakeFromSleepToReady(effects);
      case ExitSleep():
        effects.add(const ExitedSleep());
        _wakeFromSleepToReady(effects);
      case ResponseReady(:final text, :final audioUrl):
        // Sleep ack TTS ("going to sleep") — stay Sleeping; kiosk must not
        // brighten to responding while this plays.
        context.playing = true;
        context.wakeEnabled = false;
        effects.add(const EnableWake(false));
        effects.add(
          Speak(
            text: text,
            audioUrl: audioUrl,
            turnId: context.turnId ?? 'sleep-ack',
          ),
        );
      case PlaybackEnded():
        // Sleep TTS / greeter race disabled wake via Speak; restore it.
        context.playing = false;
        context.wakeEnabled = true;
        effects.add(const EnableWake(true));
      default:
        // Vision, VAD, follow-up — ignored while dormant.
        break;
    }
  }

  /// After sleep: Engaged if a session is open, else Ambient.
  /// With an open session, immediately arm follow-up Listening for the prompt.
  void _wakeFromSleepToReady(List<Effect> effects) {
    if (context.sessionOpen) {
      context.state = const Engaged();
      context.turnId = null;
      context.sttPending = false;
      context.playing = false;
      context.followUpOpen = false;
      context.followUpListening = false;
      context.followUpOpenedAtMs = null;
      context.followUpMicArmedAtMs = null;
      context.wakeEnabled = true;
      effects.add(const EnableWake(true));
      effects.add(SetVisionFps(context.config.vision.engagedFps));
      effects.add(
        EmitState(
          context.state.name,
          userid: context.cachedUserid,
          displayName: context.cachedDisplayName ?? context.cachedUserid,
        ),
      );
      // No TTS settle — wake verify already finished; listen for the prompt now.
      effects.add(const OpenFollowUpWindow(settleMs: 0));
    } else {
      _returnAmbient(effects, closeSession: false);
      context.wakeEnabled = true;
      effects.add(const EnableWake(true));
    }
  }

  void _enterSleep(List<Effect> effects) {
    final stopMic = context.state is Listening || context.followUpListening;
    if (stopMic) {
      effects.add(const StopListening());
    }
    if (context.state is Responding || context.directAgentInFlight) {
      context.directAgentInFlight = false;
      effects.add(const SetThinking(false));
    }
    context.state = const Sleeping();
    context.turnId = null;
    context.sttPending = false;
    // Keep playing as-is: greeter/sleep TTS may still be on the speaker.
    // Clearing it here re-armed wake mid-TTS so HDMI echo looked like speech.
    context.followUpOpen = false;
    context.followUpListening = false;
    context.followUpOpenedAtMs = null;
    context.followUpMicArmedAtMs = null;
    if (context.playing) {
      context.wakeEnabled = false;
      effects.add(const EnableWake(false));
    } else {
      context.wakeEnabled = true;
      effects.add(const EnableWake(true));
    }
    effects.add(const EnteredSleep());
    effects.add(SetVisionFps(context.config.vision.ambientFps));
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
    String? displayName,
  }) {
    context.state = const Engaged();
    context.engagedEnteredAtMs = context.clock.nowMs;
    _cacheIdentity(
      guest ? null : userid,
      displayName: guest ? null : displayName,
    );
    context.sessionOpen = true;
    // Block wake/VAD until greeter TTS finishes (HDMI echo otherwise
    // pulls us into Listening and swallows speak.ended).
    if (!guest) {
      context.playing = true;
      if (context.halfDuplex) {
        context.wakeEnabled = false;
        effects.add(const EnableWake(false));
      }
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
    context.followUpMicArmedAtMs = null;
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
        displayName: context.cachedDisplayName ?? context.cachedUserid,
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
    if (context.halfDuplex) {
      context.wakeEnabled = true;
      effects.add(const EnableWake(true));
    }
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
      context.cachedDisplayName = null;
      context.identityExpiresAtMs = null;
      effects.add(const CloseSession());
    }
    effects.add(SetVisionFps(context.config.vision.ambientFps));
  }

  void _cacheIdentity(String? userid, {String? displayName}) {
    if (userid == null) return;
    context.cachedUserid = userid;
    context.cachedDisplayName =
        (displayName != null && displayName.isNotEmpty) ? displayName : userid;
    context.identityExpiresAtMs = context.clock.nowMs +
        context.config.vision.identityTtlSeconds * 1000;
  }
}
