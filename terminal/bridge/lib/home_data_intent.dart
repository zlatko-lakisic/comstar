/// Local Home Assistant data intents (bridge-owned; bypass slow AO HA MCP).
enum HomeDataIntentKind { torrentsDownloading }

class HomeDataIntent {
  const HomeDataIntent(this.kind);
  final HomeDataIntentKind kind;
}

/// Returns a [HomeDataIntent] when [text] asks about HA-backed household data
/// we can answer quickly without CrewAI tool loops.
HomeDataIntent? parseHomeDataIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;

  if (RegExp(
        r'\b(torrents?|torrenting|qbittorrent|q bit torrent)\b|'
        r'\b(downloads?|downloading)\b.*\b(torrent|qbittorrent|seed|leech)\b|'
        r'\bwhat.*(download|torrent)|'
        r'\b(any|which|how many)\b.*\b(torrents?|downloads?)\b',
      ).hasMatch(t)) {
    return const HomeDataIntent(HomeDataIntentKind.torrentsDownloading);
  }

  return null;
}
