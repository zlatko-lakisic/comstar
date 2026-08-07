import 'dart:convert';
import 'dart:math' as math;

import 'package:comstar_bridge/log.dart';
import 'package:http/http.dart' as http;

/// Reverse-geocode result from Nominatim (OpenStreetMap).
class GeoPlace {
  const GeoPlace({
    this.name,
    this.amenity,
    this.road,
    this.neighbourhood,
    this.suburb,
    this.city,
    this.town,
    this.village,
    this.municipality,
    this.county,
    this.state,
    this.country,
    this.countryCode,
    this.displayName,
  });

  final String? name;
  final String? amenity;
  final String? road;
  final String? neighbourhood;
  final String? suburb;
  final String? city;
  final String? town;
  final String? village;
  final String? municipality;
  final String? county;
  final String? state;
  final String? country;
  final String? countryCode;
  final String? displayName;

  /// Best single locality label (city / town / suburb).
  String? get locality {
    for (final c in [city, town, village, suburb, neighbourhood]) {
      if (c != null && c.trim().isNotEmpty) return c.trim();
    }
    return null;
  }

  /// Prefer a named POI (shop, library, etc.) when Nominatim provides one.
  String? get placeName {
    for (final c in [name, amenity]) {
      if (c != null && c.trim().isNotEmpty) return c.trim();
    }
    return null;
  }

  factory GeoPlace.fromNominatim(Map<String, dynamic> json) {
    final addr = json['address'] is Map
        ? Map<String, dynamic>.from(json['address'] as Map)
        : const <String, dynamic>{};
    String? s(String key) {
      final v = addr[key]?.toString().trim();
      return (v == null || v.isEmpty) ? null : v;
    }

    return GeoPlace(
      name: () {
        final n = json['name']?.toString().trim();
        return (n == null || n.isEmpty) ? null : n;
      }(),
      amenity: s('amenity') ?? s('shop') ?? s('tourism') ?? s('leisure'),
      road: s('road'),
      neighbourhood: s('neighbourhood') ?? s('neighborhood'),
      suburb: s('suburb'),
      city: s('city'),
      town: s('town'),
      village: s('village'),
      municipality: s('municipality'),
      county: s('county'),
      state: s('state'),
      country: s('country'),
      countryCode: s('country_code')?.toLowerCase(),
      displayName: json['display_name']?.toString(),
    );
  }
}

/// Cached Nominatim reverse geocoder (1 req/sec policy — we cache aggressively).
class NominatimClient {
  NominatimClient({
    http.Client? httpClient,
    this.userAgent = 'COMSTAR/1.0 (hallway presence; local LAN)',
  }) : _http = httpClient ?? http.Client();

  final http.Client _http;
  final String userAgent;
  final Map<String, GeoPlace> _cache = {};

  /// Round coords to ~110 m so nearby polls share a cache entry.
  static String cacheKey(double lat, double lon) {
    final rLat = (lat * 1000).round() / 1000;
    final rLon = (lon * 1000).round() / 1000;
    return '$rLat,$rLon';
  }

  Future<GeoPlace?> reverse(double lat, double lon) async {
    final key = cacheKey(lat, lon);
    final hit = _cache[key];
    if (hit != null) return hit;

    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'lat': lat.toString(),
      'lon': lon.toString(),
      'format': 'jsonv2',
      'addressdetails': '1',
      'zoom': '18',
    });
    try {
      final resp = await _http
          .get(uri, headers: {'User-Agent': userAgent, 'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        logWarn('nominatim_http', 'reverse failed', data: {
          'status': resp.statusCode,
        });
        return null;
      }
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map) return null;
      if (decoded['error'] != null) return null;
      final place = GeoPlace.fromNominatim(Map<String, dynamic>.from(decoded));
      _cache[key] = place;
      return place;
    } catch (e) {
      logWarn('nominatim_http', e.toString());
      return null;
    }
  }

  void close() => _http.close();
}

/// Great-circle distance in kilometers.
double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final p1 = lat1 * math.pi / 180;
  final p2 = lat2 * math.pi / 180;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.asin(math.sqrt(a));
}
