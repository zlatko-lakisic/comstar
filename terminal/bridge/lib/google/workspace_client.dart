import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thin Google REST client using env client id/secret + refresh token.
class GoogleWorkspaceClient {
  GoogleWorkspaceClient({
    required this.clientId,
    required this.clientSecret,
    required this.refreshToken,
    http.Client? httpClient,
    this.timeZone = 'America/New_York',
  }) : _http = httpClient ?? http.Client();

  final String clientId;
  final String clientSecret;
  final String refreshToken;
  final String timeZone;
  final http.Client _http;

  String? _accessToken;
  DateTime? _accessExpiresAt;

  Future<String> accessToken() async {
    final exp = _accessExpiresAt;
    final cached = _accessToken;
    if (cached != null &&
        exp != null &&
        DateTime.now().isBefore(exp.subtract(const Duration(seconds: 60)))) {
      return cached;
    }
    final res = await _http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        'client_id': clientId,
        'client_secret': clientSecret,
        'refresh_token': refreshToken,
        'grant_type': 'refresh_token',
      },
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('Google token refresh failed (${res.statusCode}): ${res.body}');
    }
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    final token = map['access_token']?.toString();
    if (token == null || token.isEmpty) {
      throw StateError('Google token refresh missing access_token');
    }
    final expiresIn = (map['expires_in'] as num?)?.toInt() ?? 3600;
    _accessToken = token;
    _accessExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    return token;
  }

  Future<Map<String, String>> _authHeaders() async => {
        'Authorization': 'Bearer ${await accessToken()}',
        'Accept': 'application/json',
      };

  /// Calendar display names (primary first when present).
  Future<List<String>> listCalendarNames({int max = 8}) async {
    final res = await _http.get(
      Uri.parse('https://www.googleapis.com/calendar/v3/users/me/calendarList'),
      headers: await _authHeaders(),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('calendarList failed (${res.statusCode}): ${res.body}');
    }
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    final items = (map['items'] as List?) ?? const [];
    final names = <String>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final summary = raw['summary']?.toString().trim();
      if (summary == null || summary.isEmpty) continue;
      if (raw['primary'] == true) {
        names.insert(0, summary);
      } else {
        names.add(summary);
      }
      if (names.length >= max) break;
    }
    return names;
  }

  /// Event titles on the local calendar day for [timeZone].
  Future<List<String>> listTodayEventTitles({
    String calendarId = 'primary',
    int max = 8,
  }) async {
    final bounds = _localDayBoundsUtcIso();
    final uri = Uri.https(
      'www.googleapis.com',
      '/calendar/v3/calendars/${Uri.encodeComponent(calendarId)}/events',
      {
        'timeMin': bounds.$1,
        'timeMax': bounds.$2,
        'singleEvents': 'true',
        'orderBy': 'startTime',
        'maxResults': '$max',
      },
    );
    final res = await _http.get(uri, headers: await _authHeaders());
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('calendar events failed (${res.statusCode}): ${res.body}');
    }
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    final items = (map['items'] as List?) ?? const [];
    final titles = <String>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final summary = raw['summary']?.toString().trim();
      titles.add((summary == null || summary.isEmpty) ? 'an untitled event' : summary);
      if (titles.length >= max) break;
    }
    return titles;
  }

  Future<int> countDriveFiles({int pageSize = 10}) async {
    final uri = Uri.https(
      'www.googleapis.com',
      '/drive/v3/files',
      {
        'pageSize': '$pageSize',
        'fields': 'files(id,name)',
        'q': 'trashed=false',
      },
    );
    final res = await _http.get(uri, headers: await _authHeaders());
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('drive list failed (${res.statusCode}): ${res.body}');
    }
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    return ((map['files'] as List?) ?? const []).length;
  }

  Future<List<String>> listRecentGmailSubjects({int max = 5}) async {
    final listUri = Uri.https(
      'gmail.googleapis.com',
      '/gmail/v1/users/me/messages',
      {'maxResults': '$max', 'q': 'newer_than:1d'},
    );
    final listRes = await _http.get(listUri, headers: await _authHeaders());
    if (listRes.statusCode < 200 || listRes.statusCode >= 300) {
      throw StateError('gmail list failed (${listRes.statusCode}): ${listRes.body}');
    }
    final listMap = jsonDecode(listRes.body) as Map<String, dynamic>;
    final messages = (listMap['messages'] as List?) ?? const [];
    final subjects = <String>[];
    for (final raw in messages) {
      if (raw is! Map) continue;
      final id = raw['id']?.toString();
      if (id == null || id.isEmpty) continue;
      final msgUri = Uri.https(
        'gmail.googleapis.com',
        '/gmail/v1/users/me/messages/$id',
        {'format': 'metadata', 'metadataHeaders': 'Subject'},
      );
      final msgRes = await _http.get(msgUri, headers: await _authHeaders());
      if (msgRes.statusCode < 200 || msgRes.statusCode >= 300) continue;
      final msg = jsonDecode(msgRes.body) as Map<String, dynamic>;
      final headers = (msg['payload'] is Map)
          ? ((msg['payload'] as Map)['headers'] as List? ?? const [])
          : const [];
      String subject = 'a message';
      for (final h in headers) {
        if (h is Map && h['name']?.toString().toLowerCase() == 'subject') {
          final v = h['value']?.toString().trim();
          if (v != null && v.isNotEmpty) subject = v;
          break;
        }
      }
      subjects.add(subject);
    }
    return subjects;
  }

  /// Rough local-day bounds as RFC3339 UTC strings.
  (String, String) _localDayBoundsUtcIso() {
    // Fixed offset approximation: America/New_York is UTC-4 in Aug (EDT).
    // Good enough for voice summaries; full TZDB is not shipped in bridge.
    final offsetHours = timeZone == 'America/New_York' ? -4 : 0;
    final nowUtc = DateTime.now().toUtc();
    final local = nowUtc.add(Duration(hours: offsetHours));
    final startLocal = DateTime.utc(local.year, local.month, local.day);
    final endLocal = startLocal.add(const Duration(days: 1));
    final startUtc = startLocal.subtract(Duration(hours: offsetHours));
    final endUtc = endLocal.subtract(Duration(hours: offsetHours));
    return (startUtc.toIso8601String(), endUtc.toIso8601String());
  }

  void close() => _http.close();
}
