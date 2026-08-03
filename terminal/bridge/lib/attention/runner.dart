import 'package:comstar_bridge/attention/effects.dart';
import 'package:comstar_bridge/log.dart';

/// Dispatches attention machine effects to subsystems.
///
/// [AttentionCoordinator] calls [dispatch] for logging/tracking, then executes
/// service I/O (session, STT, TTS, WebSocket) in its own effect handler.
class EffectRunner {
  EffectRunner({
    this.onSetVisionFps,
    this.onOpenSession,
    this.onCloseSession,
    this.onStartListening,
    this.onStopListening,
    this.onFinalizeCapture,
    this.onCallStt,
    this.onCallDirectAgent,
    this.onSetThinking,
    this.onSpeak,
    this.onSpeakFallback,
    this.onPlayErrorTone,
    this.onEnableWake,
    this.onOpenFollowUpWindow,
    this.onPromoteListening,
    this.onRunGreeter,
    this.onEmitState,
    this.onEnteredSleep,
    this.onExitedSleep,
  });

  final void Function(double fps)? onSetVisionFps;
  final void Function(String userid, bool guest)? onOpenSession;
  final void Function()? onCloseSession;
  final void Function(String turnId)? onStartListening;
  final void Function()? onStopListening;
  final void Function()? onFinalizeCapture;
  final void Function(String turnId)? onCallStt;
  final void Function(String text, String turnId)? onCallDirectAgent;
  final void Function(bool active)? onSetThinking;
  final void Function(String text, String audioUrl, String turnId)? onSpeak;
  final void Function(String line, String turnId)? onSpeakFallback;
  final void Function()? onPlayErrorTone;
  final void Function(bool enabled)? onEnableWake;
  final void Function()? onOpenFollowUpWindow;
  final void Function()? onPromoteListening;
  final void Function(String userid)? onRunGreeter;
  final void Function(String state, String? userid, String? displayName)?
      onEmitState;
  final void Function()? onEnteredSleep;
  final void Function()? onExitedSleep;

  final dispatched = <Effect>[];

  void dispatchAll(List<Effect> effects) {
    for (final effect in effects) {
      dispatch(effect);
    }
  }

  void dispatch(Effect effect) {
    dispatched.add(effect);
    switch (effect) {
      case SetVisionFps(:final fps):
        onSetVisionFps?.call(fps);
        logDebug('effect', 'SetVisionFps', data: {'fps': fps});
      case OpenSession(:final userid, :final guest):
        onOpenSession?.call(userid, guest);
        logDebug('effect', 'OpenSession', data: {
          'userid': userid,
          'guest': guest,
        });
      case CloseSession():
        onCloseSession?.call();
        logDebug('effect', 'CloseSession');
      case StartListening(:final turnId):
        onStartListening?.call(turnId);
        logDebug('effect', 'StartListening', data: {'turn_id': turnId});
      case StopListening():
        onStopListening?.call();
        logDebug('effect', 'StopListening');
      case FinalizeCapture():
        onFinalizeCapture?.call();
        logDebug('effect', 'FinalizeCapture');
      case CallStt(:final turnId):
        onCallStt?.call(turnId);
        logDebug('effect', 'CallStt', data: {'turn_id': turnId});
      case CallDirectAgent(:final text, :final turnId):
        onCallDirectAgent?.call(text, turnId);
        logDebug('effect', 'CallDirectAgent', data: {'turn_id': turnId});
      case SetThinking(:final active):
        onSetThinking?.call(active);
        logDebug('effect', 'SetThinking', data: {'active': active});
      case Speak(:final text, :final audioUrl, :final turnId):
        onSpeak?.call(text, audioUrl, turnId);
        logDebug('effect', 'Speak', data: {'turn_id': turnId});
      case SpeakFallback(:final line, :final turnId):
        onSpeakFallback?.call(line, turnId);
        logDebug('effect', 'SpeakFallback', data: {'turn_id': turnId});
      case PlayErrorTone():
        onPlayErrorTone?.call();
        logDebug('effect', 'PlayErrorTone');
      case EnableWake(:final enabled):
        onEnableWake?.call(enabled);
        logDebug('effect', 'EnableWake', data: {'enabled': enabled});
      case OpenFollowUpWindow():
        onOpenFollowUpWindow?.call();
        logDebug('effect', 'OpenFollowUpWindow');
      case PromoteListening():
        onPromoteListening?.call();
        logDebug('effect', 'PromoteListening');
      case RunGreeter(:final userid):
        onRunGreeter?.call(userid);
        logDebug('effect', 'RunGreeter', data: {'userid': userid});
      case EmitState(:final stateName, :final userid, :final displayName):
        onEmitState?.call(stateName, userid, displayName);
        logDebug('effect', 'EmitState', data: {'state': stateName});
      case EnteredSleep():
        onEnteredSleep?.call();
        logDebug('effect', 'EnteredSleep');
      case ExitedSleep():
        onExitedSleep?.call();
        logDebug('effect', 'ExitedSleep');
      case LogAttention(:final evt, :final msg, :final data):
        logWarn(evt, msg, data: data);
    }
  }
}
