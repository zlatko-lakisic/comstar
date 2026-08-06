/// Attention machine inputs per CONTRACTS §8.
library;

import 'package:comstar_bridge/attention/presence.dart';

export 'package:comstar_bridge/attention/presence.dart' show PresenceEntry;

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
  const FaceRecognized(
    this.userid,
    this.confidence, {
    this.displayName,
    this.faceId,
  });

  /// FreeIPA uid (AO session identity) after directory resolve.
  final String userid;
  final double confidence;

  /// LDAP displayName/cn when known; else null (machine falls back to userid).
  final String? displayName;

  /// Biometric CPAI faceId when it differs from [userid].
  final String? faceId;
}

final class FaceUnknown extends AttentionEvent {
  const FaceUnknown();
}

/// Multi-face presence update (Phase 2). Singular [FaceRecognized] remains for compat.
final class PresenceSet extends AttentionEvent {
  const PresenceSet(this.people, {this.primaryUserid});
  final List<PresenceEntry> people;
  final String? primaryUserid;
}

final class PresencePrimaryChanged extends AttentionEvent {
  const PresencePrimaryChanged({required this.from, required this.to});
  final String? from;
  final String to;
}

final class WakeWord extends AttentionEvent {
  const WakeWord(this.score, {this.prompt});
  final double score;

  /// Remainder after the wake phrase in the same sleep-verify utterance.
  /// When non-null and non-empty, the machine runs it as the turn promptly
  /// instead of opening an empty follow-up listen.
  final String? prompt;
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

/// Terminal MCP / control HTTP requested dormant mode.
final class EnterSleep extends AttentionEvent {
  const EnterSleep();
}

/// Control HTTP requested leave sleep without a wake word.
final class ExitSleep extends AttentionEvent {
  const ExitSleep();
}
