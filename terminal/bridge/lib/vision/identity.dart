import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/config.dart';

/// Vote-based face identity resolver (CONTRACTS §8 invariant 5).
class IdentityResolver {
  IdentityResolver({
    required this.config,
    required this.clock,
  });

  final VisionConfig config;
  final Clock clock;

  String? _resolvedUserid;
  int? _expiresAtMs;
  String? _pendingUserid;
  int _voteCount = 0;

  /// When true, keep calling CPAI recognize while a person is present (multi-user).
  bool continuousRecognize = false;

  /// One-shot: next recognize pass must run even if already resolved.
  bool forceRecognizeOnce = false;

  String? get resolvedUserid => isResolved ? _resolvedUserid : null;

  bool get isResolved =>
      _resolvedUserid != null &&
      _expiresAtMs != null &&
      clock.nowMs < _expiresAtMs!;

  bool get isExpired =>
      _resolvedUserid == null ||
      _expiresAtMs == null ||
      clock.nowMs >= _expiresAtMs!;

  bool get needsRecognition =>
      continuousRecognize || forceRecognizeOnce || !isResolved;

  /// Positive recognition refreshes TTL; person detection alone does not.
  IdentityVoteResult recordMatch(String userid, double confidence) {
    if (!_isKnownUserid(userid)) {
      _resetVotes();
      return const IdentityVoteUnknown();
    }

    if (confidence < config.faceConfidence) {
      return const IdentityVotePending();
    }

    // Multi-user / engaged: emit every confident match and refresh TTL.
    if (continuousRecognize && isResolved) {
      if (_resolvedUserid == userid) {
        _expiresAtMs = clock.nowMs + config.identityTtlSeconds * 1000;
      }
      forceRecognizeOnce = false;
      return IdentityVoteRecognized(userid, confidence);
    }

    if (_pendingUserid == userid) {
      _voteCount++;
    } else {
      _pendingUserid = userid;
      _voteCount = 1;
    }

    if (_voteCount >= config.recognizeVotes || forceRecognizeOnce) {
      _resolvedUserid = userid;
      _expiresAtMs = clock.nowMs + config.identityTtlSeconds * 1000;
      forceRecognizeOnce = false;
      _resetVotes();
      return IdentityVoteRecognized(userid, confidence);
    }

    return const IdentityVotePending();
  }

  /// Soft-unknown while already resolved: keep identity, clear only vote progress.
  /// Hard wipe when nothing is resolved (or forced re-identify cleared cache).
  IdentityVoteResult recordUnknown({bool softIfResolved = true}) {
    if (softIfResolved && isResolved && !forceRecognizeOnce) {
      _resetVotes();
      return const IdentityVotePending();
    }
    _resolvedUserid = null;
    _expiresAtMs = null;
    _resetVotes();
    return const IdentityVoteUnknown();
  }

  /// Person presence alone must not extend identity TTL.
  void onPersonDetected() {}

  /// Voice "recognize me" / who-am-I: drop cache and force the next CPAI pass.
  void requestReidentify() {
    clear();
    forceRecognizeOnce = true;
    continuousRecognize = true;
  }

  void clear() {
    _resolvedUserid = null;
    _expiresAtMs = null;
    forceRecognizeOnce = false;
    _resetVotes();
  }

  void _resetVotes() {
    _pendingUserid = null;
    _voteCount = 0;
  }

  bool _isKnownUserid(String userid) =>
      userid.isNotEmpty && userid != 'unknown';
}

sealed class IdentityVoteResult {
  const IdentityVoteResult();
}

final class IdentityVoteRecognized extends IdentityVoteResult {
  const IdentityVoteRecognized(this.userid, this.confidence);
  final String userid;
  final double confidence;
}

final class IdentityVoteUnknown extends IdentityVoteResult {
  const IdentityVoteUnknown();
}

final class IdentityVotePending extends IdentityVoteResult {
  const IdentityVotePending();
}
