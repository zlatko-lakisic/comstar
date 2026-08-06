import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/attention/clock.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/log.dart';

/// FreeIPA person resolved from a biometric modality id (CONTRACTS §3b).
class PersonProfile {
  const PersonProfile({
    required this.uid,
    required this.displayName,
    this.groups = const [],
    this.dn,
    this.faceId,
    this.voiceId,
    this.haPerson,
  });

  final String uid;
  final String displayName;
  final List<String> groups;
  final String? dn;
  final String? faceId;
  final String? voiceId;

  /// Optional FreeIPA `comstarHaPerson` → HA `person.*` (P2.3 IPA→HA map).
  final String? haPerson;

  factory PersonProfile.fromJson(Map<String, dynamic> json) {
    final uid = json['uid']?.toString().trim() ?? '';
    if (uid.isEmpty) {
      throw const FormatException('directory profile missing uid');
    }
    final display = json['displayName']?.toString().trim();
    final groupsRaw = json['groups'];
    final groups = <String>[];
    if (groupsRaw is List) {
      for (final g in groupsRaw) {
        final s = g.toString().trim();
        if (s.isNotEmpty) groups.add(s);
      }
    }
    return PersonProfile(
      uid: uid,
      displayName: (display == null || display.isEmpty) ? uid : display,
      groups: groups,
      dn: json['dn']?.toString(),
      faceId: json['faceId']?.toString(),
      voiceId: json['voiceId']?.toString(),
      haPerson: json['haPerson']?.toString() ?? json['ha_person']?.toString(),
    );
  }
}

sealed class DirectoryResolveResult {
  const DirectoryResolveResult();
}

final class DirectoryResolved extends DirectoryResolveResult {
  const DirectoryResolved(this.profile);
  final PersonProfile profile;
}

final class DirectoryMiss extends DirectoryResolveResult {
  const DirectoryMiss();
}

final class DirectoryError extends DirectoryResolveResult {
  const DirectoryError(this.message);
  final String message;
}

/// Resolves biometric faceId → FreeIPA PersonProfile with short TTL cache.
class DirectoryResolver {
  DirectoryResolver({
    required this.config,
    required this.clock,
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient();

  final DirectoryConfig config;
  final Clock clock;
  final HttpClient _http;

  final Map<String, _CacheEntry> _cache = {};

  /// Drop cached entries (identity clear / tests).
  void clearCache() => _cache.clear();

  Future<DirectoryResolveResult> resolveByFaceId(String faceId) async {
    final key = faceId.trim();
    if (key.isEmpty || key == 'unknown') {
      return const DirectoryMiss();
    }

    if (!config.enabled) {
      return DirectoryResolved(
        PersonProfile(uid: key, displayName: key, faceId: key),
      );
    }

    return _resolveModality(cacheKey: 'f:$key', queryParam: 'face_id', value: key);
  }

  /// Resolve FreeIPA person by enrolled speaker id (`comstarVoiceId`).
  Future<DirectoryResolveResult> resolveByVoiceId(String voiceId) async {
    final key = voiceId.trim();
    if (key.isEmpty || key == 'unknown') {
      return const DirectoryMiss();
    }

    if (!config.enabled) {
      return DirectoryResolved(
        PersonProfile(uid: key, displayName: key, voiceId: key),
      );
    }

    return _resolveModality(cacheKey: 'v:$key', queryParam: 'voice_id', value: key);
  }

  Future<DirectoryResolveResult> _resolveModality({
    required String cacheKey,
    required String queryParam,
    required String value,
  }) async {
    final cached = _cache[cacheKey];
    if (cached != null && clock.nowMs < cached.expiresAtMs) {
      return DirectoryResolved(cached.profile);
    }

    final base = config.sidecarUrl.replaceAll(RegExp(r'/$'), '');
    final uri = Uri.parse('$base/v1/resolve').replace(
      queryParameters: {queryParam: value},
    );

    try {
      final req = await _http.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final resp = await req.close().timeout(
        Duration(milliseconds: config.timeoutMs),
      );
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 404) {
        return const DirectoryMiss();
      }
      if (resp.statusCode >= 500) {
        logWarn('directory_error', 'sidecar ${resp.statusCode}', data: {
          queryParam: value,
          'body': body.length > 200 ? body.substring(0, 200) : body,
        });
        return DirectoryError('sidecar_${resp.statusCode}');
      }
      if (resp.statusCode != 200) {
        return DirectoryError('sidecar_${resp.statusCode}');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return const DirectoryError('invalid_json');
      }
      final profile = PersonProfile.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      _cache[cacheKey] = _CacheEntry(
        profile: profile,
        expiresAtMs: clock.nowMs + config.cacheTtlSeconds * 1000,
      );
      return DirectoryResolved(profile);
    } on TimeoutException {
      logWarn('directory_timeout', 'resolve timed out', data: {queryParam: value});
      return const DirectoryError('timeout');
    } catch (e) {
      logWarn('directory_error', e.toString(), data: {queryParam: value});
      return DirectoryError(e.toString());
    }
  }
}

class _CacheEntry {
  _CacheEntry({required this.profile, required this.expiresAtMs});
  final PersonProfile profile;
  final int expiresAtMs;
}
