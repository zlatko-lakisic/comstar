import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/ha_agent_client.dart';

/// One person in the house-wide presence snapshot (CONTRACTS §7b).
class HousePresencePerson {
  const HousePresencePerson({
    required this.uid,
    required this.displayName,
    required this.haEntity,
    required this.state,
    this.source,
    this.inZones = const [],
  });

  final String uid;
  final String displayName;
  final String haEntity;
  final String state;
  final String? source;
  final List<String> inZones;

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'displayName': displayName,
        'ha_entity': haEntity,
        'state': state,
        if (source != null) 'source': source,
        if (inZones.isNotEmpty) 'in_zones': inZones,
      };
}

/// Result of a named "where is X?" lookup against HA person entities.
class WhereIsLookup {
  const WhereIsLookup({
    required this.matched,
    required this.displayName,
    required this.state,
    required this.spoken,
    required this.liveKnown,
    this.haEntity,
  });

  final bool matched;
  final String displayName;
  final String state;
  final String spoken;

  /// False when HA has no useful live location (`unknown` / empty).
  final bool liveKnown;
  final String? haEntity;
}

/// Builds `GET /v1/presence/home` payloads from config + HA entity states.
class HousePresenceService {
  HousePresenceService({
    required this.config,
    required this.clock,
    HaAgentClient? ha,
  }) : _ha = ha ?? HaAgentClient();

  final PresenceConfig config;
  final Clock clock;
  final HaAgentClient _ha;

  /// Merge yaml map with optional directory overlays (uid → ha entity).
  /// Directory values fill gaps only; yaml wins on conflict.
  Map<String, String> resolvedHaPersonByUid({
    Map<String, String> directoryOverlay = const {},
  }) {
    final out = Map<String, String>.from(directoryOverlay);
    out.addAll(config.haPersonByUid);
    return out;
  }

  Future<Map<String, dynamic>> snapshot({
    Map<String, String> directoryOverlay = const {},
  }) async {
    final people = await _loadPeople(directoryOverlay: directoryOverlay);
    return {
      'ts': clock.nowMs,
      'people': people.map((p) => p.toJson()).toList(),
    };
  }

  Future<List<HousePresencePerson>> _loadPeople({
    Map<String, String> directoryOverlay = const {},
  }) async {
    final map = resolvedHaPersonByUid(directoryOverlay: directoryOverlay);
    // Deduplicate by entity_id (zlatko + zlatko.lakisic → same person).
    final seenEntity = <String>{};
    final people = <HousePresencePerson>[];
    for (final entry in map.entries) {
      final uid = entry.key;
      final entity = entry.value;
      if (!seenEntity.add(entity)) continue;
      final stateMap = await _ha.entityState(entity);
      people.add(_personFromEntityState(
        uid: uid,
        entity: entity,
        stateMap: stateMap,
      ));
    }

    // Auto-discover Assist-exposed person.* so yaml is optional for where-is.
    // Yaml/directory mappings win on entity_id conflict (aliases + attrs).
    final discovered = await _ha.listEntities(domain: 'person', summaryOnly: true);
    for (final row in discovered) {
      final entity = row['entity_id']?.toString().trim() ?? '';
      if (entity.isEmpty || !entity.startsWith('person.')) continue;
      if (seenEntity.contains(entity)) continue;
      final friendly = row['friendly_name']?.toString().trim() ?? '';
      if (!_isTrackablePerson(entity, friendly)) continue;
      if (!seenEntity.add(entity)) continue;
      final state = row['state']?.toString().trim();
      final uid = entity.substring('person.'.length);
      people.add(
        HousePresencePerson(
          uid: uid,
          displayName: friendly.isNotEmpty ? friendly : uid,
          haEntity: entity,
          state: (state == null || state.isEmpty) ? 'unknown' : state,
        ),
      );
    }
    return people;
  }

  static HousePresencePerson _personFromEntityState({
    required String uid,
    required String entity,
    required Map<String, dynamic>? stateMap,
  }) {
    final state = stateMap?['state']?.toString().trim();
    final attrs = stateMap?['attributes'] is Map
        ? Map<String, dynamic>.from(stateMap!['attributes'] as Map)
        : const <String, dynamic>{};
    final friendly = attrs['friendly_name']?.toString().trim();
    final source = attrs['source']?.toString().trim();
    final zonesRaw = attrs['in_zones'];
    final zones = <String>[];
    if (zonesRaw is List) {
      for (final z in zonesRaw) {
        final s = z.toString().trim();
        if (s.isNotEmpty) zones.add(s);
      }
    }
    return HousePresencePerson(
      uid: uid,
      displayName: (friendly != null && friendly.isNotEmpty) ? friendly : uid,
      haEntity: entity,
      state: (state == null || state.isEmpty) ? 'unknown' : state,
      source: (source == null || source.isEmpty) ? null : source,
      inZones: zones,
    );
  }

  /// Skip HA "person" entities that are speakers / service accounts, not people.
  static bool _isTrackablePerson(String entityId, String friendlyName) {
    final id = entityId.toLowerCase();
    final name = friendlyName.toLowerCase().trim();
    if (_skipPersonEntities.contains(id)) return false;
    if (name == 'google home' || name.endsWith(' google home')) return false;
    if (name == 'md-admin' || id == 'person.md_admin') return false;
    return true;
  }

  static const _skipPersonEntities = {
    'person.google_home',
    'person.md_admin',
  };

  /// Spoken “who’s home” summary for [HomeDataIntentKind.presenceHome].
  Future<String?> spokenSummary({
    Map<String, String> directoryOverlay = const {},
  }) async {
    final people = await _loadPeople(directoryOverlay: directoryOverlay);
    if (people.isEmpty) {
      return 'I could not find any Home Assistant people to look up right now.';
    }
    final home = <String>[];
    final away = <String>[];
    for (final p in people) {
      final name = p.displayName;
      if (name.isEmpty) continue;
      final state = p.state.toLowerCase();
      if (state == 'home') {
        home.add(name);
      } else if (state == 'unknown') {
        // skip unknowns in spoken line
      } else {
        away.add(name);
      }
    }
    if (home.isEmpty && away.isEmpty) {
      return 'I could not read Home Assistant person states right now.';
    }
    if (home.isEmpty) {
      return 'Nobody I can track is marked home right now.';
    }
    if (home.length == 1) {
      return '${home.first} is home.';
    }
    if (home.length == 2) {
      return '${home[0]} and ${home[1]} are home.';
    }
    final head = home.sublist(0, home.length - 1).join(', ');
    return '$head, and ${home.last} are home.';
  }

  /// Resolve a spoken name against mapped HA people and describe location.
  Future<WhereIsLookup> whereIs(
    String nameQuery, {
    Map<String, String> directoryOverlay = const {},
  }) async {
    final query = nameQuery.trim();
    if (query.isEmpty) {
      return const WhereIsLookup(
        matched: false,
        displayName: '',
        state: 'unknown',
        spoken: 'Who should I look up?',
        liveKnown: false,
      );
    }

    final people = await _loadPeople(directoryOverlay: directoryOverlay);
    if (people.isEmpty) {
      return WhereIsLookup(
        matched: false,
        displayName: query,
        state: 'unknown',
        spoken:
            'I could not find any Home Assistant people to look up right now.',
        liveKnown: false,
      );
    }

    final match = _bestMatch(query, people);
    if (match == null) {
      final known = people.map((p) => p.displayName.split(' ').first).toSet();
      final hint = known.isEmpty
          ? ''
          : ' I can look up ${known.take(4).join(', ')}.';
      return WhereIsLookup(
        matched: false,
        displayName: query,
        state: 'unknown',
        spoken: 'I do not recognize $query among Home Assistant people.$hint',
        liveKnown: false,
      );
    }

    final state = match.state.trim();
    final lower = state.toLowerCase();
    final liveKnown = lower.isNotEmpty && lower != 'unknown' && lower != 'unavailable';
    late final String spoken;
    if (!liveKnown) {
      spoken =
          'Home Assistant does not have a live location for ${match.displayName} right now.';
    } else if (lower == 'home') {
      spoken = '${match.displayName} is home.';
    } else if (lower == 'not_home' || lower == 'away') {
      spoken = '${match.displayName} is away from home.';
    } else {
      // Zone name or custom location string from HA.
      final place = _speakPlace(state);
      spoken = '${match.displayName} is at $place.';
    }

    return WhereIsLookup(
      matched: true,
      displayName: match.displayName,
      state: state,
      spoken: spoken,
      liveKnown: liveKnown,
      haEntity: match.haEntity,
    );
  }

  static String _speakPlace(String state) {
    final s = state.trim();
    if (s.toLowerCase().startsWith('zone.')) {
      return s.substring(5).replaceAll('_', ' ');
    }
    return s.replaceAll('_', ' ');
  }

  static HousePresencePerson? _bestMatch(
    String query,
    List<HousePresencePerson> people,
  ) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return null;

    HousePresencePerson? best;
    var bestScore = 0;
    for (final p in people) {
      final score = _matchScore(q, p);
      if (score > bestScore) {
        bestScore = score;
        best = p;
      }
    }
    // Require at least first-name containment / soft match.
    return bestScore >= 50 ? best : null;
  }

  static int _matchScore(String q, HousePresencePerson p) {
    final display = p.displayName.toLowerCase();
    final uid = p.uid.toLowerCase();
    final tokens = display.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    if (display == q || uid == q) return 100;
    if (tokens.contains(q)) return 90;
    if (display.startsWith('$q ')) return 85;
    if (uid.startsWith(q)) return 80;
    // Soft first-name (Adna / Anna).
    final first = tokens.isEmpty ? '' : tokens.first;
    if (first.length >= 3 && q.length >= 3 && _editDistance(q, first) <= 1) {
      return 70;
    }
    if (display.contains(q) && q.length >= 3) return 60;
    return 0;
  }

  static int _editDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      cur[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a[i] == b[j] ? 0 : 1;
        cur[j + 1] = [
          cur[j] + 1,
          prev[j + 1] + 1,
          prev[j] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      for (var j = 0; j < prev.length; j++) {
        prev[j] = cur[j];
      }
    }
    return prev[b.length];
  }
}
