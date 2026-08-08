import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Per-userid Nextcloud app-password credentials (`0600` files).
///
/// Default root: `$COMSTAR_DATA_DIR/nextcloud` or `~/.local/share/comstar/nextcloud`.
///
/// Keys may be the biometric faceId (`zlatko`) or FreeIPA uid (`zlatko.lakisic`).
/// Reads accept both forms so directory resolve does not orphan an earlier
/// faceId pairing.
class NextcloudTokenStore {
  NextcloudTokenStore({Directory? root}) : _root = root;

  final Directory? _root;

  Directory get root {
    if (_root != null) return _root;
    final override = Platform.environment['COMSTAR_DATA_DIR']?.trim();
    final base = (override != null && override.isNotEmpty)
        ? override
        : p.join(
            Platform.environment['HOME'] ?? Directory.systemTemp.path,
            '.local',
            'share',
            'comstar',
          );
    return Directory(p.join(base, 'nextcloud'));
  }

  static String safeUserid(String userid) {
    final cleaned = userid.trim().toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9_-]'),
          '_',
        );
    if (cleaned.isEmpty || cleaned == 'guest' || cleaned == 'unknown') {
      throw ArgumentError('invalid nextcloud token userid: $userid');
    }
    return cleaned;
  }

  static List<String> candidateStems(String userid) {
    final primary = safeUserid(userid);
    final out = <String>[primary];
    final raw = userid.trim().toLowerCase();
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

  Future<bool> hasCredentials(String userid) async {
    final c = await readCredentials(userid);
    return c != null;
  }

  /// Resolved host / username / app password for MCP env, or null if incomplete.
  Future<({String host, String username, String appPassword})?> readCredentials(
    String userid,
  ) async {
    final map = await readRecord(userid);
    final username = map?['username']?.toString().trim() ?? '';
    final appPassword = map?['app_password']?.toString().trim() ?? '';
    var host = map?['host']?.toString().trim() ?? '';
    if (host.isEmpty) {
      host = Platform.environment['NEXTCLOUD_HOST']?.trim() ?? '';
    }
    if (host.isEmpty || username.isEmpty || appPassword.isEmpty) return null;
    return (host: _normalizeHost(host), username: username, appPassword: appPassword);
  }

  Future<void> writeCredentials(
    String userid, {
    required String username,
    required String appPassword,
    String? host,
  }) async {
    final user = username.trim();
    final pass = appPassword.trim();
    if (user.isEmpty || pass.isEmpty) {
      throw ArgumentError('username and app_password must be non-empty');
    }
    var h = (host ?? '').trim();
    if (h.isEmpty) {
      h = Platform.environment['NEXTCLOUD_HOST']?.trim() ?? '';
    }
    if (h.isEmpty) {
      throw ArgumentError('host or NEXTCLOUD_HOST required');
    }
    h = _normalizeHost(h);

    final dir = root;
    await dir.create(recursive: true);
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.run('chmod', ['700', dir.path]);
    }
    final payload = jsonEncode({
      'host': h,
      'username': user,
      'app_password': pass,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
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

  /// Public status for Admin (never includes app_password).
  Future<Map<String, Object?>> status(String userid) async {
    final map = await readRecord(userid);
    final creds = await readCredentials(userid);
    return {
      'userid': userid,
      'linked': creds != null,
      'host': creds?.host ?? map?['host']?.toString(),
      'username': creds?.username ?? map?['username']?.toString(),
      'updated_at': map?['updated_at']?.toString(),
    };
  }

  static String _normalizeHost(String host) {
    var h = host.trim();
    if (h.endsWith('/')) h = h.substring(0, h.length - 1);
    return h;
  }
}
