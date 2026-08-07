import 'package:comstar_bridge/geocode/nominatim_client.dart';

/// How precisely we describe someone's location relative to home.
enum LocationSpeechTier {
  home,
  namedZone,
  local,
  sameState,
  otherState,
  otherCountry,
  awayUnknown,
}

/// Pure helpers for presence location speech (CONTRACTS §7b).
class PresenceLocationSpeech {
  /// Local POI / street detail when within this distance of home.
  static const localKm = 12.0;

  static LocationSpeechTier tier({
    required String haState,
    required List<String> inZones,
    GeoPlace? person,
    GeoPlace? home,
    double? distanceKm,
    String? namedZoneLabel,
  }) {
    final lower = haState.trim().toLowerCase();
    if (lower == 'home' || inZones.any((z) => z.toLowerCase() == 'zone.home')) {
      return LocationSpeechTier.home;
    }
    if (namedZoneLabel != null && namedZoneLabel.trim().isNotEmpty) {
      return LocationSpeechTier.namedZone;
    }
    if (person == null) return LocationSpeechTier.awayUnknown;

    final homeCc = home?.countryCode?.toLowerCase();
    final personCc = person.countryCode?.toLowerCase();
    if (homeCc != null &&
        personCc != null &&
        homeCc.isNotEmpty &&
        personCc.isNotEmpty &&
        homeCc != personCc) {
      return LocationSpeechTier.otherCountry;
    }

    final homeState = _normRegion(home?.state);
    final personState = _normRegion(person.state);
    if (homeState != null &&
        personState != null &&
        homeState != personState) {
      return LocationSpeechTier.otherState;
    }

    if (distanceKm != null && distanceKm <= localKm) {
      return LocationSpeechTier.local;
    }
    return LocationSpeechTier.sameState;
  }

  static String speakWhere({
    required String displayName,
    required LocationSpeechTier tier,
    String? namedZoneLabel,
    GeoPlace? person,
  }) {
    final name = displayName.trim().isEmpty ? 'They' : displayName.trim();
    switch (tier) {
      case LocationSpeechTier.home:
        return '$name is home.';
      case LocationSpeechTier.namedZone:
        final place = _title(namedZoneLabel ?? 'a saved place');
        return '$name is at $place.';
      case LocationSpeechTier.local:
        return '$name is at ${_localPhrase(person)}.';
      case LocationSpeechTier.sameState:
        final city = _cityPhrase(person) ?? 'another part of the area';
        return '$name went to $city.';
      case LocationSpeechTier.otherState:
        final city = person?.locality;
        final state = person?.state;
        if (city != null && state != null) {
          return '$name went to $city, $state.';
        }
        if (state != null) return '$name went to $state.';
        if (city != null) return '$name went to $city.';
        return '$name is away in another state.';
      case LocationSpeechTier.otherCountry:
        final city = person?.locality;
        final country = person?.country;
        if (city != null && country != null) {
          return '$name is in $city, $country.';
        }
        if (country != null) return '$name is in $country.';
        if (city != null) return '$name is in $city.';
        return '$name is abroad.';
      case LocationSpeechTier.awayUnknown:
        return '$name is away from home.';
    }
  }

  /// Last transition from `home` → not home in chronological history rows.
  static DateTime? lastLeftHomeAt(List<Map<String, dynamic>> history) {
    if (history.isEmpty) return null;
    final sorted = [...history]..sort((a, b) {
        final ta = _parseHaTime(a['last_changed']?.toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        final tb = _parseHaTime(b['last_changed']?.toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        return ta.compareTo(tb);
      });

    String? prev;
    DateTime? leftAt;
    for (final row in sorted) {
      final state = row['state']?.toString().trim().toLowerCase() ?? '';
      final when = _parseHaTime(row['last_changed']?.toString());
      if (prev == 'home' &&
          state.isNotEmpty &&
          state != 'home' &&
          state != 'unknown' &&
          state != 'unavailable' &&
          when != null) {
        leftAt = when;
      }
      if (state.isNotEmpty) prev = state;
    }
    return leftAt;
  }

  static String speakLeft({
    required String displayName,
    required String haState,
    DateTime? leftAt,
    DateTime? now,
  }) {
    final name = displayName.trim().isEmpty ? 'They' : displayName.trim();
    final lower = haState.trim().toLowerCase();
    if (lower == 'home') {
      return '$name is home — they have not left.';
    }
    if (leftAt == null) {
      return 'I do not have a clear leave time for $name in recent Home Assistant history.';
    }
    final when = formatSpokenWhen(leftAt, now: now ?? DateTime.now().toUtc());
    return '$name left home $when.';
  }

  /// Relative / clock phrasing in the terminal's local timezone.
  static String formatSpokenWhen(DateTime utc, {DateTime? now}) {
    final local = utc.toLocal();
    final n = (now ?? DateTime.now().toUtc()).toLocal();
    final time = _clock(local);
    final dayStart = DateTime(n.year, n.month, n.day);
    final localDay = DateTime(local.year, local.month, local.day);
    final dayDiff = dayStart.difference(localDay).inDays;
    if (dayDiff == 0) return 'today at $time';
    if (dayDiff == 1) return 'yesterday at $time';
    if (dayDiff > 1 && dayDiff < 7) {
      return 'on ${_weekday(local.weekday)} at $time';
    }
    return 'on ${_month(local.month)} ${local.day} at $time';
  }

  static String _localPhrase(GeoPlace? p) {
    if (p == null) return 'a nearby place';
    final poi = p.placeName;
    final road = p.road;
    final area = _areaLabel(p);
    if (poi != null && road != null && area != null) {
      return 'the $poi on $road in $area';
    }
    if (poi != null && area != null) return 'the $poi in $area';
    if (poi != null && road != null) return 'the $poi on $road';
    if (poi != null) return 'the $poi';
    if (road != null && area != null) return '$road in $area';
    if (area != null) return area;
    if (road != null) return road;
    return 'a nearby place';
  }

  static String? _cityPhrase(GeoPlace? p) {
    if (p == null) return null;
    return p.city ?? p.town ?? p.village ?? p.suburb;
  }

  static String? _areaLabel(GeoPlace? p) {
    if (p == null) return null;
    final muni = p.municipality;
    if (muni != null) {
      // "Town of Greenburgh" → "Greenburgh"
      final stripped = muni
          .replaceFirst(RegExp(r'^(town|city|village|township)\s+of\s+', caseSensitive: false), '')
          .trim();
      if (stripped.isNotEmpty) return stripped;
    }
    return p.suburb ?? p.town ?? p.city ?? p.neighbourhood;
  }

  static String? _normRegion(String? s) {
    final t = s?.trim().toLowerCase();
    if (t == null || t.isEmpty) return null;
    return t;
  }

  static String _title(String s) {
    final t = s.trim();
    if (t.toLowerCase().startsWith('zone.')) {
      return t.substring(5).replaceAll('_', ' ');
    }
    return t.replaceAll('_', ' ');
  }

  static DateTime? _parseHaTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  static String _clock(DateTime dt) {
    var h = dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final am = h < 12;
    final suffix = am ? 'AM' : 'PM';
    h = h % 12;
    if (h == 0) h = 12;
    if (dt.minute == 0) return '$h $suffix';
    return '$h:$m $suffix';
  }

  static String _weekday(int w) {
    const names = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[(w - 1).clamp(0, 6)];
  }

  static String _month(int m) {
    const names = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return names[(m - 1).clamp(0, 11)];
  }
}
