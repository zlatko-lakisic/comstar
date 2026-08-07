/// Local Home Assistant data intents (bridge-owned; bypass flaky AO HA MCP loops).
enum HomeDataIntentKind {
  torrentsDownloading,
  irrigationSummary,
  networkSummary,
  presenceHome,
  whereIsPerson,
  whenPersonLeft,
}

class HomeDataIntent {
  const HomeDataIntent(
    this.kind, {
    this.query = '',
    this.personName,
  });
  final HomeDataIntentKind kind;

  /// Original normalized text — used for network sub-routing (WAN vs LAN vs speed).
  final String query;

  /// Spoken name for person lookups (e.g. Adna). Null when pronouns need context.
  final String? personName;
}

/// Returns a [HomeDataIntent] when [text] asks about HA-backed household data
/// we can answer from entity state without CrewAI tool stalls.
HomeDataIntent? parseHomeDataIntent(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r"['\u2019]"), '')
      .replaceAll(RegExp(r'[^\w\s]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;

  final left = _parseWhenPersonLeft(t);
  if (left != null) return left;

  final where = _parseWhereIsPerson(t);
  if (where != null) return where;

  // Who's home / anyone home — before network (no IP conflict).
  // Apostrophes are stripped above, so "who's" → "whos".
  if (RegExp(
        r'\bwhos?\s+(home|here)\b|'
        r'\bwho\s+is\s+(home|here)\b|'
        r'\bwho\s+are\s+(home|here)\b|'
        r'\banyone\s+(home|here)\b|'
        r'\bwhos?\s+at\s+home\b|'
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

HomeDataIntent? _parseWhenPersonLeft(String t) {
  // "when did Adna leave" / "when did they leave home" / "how long has she been gone"
  final patterns = <RegExp>[
    RegExp(
      r'\bwhen\s+did\s+(.+?)\s+leave(?:\s+(?:home|the\s+house|here))?\b',
    ),
    RegExp(
      r'\bwhen\s+did\s+(.+?)\s+go(?:\s+(?:away|out))?\b',
    ),
    RegExp(
      r'\bhow\s+long\s+has\s+(.+?)\s+been\s+(?:gone|away|out)\b',
    ),
    RegExp(
      r'\bwhat\s+time\s+did\s+(.+?)\s+leave(?:\s+(?:home|the\s+house))?\b',
    ),
  ];

  String? raw;
  for (final re in patterns) {
    final m = re.firstMatch(t);
    if (m != null) {
      raw = m.group(1);
      break;
    }
  }
  if (raw == null) return null;

  final name = _cleanPersonName(raw);
  if (name == null) return null;

  // Pronouns → null personName; coordinator fills from last presence lookup.
  if (RegExp(r'^(they|them|she|he|her|him)$').hasMatch(name.toLowerCase())) {
    return HomeDataIntent(
      HomeDataIntentKind.whenPersonLeft,
      query: t,
      personName: null,
    );
  }

  return HomeDataIntent(
    HomeDataIntentKind.whenPersonLeft,
    query: t,
    personName: _titleCaseName(name),
  );
}

HomeDataIntent? _parseWhereIsPerson(String t) {
  // Named person location — not "where's home" / "where is the camera".
  final patterns = <RegExp>[
    RegExp(r'\b(?:where\s+is|wheres|where\s+s)\s+(.+?)(?:\s+right\s+now|\s+now)?$'),
    RegExp(r'\bwhere\s+are\s+(.+?)(?:\s+right\s+now|\s+now)?$'),
    RegExp(r'\bis\s+(.+?)\s+(?:at\s+)?home(?:\s+right\s+now|\s+now)?$'),
    RegExp(r'\bis\s+(.+?)\s+here(?:\s+right\s+now|\s+now)?$'),
    RegExp(r'\bwhere\s+can\s+i\s+find\s+(.+)$'),
  ];

  String? raw;
  for (final re in patterns) {
    final m = re.firstMatch(t);
    if (m != null) {
      raw = m.group(1);
      break;
    }
  }
  if (raw == null) return null;

  final name = _cleanPersonName(raw);
  if (name == null) return null;

  if (RegExp(r'^(they|them|she|he|her|him)$').hasMatch(name.toLowerCase())) {
    return HomeDataIntent(
      HomeDataIntentKind.whereIsPerson,
      query: t,
      personName: null,
    );
  }

  return HomeDataIntent(
    HomeDataIntentKind.whereIsPerson,
    query: t,
    personName: _titleCaseName(name),
  );
}

String? _cleanPersonName(String raw) {
  var name = raw
      .replaceAll(
        RegExp(
          r'\b(right now|now|today|please|at home|in the house|'
          r'located|living|staying|home|the house|here)\b',
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  name = name.replaceFirst(RegExp(r'^(the |a |an |my |our )'), '').trim();
  if (name.isEmpty || name.length < 2) return null;

  // Reject non-person / household aggregate queries.
  if (RegExp(
        r'^(everyone|everybody|anyone|anybody|someone|somebody|'
        r'home|house|camera|driveway|front door|keys|car|wifi|network|'
        r'light|lights|thermostat)$',
      ).hasMatch(name)) {
    return null;
  }
  return name;
}

String _titleCaseName(String name) {
  return name.split(' ').map((w) {
    if (w.isEmpty) return w;
    return '${w[0].toUpperCase()}${w.substring(1)}';
  }).join(' ');
}
