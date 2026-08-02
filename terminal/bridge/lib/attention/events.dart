/// Attention machine inputs per CONTRACTS §8.
sealed class AttentionEvent {
  const AttentionEvent();
}

final class PersonDetected extends AttentionEvent {
  const PersonDetected(this.confidence);
  final double confidence;
}

final class PersonAbsent extends AttentionEvent {
  const PersonAbsent();
}

final class FaceRecognized extends AttentionEvent {
  const FaceRecognized(this.userid, this.confidence);
  final String userid;
  final double confidence;
}

final class FaceUnknown extends AttentionEvent {
  const FaceUnknown();
}

final class WakeWord extends AttentionEvent {
  const WakeWord(this.score);
  final double score;
}

final class SpeechStart extends AttentionEvent {
  const SpeechStart();
}

final class SpeechEnd extends AttentionEvent {
  const SpeechEnd(this.durationMs);
  final int durationMs;
}

final class TranscriptReady extends AttentionEvent {
  const TranscriptReady(this.text);
  final String text;
}

final class ResponseReady extends AttentionEvent {
  const ResponseReady(this.text, this.audioUrl);
  final String text;
  final String audioUrl;
}

final class PlaybackEnded extends AttentionEvent {
  const PlaybackEnded();
}

final class Tick extends AttentionEvent {
  const Tick();
}

final class AttentionError extends AttentionEvent {
  const AttentionError(this.scope, {this.fatal = true});
  final String scope;
  final bool fatal;
}

final class VisionDegraded extends AttentionEvent {
  const VisionDegraded();
}

final class VisionRecovered extends AttentionEvent {
  const VisionRecovered();
}
