import 'package:comstar_bridge/announce/types.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:comstar_bridge/log.dart';

/// Why the gate held (or null if deliver).
enum GateHoldReason {
  ambient,
  noticed,
  listening,
  responding,
  sleeping,
  identityMismatch,
  quietHours,
  alreadyAnnouncedThisEngage,
  noDue,
  playing,
}

/// Result of evaluating the delivery gate (M10.3).
class GateDecision {
  const GateDecision.hold(this.reason)
      : deliver = false,
        items = const [];

  const GateDecision.deliver(this.items)
      : deliver = true,
        reason = null;

  final bool deliver;
  final GateHoldReason? reason;
  final List<Announcement> items;

  String get reasonWire => reason?.name ?? 'deliver';
}

/// Coalesce up to [maxItems] announcements into one spoken line.
String coalesceAnnouncementText(List<Announcement> items, {int maxItems = 3}) {
  if (items.isEmpty) return '';
  final texts = items
      .map((a) => (a.text?.trim().isNotEmpty == true) ? a.text!.trim() : a.intent.trim())
      .where((t) => t.isNotEmpty)
      .toList();
  if (texts.isEmpty) return '';
  if (texts.length == 1) return texts.first;
  final take = texts.take(maxItems).toList();
  final extra = texts.length - take.length;
  final body = take.join('. ');
  if (extra <= 0) return body.endsWith('.') ? body : '$body.';
  return '${body.endsWith('.') ? body.substring(0, body.length - 1) : body}, and a few other things.';
}

/// Pure delivery gate — sources enqueue; this decides speak (ADR 0009 / M10.3).
class AnnouncementGate {
  AnnouncementGate({
    this.quietStartHour = 22,
    this.quietStartMinute = 0,
    this.quietEndHour = 7,
    this.quietEndMinute = 0,
  });

  final int quietStartHour;
  final int quietStartMinute;
  final int quietEndHour;
  final int quietEndMinute;

  /// Parse `HH:MM` into hour/minute; returns null on failure.
  static (int, int)? parseHm(String raw) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(raw.trim());
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!);
    final min = int.tryParse(m.group(2)!);
    if (h == null || min == null || h > 23 || min > 59) return null;
    return (h, min);
  }

  factory AnnouncementGate.fromQuietStrings({
    required String start,
    required String end,
  }) {
    final s = parseHm(start) ?? (22, 0);
    final e = parseHm(end) ?? (7, 0);
    return AnnouncementGate(
      quietStartHour: s.$1,
      quietStartMinute: s.$2,
      quietEndHour: e.$1,
      quietEndMinute: e.$2,
    );
  }

  bool isQuietHours(DateTime localNow) {
    final nowM = localNow.hour * 60 + localNow.minute;
    final startM = quietStartHour * 60 + quietStartMinute;
    final endM = quietEndHour * 60 + quietEndMinute;
    if (startM == endM) return false;
    if (startM < endM) {
      return nowM >= startM && nowM < endM;
    }
    // Wraps midnight (e.g. 22:00–07:00).
    return nowM >= startM || nowM < endM;
  }

  /// Evaluate whether [due] may be spoken now.
  ///
  /// [userid] is the engaged primary identity (null in noticed/ambient).
  /// [announcedThisEngage] enforces invariant 8.
  GateDecision evaluate({
    required AttentionState state,
    required String? userid,
    required bool guest,
    required bool playing,
    required bool announcedThisEngage,
    required List<Announcement> due,
    required DateTime localNow,
    bool logHolds = true,
  }) {
    if (due.isEmpty) {
      return const GateDecision.hold(GateHoldReason.noDue);
    }

    GateDecision hold(GateHoldReason reason) {
      if (logHolds) {
        logInfo('announce_hold', 'Announcement held', data: {
          'reason': reason.name,
          'state': state.runtimeType.toString(),
          'userid': userid,
          'due': due.length,
          'priorities': due.map((d) => d.priority.wire).toList(),
        });
      }
      return GateDecision.hold(reason);
    }

    switch (state) {
      case Ambient():
        return hold(GateHoldReason.ambient);
      case Noticed():
        // Security boundary: identity unresolved — never deliver.
        return hold(GateHoldReason.noticed);
      case Listening():
        return hold(GateHoldReason.listening);
      case Responding():
        return hold(GateHoldReason.responding);
      case Sleeping():
        return hold(GateHoldReason.sleeping);
      case Engaged():
        break;
    }

    if (playing) {
      return hold(GateHoldReason.playing);
    }
    if (announcedThisEngage) {
      return hold(GateHoldReason.alreadyAnnouncedThisEngage);
    }
    if (guest || userid == null || userid.isEmpty) {
      return hold(GateHoldReason.identityMismatch);
    }

    final matching = due.where((a) {
      final r = a.recipient.trim();
      return r == 'any' || r == userid;
    }).toList();
    if (matching.isEmpty) {
      return hold(GateHoldReason.identityMismatch);
    }

    final quiet = isQuietHours(localNow);
    final deliverable = quiet
        ? matching.where((a) => a.priority == AnnouncementPriority.urgent).toList()
        : matching;
    if (deliverable.isEmpty) {
      return hold(GateHoldReason.quietHours);
    }

    return GateDecision.deliver(deliverable);
  }
}
