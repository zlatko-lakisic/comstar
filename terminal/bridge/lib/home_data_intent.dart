/// Local Home Assistant data intents (bridge-owned; bypass flaky AO HA MCP loops).
enum HomeDataIntentKind {
  torrentsDownloading,
  irrigationSummary,
  networkSummary,
  presenceHome,
}

class HomeDataIntent {
  const HomeDataIntent(this.kind, {this.query = ''});
  final HomeDataIntentKind kind;

  /// Original normalized text — used for network sub-routing (WAN vs LAN vs speed).
  final String query;
}

/// Returns a [HomeDataIntent] when [text] asks about HA-backed household data
/// we can answer from entity state without CrewAI tool stalls.
HomeDataIntent? parseHomeDataIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;

  // Who's home / anyone home — before network (no IP conflict).
  // Apostrophes are stripped above, so "who's" → "who s".
  if (RegExp(
        r'\bwho\s+s\s+(home|here)\b|'
        r'\bwho\s+is\s+(home|here)\b|'
        r'\bwho\s+are\s+(home|here)\b|'
        r'\banyone\s+(home|here)\b|'
        r'\bwho\s+s\s+at\s+home\b|'
        r'\bwho\s+is\s+at\s+home\b|'
        r'\bhouse\s+presence\b|'
        r'\bwho\s+is\s+in\s+the\s+house\b',
      ).hasMatch(t)) {
    return HomeDataIntent(HomeDataIntentKind.presenceHome, query: t);
  }

  // Network before torrents — "download speed" must not match torrent heuristics.
  if (RegExp(
        r'\b(wan|public)\s*ip\b|'
        r'\b(local|lan)\s*ip\b|'
        r'\bhome assistant\b.*\bip\b|'
        r'\bip\b.*\b(home assistant|ha)\b|'
        r'\b(my|the|our)\s+(ip|ip address)\b|'
        r'\bip address\b|'
        r'\bspeed\s*test\b|'
        r'\b(download|upload)\s+speed\b|'
        r'\b(bandwidth|mikrotik|wireguard|vlan)\b|'
        r'\bwifi\s+clients\b|'
        r'\b(wireless|wired)\s+clients\b|'
        r'\b(network|router|interface)\b.*\b(speed|bandwidth|rate|clients|ip)\b|'
        r'\b(speed|bandwidth|rate|clients|ip)\b.*\b(network|router|interface|mikrotik)\b|'
        r'\bmostar\b.*\b(ip|public)\b|'
        r'\b(public|wan)\b.*\bmostar\b',
      ).hasMatch(t)) {
    return HomeDataIntent(HomeDataIntentKind.networkSummary, query: t);
  }

  if (RegExp(
        r'\b(torrents?|torrenting|qbittorrent|q bit torrent)\b|'
        r'\b(downloads?|downloading)\b.*\b(torrent|qbittorrent|seed|leech)\b|'
        r'\bwhat.*(torrent)|'
        r'\b(any|which|how many)\b.*\b(torrents?|downloads?)\b',
      ).hasMatch(t)) {
    return HomeDataIntent(HomeDataIntentKind.torrentsDownloading, query: t);
  }

  // Irrigation / watering amounts — AO HA MCP often skips tools or stalls on
  // "Please provide the tool result…"; read sensors directly via HA agent.
  if (RegExp(
        r'\b(irrigation|watering|watered|sprinkler|sprinklers)\b|'
        r'\bhow much water\b|'
        r'\b(garden|lawn|east lawn|front yard|back lawn)\b.*\b(water|irrigation|watering)\b|'
        r'\b(water|irrigation|watering)\b.*\b(garden|lawn|home|yesterday|week)\b',
      ).hasMatch(t)) {
    return HomeDataIntent(HomeDataIntentKind.irrigationSummary, query: t);
  }

  return null;
}
