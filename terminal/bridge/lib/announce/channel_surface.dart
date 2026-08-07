/// Dual-surface announcement gate for the bridge (M11.6).
///
/// Mirrors `channel/lib/announce_gate.dart` so the Pi owns delivered-once truth
/// without importing the Ada package. Keep both in sync (CONTRACTS §11).
library;

import 'package:comstar_bridge/announce/types.dart';

/// Channel delivery decision.
enum ChannelDeliverDecision {
  skip,
  deliver,
  holdForTerminal,
}

/// M11.6 policy — see CONTRACTS §11.
ChannelDeliverDecision shouldDeliverToChannel({
  required String recipientUserid,
  required AnnouncementPriority priority,
  required bool recipientPresentAtTerminal,
  required bool alreadyDelivered,
}) {
  if (alreadyDelivered) return ChannelDeliverDecision.skip;
  if (recipientPresentAtTerminal) return ChannelDeliverDecision.skip;
  if (priority == AnnouncementPriority.urgent) {
    return ChannelDeliverDecision.deliver;
  }
  return ChannelDeliverDecision.holdForTerminal;
}

/// True when the attention machine has [userid] in an identified turn.
bool recipientPresentAtTerminal({
  required String? cachedUserid,
  required String stateName,
  required String recipient,
}) {
  if (recipient.trim().isEmpty || recipient == 'any') return false;
  if (cachedUserid == null || cachedUserid.isEmpty) return false;
  if (cachedUserid != recipient) return false;
  switch (stateName) {
    case 'engaged':
    case 'listening':
    case 'responding':
      return true;
    default:
      return false;
  }
}
