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

  String? get resolvedUserid => isResolved ? _resolvedUserid : null;

  bool get isResolved =>
      _resolvedUserid != null &&
      _expiresAtMs != null &&
      clock.nowMs < _expiresAtMs!;

  bool get isExpired =>
      _resolvedUserid == null ||
      _expiresAtMs == null ||
      clock.nowMs >= _expiresAtMs!;

  bool get needsRecognition => !isResolved;

  /// Positive recognition refreshes TTL; person detection alone does not.
  IdentityVoteResult recordMatch(String userid, double confidence) {
    if (confidence < config.faceConfidence || ! _isKnownUserid(userid)) {
      _resetVotes();
      return const IdentityVoteUnknown();
    }

    if (_pendingUserid == userid) {
      _voteCount++;
    } else {
      _pendingUserid = userid;
      _voteCount = 1;
    }

    if (_voteCount >= config.recognizeVotes) {
      _resolvedUserid = userid;
      _expiresAtMs = clock.nowMs + config.identityTtlSeconds * 1000;
      _resetVotes();
      return IdentityVoteRecognized(userid, confidence);
    }

    return const IdentityVotePending();
  }

  IdentityVoteResult recordUnknown() {
    _resetVotes();
    return const IdentityVoteUnknown();
  }

  /// Person presence alone must not extend identity TTL.
  void onPersonDetected() {}

  void clear() {
    _resolvedUserid = null;
    _expiresAtMs = null;
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
