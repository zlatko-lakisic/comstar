import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum GoogleOAuthClientKind { tv, desktop }

/// Per-userid Google OAuth refresh tokens (`0600` files).
///
/// Default root: `$COMSTAR_DATA_DIR/google` or `~/.local/share/comstar/google`.
///
/// Keys may be the biometric faceId (`zlatko`) or FreeIPA uid (`zlatko.lakisic`).
/// Reads accept both forms so directory resolve does not orphan an earlier
/// faceId pairing.
class GoogleTokenStore {
  GoogleTokenStore({Directory? root}) : _root = root;

  final Directory? _root;

  Directory get root {
    if (_root != null) return _root!;
    final override = Platform.environment['COMSTAR_DATA_DIR']?.trim();
    final base = (override != null && override.isNotEmpty)
        ? override
        : p.join(
            Platform.environment['HOME'] ?? Directory.systemTemp.path,
            '.local',
            'share',
            'comstar',
          );
    return Directory(p.join(base, 'google'));
  }

  /// Safe filename stem for [userid] (face id or LDAP uid).
  static String safeUserid(String userid) {
    final cleaned = userid.trim().toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9_-]'),
          '_',
        );
    if (cleaned.isEmpty || cleaned == 'guest' || cleaned == 'unknown') {
      throw ArgumentError('invalid google token userid: $userid');
    }
    return cleaned;
  }

  /// Filename stems to try for [userid], longest/exact first.
  ///
  /// `zlatko.lakisic` → `zlatko_lakisic`, then `zlatko` (legacy faceId file).
  static List<String> candidateStems(String userid) {
    final primary = safeUserid(userid);
    final out = <String>[primary];
    final raw = userid.trim().toLowerCase();
    // LDAP uid / email-local: keep first segment as faceId alias.
    for (final sep in ['.', '_', '-']) {
      final i = raw.indexOf(sep);
      if (i > 0) {
        final short = safeUserid(raw.substring(0, i));
        if (short != primary && !out.contains(short)) {
          out.add(short);
        }
        break;
      }
    }
    return out;
  }

  File _fileForStem(String stem) => File(p.join(root.path, '$stem.json'));

  File _fileFor(String userid) => _fileForStem(safeUserid(userid));

  Future<Map<String, dynamic>?> readRecord(String userid) async {
    for (final stem in candidateStems(userid)) {
      final file = _fileForStem(stem);
      if (!await file.exists()) continue;
      try {
        final map = jsonDecode(await file.readAsString());
        if (map is Map<String, dynamic>) return map;
        if (map is Map) return Map<String, dynamic>.from(map);
      } catch (_) {}
    }
    return null;
  }

  Future<String?> readRefreshToken(String userid) async {
    final map = await readRecord(userid);
    final token = map?['refresh_token']?.toString().trim() ?? '';
    return token.isEmpty ? null : token;
  }

  Future<GoogleOAuthClientKind> readClientKind(String userid) async {
    final map = await readRecord(userid);
    final raw = map?['client']?.toString().trim().toLowerCase() ?? 'tv';
    return raw == 'desktop'
        ? GoogleOAuthClientKind.desktop
        : GoogleOAuthClientKind.tv;
  }

  Future<bool> hasTokens(String userid) async {
    final t = await readRefreshToken(userid);
    return t != null && t.isNotEmpty;
  }

  Future<void> writeRefreshToken(
    String userid,
    String refreshToken, {
    GoogleOAuthClientKind client = GoogleOAuthClientKind.tv,
  }) async {
    final token = refreshToken.trim();
    if (token.isEmpty) {
      throw ArgumentError('refresh token must be non-empty');
    }
    final dir = root;
    await dir.create(recursive: true);
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.run('chmod', ['700', dir.path]);
    }
    final payload = jsonEncode({
      'refresh_token': token,
      'client': client.name,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    // Write primary + faceId alias so LDAP uid sessions still find faceId files.
    for (final stem in candidateStems(userid)) {
      final file = _fileForStem(stem);
      await file.writeAsString(payload, flush: true);
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', ['600', file.path]);
      }
    }
  }

  Future<void> clear(String userid) async {
    for (final stem in candidateStems(userid)) {
      final file = _fileForStem(stem);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }
}
