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
  });

  final String uid;
  final String displayName;
  final String haEntity;
  final String state;

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'displayName': displayName,
        'ha_entity': haEntity,
        'state': state,
      };
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
    final map = resolvedHaPersonByUid(directoryOverlay: directoryOverlay);
    final people = <HousePresencePerson>[];
    for (final entry in map.entries) {
      final uid = entry.key;
      final entity = entry.value;
      final stateMap = await _ha.entityState(entity);
      final state = stateMap?['state']?.toString().trim();
      final friendly = stateMap?['attributes'] is Map
          ? (stateMap!['attributes'] as Map)['friendly_name']?.toString().trim()
          : null;
      people.add(
        HousePresencePerson(
          uid: uid,
          displayName: (friendly != null && friendly.isNotEmpty) ? friendly : uid,
          haEntity: entity,
          state: (state == null || state.isEmpty) ? 'unknown' : state,
        ),
      );
    }
    return {
      'ts': clock.nowMs,
      'people': people.map((p) => p.toJson()).toList(),
    };
  }

  /// Spoken “who’s home” summary for [HomeDataIntentKind.presenceHome].
  Future<String?> spokenSummary({
    Map<String, String> directoryOverlay = const {},
  }) async {
    final snap = await snapshot(directoryOverlay: directoryOverlay);
    final raw = snap['people'];
    if (raw is! List || raw.isEmpty) {
      return 'I do not have anyone mapped for house presence yet.';
    }
    final home = <String>[];
    final away = <String>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final name = item['displayName']?.toString() ?? item['uid']?.toString() ?? '';
      if (name.isEmpty) continue;
      final state = (item['state']?.toString() ?? '').toLowerCase();
      if (state == 'home' || state == 'Home') {
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
      return 'Nobody on the mapped list is marked home right now.';
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
}
