/// Announcement delivery gate stub for the text channel surface (M11.6).
///
/// Full dual-surface gate lives with M10's announce queue on the bridge.
/// This documents the channel-side policy and provides a pure function for
/// unit tests until bridge ↔ channel coordination is wired.
library;

/// Priority matching M10 announcement priorities.
enum AnnouncePriority { normal, urgent }

/// Inputs for channel delivery decision.
class ChannelAnnounceContext {
  const ChannelAnnounceContext({
    required this.recipientUserid,
    required this.priority,
    required this.recipientPresentAtTerminal,
    required this.alreadyDelivered,
  });

  final String recipientUserid;
  final AnnouncePriority priority;

  /// True when the attention machine has this userid engaged (or equivalent).
  final bool recipientPresentAtTerminal;

  /// True when either surface already marked this announcement delivered.
  final bool alreadyDelivered;
}

/// Channel delivery decision.
enum ChannelDeliverDecision {
  /// Do not send on channel (terminal wins, or hold, or already delivered).
  skip,

  /// Deliver on channel now.
  deliver,

  /// Hold for terminal until TTL (normal + absent); channel does not fire.
  holdForTerminal,
}

/// M11.6 policy:
/// - Recipient present at terminal → terminal wins; channel does not also fire.
/// - Recipient absent, urgent → deliver to channel.
/// - Recipient absent, normal → hold for terminal until TTL, then drop.
/// - Already delivered on either surface → skip.
ChannelDeliverDecision shouldDeliverToChannel(ChannelAnnounceContext ctx) {
  if (ctx.alreadyDelivered) return ChannelDeliverDecision.skip;
  if (ctx.recipientPresentAtTerminal) return ChannelDeliverDecision.skip;
  if (ctx.priority == AnnouncePriority.urgent) {
    return ChannelDeliverDecision.deliver;
  }
  return ChannelDeliverDecision.holdForTerminal;
}
