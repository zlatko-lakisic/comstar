/// Local Home Assistant data intents (bridge-owned; bypass flaky AO HA MCP loops).
enum HomeDataIntentKind {
  torrentsDownloading,
  irrigationSummary,
  networkSummary,
  presenceHome,
  whereIsPerson,
  whenPersonLeft,
  familyCar,
  lockStatus,
  garageStatus,
}

class HomeDataIntent {
  const HomeDataIntent(
    this.kind, {
    this.query = '',
    this.personName,
    this.lockKey,
  });
  final HomeDataIntentKind kind;

  /// Original normalized text — used for network sub-routing (WAN vs LAN vs speed).
  final String query;

  /// Spoken name for person lookups (e.g. Adna). Null when pronouns need context.
  final String? personName;

  /// Lock map key: front, office, garage_entry, back, all.
  final String? lockKey;
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

  // Family car / LPR nickname — before person where-is ("where's the family car").
  if (RegExp(
        r'\b(family car|our car|the car|household car)\b|'
        r'\bwhere.*(family )?car\b|'
        r'\b(when|last).*(family )?car\b|'
        r'\bcar (arrive|arrived|leave|left|home|here|in the driveway)\b',
      ).hasMatch(t)) {
    return HomeDataIntent(HomeDataIntentKind.familyCar, query: t);
  }

  // Garage door open/closed (before lock — "garage door").
  if (RegExp(
        r'\bgarage door\b|'
        r'\bis the garage (open|closed|door)\b|'
        r'\b(open|closed).*garage door\b',
      ).hasMatch(t)) {
    return HomeDataIntent(HomeDataIntentKind.garageStatus, query: t);
  }

  final lock = _parseLockStatus(t);
  if (lock != null) return lock;

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

HomeDataIntent? _parseLockStatus(String t) {
  if (!RegExp(r'\b(lock|locked|unlocked|deadbolt)\b').hasMatch(t)) {
    return null;
  }
  final String key;
  if (RegExp(r'\bfront door\b|\bfront lock\b').hasMatch(t)) {
    key = 'front';
  } else if (RegExp(r'\boffice door\b|\boffice lock\b').hasMatch(t)) {
    key = 'office';
  } else if (RegExp(r'\bdoor to garage\b|\bgarage (door )?lock\b').hasMatch(t)) {
    key = 'garage_entry';
  } else if (RegExp(r'\bback door\b|\bback lock\b').hasMatch(t)) {
    key = 'back';
  } else if (RegExp(r'\ball (the )?locks\b|\bdoors locked\b').hasMatch(t)) {
    key = 'all';
  } else {
    key = 'front';
  }
  return HomeDataIntent(HomeDataIntentKind.lockStatus, query: t, lockKey: key);
}

/// HA entity ids for lock status reads (ha_security_voice skill map).
const kHomeLockEntities = <String, String>{
  'front': 'lock.front_door',
  'office': 'lock.office_door',
  'garage_entry': 'lock.door_to_garage',
  'back': 'lock.back_door',
};

const kGarageCoverEntity = 'cover.garage_door_door';
const kFamilyCarLastCamera = 'sensor.frigate_family_car_last_camera';
const kDrivewayCarOccupancy = 'binary_sensor.driveway_car_occupancy';

const kHomeLockLabels = <String, String>{
  'front': 'front door',
  'office': 'office door',
  'garage_entry': 'door to the garage',
  'back': 'back door',
};

String speakLockState(String label, String? state) {
  final s = (state ?? '').toLowerCase().trim();
  if (s == 'locked') return 'The $label is locked.';
  if (s == 'unlocked') return 'The $label is unlocked.';
  if (s.isEmpty || s == 'unavailable' || s == 'unknown') {
    return 'I could not read the $label lock right now.';
  }
  return 'The $label reports $s.';
}

String speakGarageState(String? state) {
  final s = (state ?? '').toLowerCase().trim();
  if (s == 'open' || s == 'opening') return 'The garage door is open.';
  if (s == 'closed' || s == 'closing') return 'The garage door is closed.';
  if (s.isEmpty || s == 'unavailable' || s == 'unknown') {
    return 'I could not read the garage door right now.';
  }
  return 'The garage door reports $s.';
}

String speakFamilyCar({
  required String? lastCamera,
  required String? drivewayOccupancy,
}) {
  final cam = (lastCamera ?? '').trim();
  final occ = (drivewayOccupancy ?? '').toLowerCase().trim();
  if (occ == 'on') {
    return 'The family car looks like it is in the driveway right now.';
  }
  final camKnown = cam.isNotEmpty &&
      cam.toLowerCase() != 'unknown' &&
      cam.toLowerCase() != 'unavailable';
  if (camKnown) {
    return 'The family car was last seen on the $cam camera.';
  }
  if (occ == 'off') {
    return 'The family car is not showing in the driveway right now, '
        'and I do not have a recent Frigate sighting.';
  }
  return 'I could not find a recent sighting of the family car.';
}

HomeDataIntent? _parseWhenPersonLeft(String t) {
  // "when did Adna leave" / "when did they leave home" / "how long has she been gone"
  // Also house presence last-seen: "last time we saw Adna around the house"
  // (HA person history — not Frigate cameras).
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
    RegExp(
      r"\b(?:when\s+(?:was|is)|whats?|what\s+was)\s+the\s+last\s+time\s+"
      r"(?:that\s+)?(?:you|we|i)\s+(?:saw|seen)\s+(.+?)\s+"
      r"(?:around|at|in)\s+(?:the\s+)?(?:house|home)\b",
    ),
    RegExp(
      r'\blast\s+time\s+(?:you|we|i)\s+(?:saw|seen)\s+(.+?)\s+'
      r'(?:around|at|in)\s+(?:the\s+)?(?:house|home)\b',
    ),
    RegExp(
      r'\bwhen\s+was\s+(.+?)\s+last\s+(?:home|at\s+home|in\s+the\s+house|'
      r'around\s+(?:the\s+)?house)\b',
    ),
    RegExp(
      r'\blast\s+time\s+(.+?)\s+was\s+(?:home|at\s+home|in\s+the\s+house|'
      r'around\s+(?:the\s+)?house)\b',
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
          r'around the house|around house|located|living|staying|home|'
          r'the house|here)\b',
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
        r'home|house|camera|driveway|front door|keys|car|family car|'
        r'wifi|network|light|lights|thermostat)$',
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
