import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/geocode/nominatim_client.dart';
import 'package:comstar_bridge/ha_agent_client.dart';
import 'package:comstar_bridge/house_presence.dart';
import 'package:comstar_bridge/presence_location.dart';

/// Rich where-is / leave-time answers using HA GPS + reverse geocode.
class PresenceLocationService {
  PresenceLocationService({
    required this.config,
    required this.clock,
    HaAgentClient? ha,
    NominatimClient? geocode,
  })  : _ha = ha ?? HaAgentClient(),
        _geocode = geocode ?? NominatimClient();

  final PresenceConfig config;
  final Clock clock;
  final HaAgentClient _ha;
  final NominatimClient _geocode;

  HousePresenceService get _people => HousePresenceService(
        config: config,
        clock: clock,
        ha: _ha,
      );

  Future<WhereIsLookup> whereIs(
    String nameQuery, {
    Map<String, String> directoryOverlay = const {},
  }) async {
    final base = await _people.whereIs(
      nameQuery,
      directoryOverlay: directoryOverlay,
    );
    if (!base.matched || base.haEntity == null) return base;
    if (!base.liveKnown) return base;

    final full = await _ha.entityState(base.haEntity!);
    final state = full?['state']?.toString().trim() ?? base.state;
    final attrs = full?['attributes'] is Map
        ? Map<String, dynamic>.from(full!['attributes'] as Map)
        : const <String, dynamic>{};
    final inZones = <String>[];
    final zonesRaw = attrs['in_zones'];
    if (zonesRaw is List) {
      for (final z in zonesRaw) {
        final s = z.toString().trim();
        if (s.isNotEmpty) inZones.add(s);
      }
    }

    final lat = _asDouble(attrs['latitude']);
    final lon = _asDouble(attrs['longitude']);
    final namedZone = _namedZoneLabel(state, inZones);

    GeoPlace? homePlace;
    GeoPlace? personPlace;
    double? distanceKm;
    final home = await _homeCoords();
    if (home != null) {
      homePlace = await _geocode.reverse(home.$1, home.$2);
    }
    if (lat != null && lon != null) {
      personPlace = await _geocode.reverse(lat, lon);
      if (home != null) {
        distanceKm = haversineKm(home.$1, home.$2, lat, lon);
      }
      // Prefer a non-home HA zone containing this GPS point.
      final zoneHit = await _zoneContaining(lat, lon);
      if (zoneHit != null && namedZone == null) {
        final tier = PresenceLocationSpeech.tier(
          haState: state,
          inZones: inZones,
          namedZoneLabel: zoneHit,
        );
        final spoken = PresenceLocationSpeech.speakWhere(
          displayName: base.displayName,
          tier: tier,
          namedZoneLabel: zoneHit,
        );
        return WhereIsLookup(
          matched: true,
          displayName: base.displayName,
          state: state,
          spoken: spoken,
          liveKnown: true,
          haEntity: base.haEntity,
        );
      }
    }

    final tier = PresenceLocationSpeech.tier(
      haState: state,
      inZones: inZones,
      person: personPlace,
      home: homePlace,
      distanceKm: distanceKm,
      namedZoneLabel: namedZone,
    );
    final spoken = PresenceLocationSpeech.speakWhere(
      displayName: base.displayName,
      tier: tier,
      namedZoneLabel: namedZone,
      person: personPlace,
    );
    return WhereIsLookup(
      matched: true,
      displayName: base.displayName,
      state: state,
      spoken: spoken,
      liveKnown: true,
      haEntity: base.haEntity,
    );
  }

  Future<WhereIsLookup> whenLeft(
    String nameQuery, {
    Map<String, String> directoryOverlay = const {},
    Duration lookback = const Duration(days: 30),
  }) async {
    final base = await _people.whereIs(
      nameQuery,
      directoryOverlay: directoryOverlay,
    );
    if (!base.matched || base.haEntity == null) {
      return base;
    }

    final full = await _ha.entityState(base.haEntity!);
    final state = full?['state']?.toString().trim() ?? base.state;
    final start = DateTime.now().toUtc().subtract(lookback);
    final history = await _ha.entityHistory(
      base.haEntity!,
      start: start,
      minimalResponse: true,
    );
    final leftAt = PresenceLocationSpeech.lastLeftHomeAt(history);
    final spoken = PresenceLocationSpeech.speakLeft(
      displayName: base.displayName,
      haState: state,
      leftAt: leftAt,
      now: DateTime.fromMillisecondsSinceEpoch(clock.nowMs, isUtc: true),
    );
    return WhereIsLookup(
      matched: true,
      displayName: base.displayName,
      state: state,
      spoken: spoken,
      liveKnown: true,
      haEntity: base.haEntity,
    );
  }

  Future<(double, double)?> _homeCoords() async {
    final zones = await _ha.listZones();
    for (final z in zones) {
      final id = z['entity_id']?.toString() ?? '';
      if (id != 'zone.home' && z['name']?.toString().toLowerCase() != 'home') {
        continue;
      }
      final lat = _asDouble(z['latitude']);
      final lon = _asDouble(z['longitude']);
      if (lat != null && lon != null) return (lat, lon);
    }
    final state = await _ha.entityState('zone.home');
    final attrs = state?['attributes'] is Map
        ? Map<String, dynamic>.from(state!['attributes'] as Map)
        : const <String, dynamic>{};
    final lat = _asDouble(attrs['latitude']);
    final lon = _asDouble(attrs['longitude']);
    if (lat != null && lon != null) return (lat, lon);
    return null;
  }

  Future<String?> _zoneContaining(double lat, double lon) async {
    final zones = await _ha.listZones();
    String? bestName;
    var bestRadius = double.infinity;
    for (final z in zones) {
      final id = z['entity_id']?.toString() ?? '';
      final name = z['name']?.toString().trim() ?? '';
      if (id == 'zone.home' || name.toLowerCase() == 'home') continue;
      final zLat = _asDouble(z['latitude']);
      final zLon = _asDouble(z['longitude']);
      final radiusM = _asDouble(z['radius']) ?? 100;
      if (zLat == null || zLon == null) continue;
      final distM = haversineKm(lat, lon, zLat, zLon) * 1000;
      if (distM <= radiusM && radiusM < bestRadius) {
        bestRadius = radiusM;
        bestName = name.isNotEmpty
            ? name
            : id.replaceFirst('zone.', '').replaceAll('_', ' ');
      }
    }
    return bestName;
  }

  static String? _namedZoneLabel(String state, List<String> inZones) {
    final lower = state.trim().toLowerCase();
    if (lower == 'home' || lower == 'not_home' || lower == 'away') {
      for (final z in inZones) {
        final zl = z.toLowerCase();
        if (zl == 'zone.home' || zl == 'home') continue;
        return z;
      }
      return null;
    }
    if (lower == 'unknown' || lower == 'unavailable') return null;
    return state;
  }

  static double? _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }
}
