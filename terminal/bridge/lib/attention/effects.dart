/// Side effects returned as data from the pure attention machine.
sealed class Effect {
  const Effect();
}

final class SetVisionFps extends Effect {
  const SetVisionFps(this.fps);
  final double fps;
}

final class OpenSession extends Effect {
  const OpenSession({required this.userid, this.guest = false});
  final String userid;
  final bool guest;
}

final class CloseSession extends Effect {
  const CloseSession();
}

final class StartListening extends Effect {
  const StartListening(this.turnId);
  final String turnId;
}

final class StopListening extends Effect {
  const StopListening();
}

final class FinalizeCapture extends Effect {
  const FinalizeCapture();
}

final class CallStt extends Effect {
  const CallStt(this.turnId);
  final String turnId;
}

final class CallDirectAgent extends Effect {
  const CallDirectAgent(this.text, this.turnId);
  final String text;
  final String turnId;
}

final class SetThinking extends Effect {
  const SetThinking(this.active);
  final bool active;
}

final class Speak extends Effect {
  const Speak({required this.text, required this.audioUrl, required this.turnId});
  final String text;
  final String audioUrl;
  final String turnId;
}

final class SpeakFallback extends Effect {
  const SpeakFallback(this.line, this.turnId);
  final String line;
  final String turnId;
}

final class PlayErrorTone extends Effect {
  const PlayErrorTone();
}

final class EnableWake extends Effect {
  const EnableWake(this.enabled);
  final bool enabled;
}

final class OpenFollowUpWindow extends Effect {
  const OpenFollowUpWindow();
}

final class RunGreeter extends Effect {
  const RunGreeter(this.userid);
  final String userid;
}

final class EmitState extends Effect {
  const EmitState(this.stateName, {this.userid, this.displayName});
  final String stateName;
  final String? userid;
  final String? displayName;
}

final class LogAttention extends Effect {
  const LogAttention(this.evt, this.msg, {this.data});
  final String evt;
  final String msg;
  final Map<String, dynamic>? data;
}
