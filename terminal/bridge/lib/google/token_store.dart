import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

enum GoogleOAuthClientKind { tv, desktop }

/// Per-userid Google OAuth refresh tokens (`0600` files).
///
/// Default root: `$COMSTAR_DATA_DIR/google` or `~/.local/share/comstar/google`.
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

  /// Safe filename stem for [userid] (face id).
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

  File _fileFor(String userid) =>
      File(p.join(root.path, '${safeUserid(userid)}.json'));

  Future<Map<String, dynamic>?> readRecord(String userid) async {
    final file = _fileFor(userid);
    if (!await file.exists()) return null;
    try {
      final map = jsonDecode(await file.readAsString());
      if (map is Map<String, dynamic>) return map;
      if (map is Map) return Map<String, dynamic>.from(map);
    } catch (_) {}
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
    final file = _fileFor(userid);
    final payload = jsonEncode({
      'refresh_token': token,
      'client': client.name,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    await file.writeAsString(payload, flush: true);
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.run('chmod', ['600', file.path]);
    }
  }

  Future<void> clear(String userid) async {
    final file = _fileFor(userid);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
