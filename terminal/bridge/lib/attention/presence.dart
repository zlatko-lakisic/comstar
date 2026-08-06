/// Terminal multi-user presence (CONTRACTS §8 Phase 2).
class PresenceEntry {
  const PresenceEntry({
    required this.userid,
    required this.confidence,
    required this.seenAtMs,
    this.displayName,
    this.faceId,
    this.guest = false,
  });

  final String userid;
  final double confidence;
  final int seenAtMs;
  final String? displayName;
  final String? faceId;
  final bool guest;

  PresenceEntry copyWith({
    double? confidence,
    int? seenAtMs,
    String? displayName,
    String? faceId,
  }) =>
      PresenceEntry(
        userid: userid,
        confidence: confidence ?? this.confidence,
        seenAtMs: seenAtMs ?? this.seenAtMs,
        displayName: displayName ?? this.displayName,
        faceId: faceId ?? this.faceId,
        guest: guest,
      );

  Map<String, dynamic> toJson() => {
        'userid': userid,
        'confidence': confidence,
        'seenAtMs': seenAtMs,
        if (displayName != null) 'displayName': displayName,
        if (faceId != null) 'faceId': faceId,
        'guest': guest,
      };
}

/// Select primary: highest confidence among non-expired, non-guest preferred.
String? selectPrimaryUserid(
  Map<String, PresenceEntry> presence, {
  required int nowMs,
  required int ttlMs,
}) {
  PresenceEntry? bestKnown;
  PresenceEntry? bestGuest;
  for (final e in presence.values) {
    if (nowMs - e.seenAtMs > ttlMs) continue;
    if (e.guest) {
      if (bestGuest == null || e.confidence > bestGuest.confidence) {
        bestGuest = e;
      }
    } else {
      if (bestKnown == null || e.confidence > bestKnown.confidence) {
        bestKnown = e;
      }
    }
  }
  return bestKnown?.userid ?? bestGuest?.userid;
}

List<PresenceEntry> prunePresence(
  Map<String, PresenceEntry> presence, {
  required int nowMs,
  required int ttlMs,
}) {
  final keep = <String, PresenceEntry>{};
  for (final e in presence.entries) {
    if (nowMs - e.value.seenAtMs <= ttlMs) {
      keep[e.key] = e.value;
    }
  }
  presence
    ..clear()
    ..addAll(keep);
  return keep.values.toList()
    ..sort((a, b) => b.confidence.compareTo(a.confidence));
}
