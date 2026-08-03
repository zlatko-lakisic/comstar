import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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

  Future<String?> readRefreshToken(String userid) async {
    final file = _fileFor(userid);
    if (!await file.exists()) return null;
    try {
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final token = map['refresh_token']?.toString().trim() ?? '';
      return token.isEmpty ? null : token;
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasTokens(String userid) async {
    final t = await readRefreshToken(userid);
    return t != null && t.isNotEmpty;
  }

  Future<void> writeRefreshToken(String userid, String refreshToken) async {
    final token = refreshToken.trim();
    if (token.isEmpty) {
      throw ArgumentError('refresh token must be non-empty');
    }
    final dir = root;
    await dir.create(recursive: true);
    // Directory 0700 when we own it.
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.run('chmod', ['700', dir.path]);
    }
    final file = _fileFor(userid);
    final payload = jsonEncode({
      'refresh_token': token,
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
