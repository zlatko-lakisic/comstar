/// Persistent `(provider, sender_id) → userid` bindings from QR pairing.
///
/// Merged with the static [Allowlist] at resolve time. File mode `0600`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One linked messaging identity.
class ChannelBinding {
  const ChannelBinding({
    required this.provider,
    required this.senderId,
    required this.userid,
    required this.linkedAt,
  });

  final String provider;
  final String senderId;
  final String userid;
  final DateTime linkedAt;

  String get key => '$provider:$senderId';

  Map<String, Object?> toJson() => {
        'provider': provider,
        'sender_id': senderId,
        'userid': userid,
        'linked_at': linkedAt.toUtc().toIso8601String(),
      };

  factory ChannelBinding.fromJson(Map<String, dynamic> json) {
    return ChannelBinding(
      provider: '${json['provider'] ?? ''}'.trim(),
      senderId: '${json['sender_id'] ?? json['senderId'] ?? ''}'.trim(),
      userid: '${json['userid'] ?? ''}'.trim(),
      linkedAt: DateTime.tryParse('${json['linked_at'] ?? ''}')?.toUtc() ??
          DateTime.now().toUtc(),
    );
  }
}

/// Disk-backed binding store (Ada).
class BindingStore {
  BindingStore({Directory? root}) : _rootOverride = root;

  final Directory? _rootOverride;
  final _byKey = <String, ChannelBinding>{};
  var _loaded = false;

  Directory get root {
    if (_rootOverride != null) return _rootOverride!;
    final override = Platform.environment['COMSTAR_DATA_DIR']?.trim();
    final base = (override != null && override.isNotEmpty)
        ? override
        : p.join(
            Platform.environment['HOME'] ?? Directory.systemTemp.path,
            '.local',
            'share',
            'comstar',
          );
    return Directory(p.join(base, 'channel'));
  }

  File get _file => File(p.join(root.path, 'bindings.json'));

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (!await _file.exists()) return;
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map) return;
      final list = decoded['bindings'];
      if (list is! List) return;
      for (final raw in list) {
        if (raw is! Map) continue;
        final b = ChannelBinding.fromJson(Map<String, dynamic>.from(raw));
        if (b.provider.isEmpty || b.senderId.isEmpty || b.userid.isEmpty) {
          continue;
        }
        if (b.userid == 'guest' || b.userid == 'unknown') continue;
        _byKey[b.key] = b;
      }
    } catch (_) {}
  }

  Future<void> _persist() async {
    if (!await root.exists()) {
      await root.create(recursive: true);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['0700', root.path]);
      }
    }
    final body = jsonEncode({
      'bindings': [for (final b in _byKey.values) b.toJson()],
    });
    await _file.writeAsString(body);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['0600', _file.path]);
    }
  }

  String? useridFor(String provider, String senderId) {
    return _byKey['$provider:$senderId']?.userid;
  }

  List<ChannelBinding> bindingsFor(String userid) {
    return [
      for (final b in _byKey.values)
        if (b.userid == userid) b,
    ];
  }

  List<String> senderIdsFor(String userid, {String? provider}) {
    return [
      for (final b in bindingsFor(userid))
        if (provider == null || b.provider == provider) b.senderId,
    ];
  }

  Future<void> upsert(ChannelBinding binding) async {
    await load();
    // One binding per (provider, userid): replace prior sender for that pair.
    _byKey.removeWhere(
      (_, b) => b.provider == binding.provider && b.userid == binding.userid,
    );
    _byKey[binding.key] = binding;
    await _persist();
  }

  Future<bool> remove({
    required String userid,
    String? provider,
  }) async {
    await load();
    final before = _byKey.length;
    _byKey.removeWhere((_, b) {
      if (b.userid != userid) return false;
      if (provider != null && b.provider != provider) return false;
      return true;
    });
    if (_byKey.length == before) return false;
    await _persist();
    return true;
  }

  int get length => _byKey.length;
}
