/// NetworkManager (nmcli) VPN up/down + optional profile apply.
library;

import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/log.dart';
import 'package:path/path.dart' as p;

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class VpnActionResult {
  const VpnActionResult({
    required this.ok,
    this.message = '',
    this.stdout = '',
    this.stderr = '',
  });

  final bool ok;
  final String message;
  final String stdout;
  final String stderr;
}

class ActiveVpnInfo {
  const ActiveVpnInfo({
    required this.name,
    required this.type,
    this.device,
  });

  final String name;
  final String type;
  final String? device;
}

/// Thin nmcli wrapper. Uses `sudo -n nmcli` when available (system connections).
class NmcliVpnBackend {
  NmcliVpnBackend({
    ProcessRunner? runner,
    this.stateDir,
  }) : runner = runner ?? Process.run;

  final ProcessRunner runner;
  String? stateDir;

  Future<List<String>> _nmcliPrefix() async {
    final preferSudo = Platform.environment['COMSTAR_ROAD_NMCLI_SUDO'] != '0';
    if (!preferSudo) return ['nmcli'];
    final probe = await runner('sudo', ['-n', 'nmcli', '-t', '-f', 'NAME', 'connection', 'show']);
    if (probe.exitCode == 0) return ['sudo', '-n', 'nmcli'];
    return ['nmcli'];
  }

  Future<ProcessResult> _run(List<String> args) async {
    final prefix = await _nmcliPrefix();
    final exe = prefix.first;
    final full = [...prefix.skip(1), ...args];
    return runner(exe, full);
  }

  Future<List<ActiveVpnInfo>> listActiveVpn() async {
    final r = await _run([
      '-t',
      '-f',
      'NAME,TYPE,DEVICE',
      'connection',
      'show',
      '--active',
    ]);
    if (r.exitCode != 0) return const [];
    final out = <ActiveVpnInfo>[];
    for (final line in (r.stdout as String).split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final parts = t.split(':');
      if (parts.length < 2) continue;
      final name = parts[0];
      final type = parts[1];
      if (!type.contains('vpn') && type != 'tun' && type != 'wireguard') {
        // Still include if NAME matches later filter via isActive.
        if (!type.toLowerCase().contains('vpn')) continue;
      }
      out.add(ActiveVpnInfo(
        name: name,
        type: type,
        device: parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null,
      ));
    }
    return out;
  }

  Future<bool> connectionExists(String name) async {
    if (name.trim().isEmpty) return false;
    final r = await _run(['-t', '-f', 'NAME', 'connection', 'show']);
    if (r.exitCode != 0) return false;
    for (final line in (r.stdout as String).split('\n')) {
      if (line.trim() == name) return true;
    }
    return false;
  }

  Future<bool> isActive(String name) async {
    if (name.trim().isEmpty) return false;
    final r = await _run([
      '-t',
      '-f',
      'NAME',
      'connection',
      'show',
      '--active',
    ]);
    if (r.exitCode != 0) return false;
    for (final line in (r.stdout as String).split('\n')) {
      if (line.trim() == name) return true;
    }
    return false;
  }

  Future<VpnActionResult> up(String name) async {
    if (name.trim().isEmpty) {
      return const VpnActionResult(ok: false, message: 'empty_connection');
    }
    final r = await _run(['connection', 'up', 'id', name]);
    final ok = r.exitCode == 0;
    if (!ok) {
      logWarn('road_vpn_up_failed', 'nmcli connection up failed', data: {
        'connection': name,
        'code': r.exitCode,
        'stderr': (r.stderr as String).trim(),
      });
    } else {
      logInfo('road_vpn_up', 'VPN connection up', data: {'connection': name});
    }
    return VpnActionResult(
      ok: ok,
      message: ok ? 'up' : 'up_failed',
      stdout: (r.stdout as String).trim(),
      stderr: (r.stderr as String).trim(),
    );
  }

  Future<VpnActionResult> down(String name) async {
    if (name.trim().isEmpty) {
      return const VpnActionResult(ok: false, message: 'empty_connection');
    }
    final active = await isActive(name);
    if (!active) {
      return const VpnActionResult(ok: true, message: 'already_down');
    }
    final r = await _run(['connection', 'down', 'id', name]);
    final ok = r.exitCode == 0;
    if (!ok) {
      logWarn('road_vpn_down_failed', 'nmcli connection down failed', data: {
        'connection': name,
        'code': r.exitCode,
        'stderr': (r.stderr as String).trim(),
      });
    } else {
      logInfo('road_vpn_down', 'VPN connection down', data: {'connection': name});
    }
    return VpnActionResult(
      ok: ok,
      message: ok ? 'down' : 'down_failed',
      stdout: (r.stdout as String).trim(),
      stderr: (r.stderr as String).trim(),
    );
  }

  /// Import or replace an OpenVPN profile from inline `.ovpn` text.
  Future<VpnActionResult> applyOpenVpn({
    required String connectionName,
    required String ovpnText,
    String? passphrase,
  }) async {
    final dir = stateDir;
    if (dir == null || dir.isEmpty) {
      return const VpnActionResult(ok: false, message: 'no_state_dir');
    }
    await Directory(dir).create(recursive: true);
    final ovpnPath = p.join(dir, 'client.ovpn');
    await File(ovpnPath).writeAsString(ovpnText, flush: true);
    // Remove existing connection with same name (ignore failure).
    await _run(['connection', 'delete', 'id', connectionName]);
    final import = await _run([
      'connection',
      'import',
      'type',
      'openvpn',
      'file',
      ovpnPath,
    ]);
    if (import.exitCode != 0) {
      return VpnActionResult(
        ok: false,
        message: 'import_failed',
        stderr: (import.stderr as String).trim(),
        stdout: (import.stdout as String).trim(),
      );
    }
    // Rename imported connection (often basename of file) to desired name.
    final importedName = _guessImportedName(ovpnPath, import.stdout as String);
    if (importedName != null && importedName != connectionName) {
      await _run([
        'connection',
        'modify',
        'id',
        importedName,
        'connection.id',
        connectionName,
      ]);
    }
    if (passphrase != null && passphrase.isNotEmpty) {
      await _run([
        'connection',
        'modify',
        'id',
        connectionName,
        'vpn.secrets',
        'password=$passphrase',
      ]);
    }
    // Autoconnect off — COMSTAR reconciler owns bring-up.
    await _run([
      'connection',
      'modify',
      'id',
      connectionName,
      'connection.autoconnect',
      'no',
    ]);
    logInfo('road_ovpn_applied', 'OpenVPN profile applied', data: {
      'connection': connectionName,
    });
    return const VpnActionResult(ok: true, message: 'openvpn_applied');
  }

  String? _guessImportedName(String ovpnPath, String stdout) {
    // nmcli often prints: Connection 'client' (uuid) successfully added.
    final m = RegExp(r"Connection '([^']+)'").firstMatch(stdout);
    if (m != null) return m.group(1);
    return p.basenameWithoutExtension(ovpnPath);
  }

  /// Create or update an L2TP/IPsec VPN connection.
  Future<VpnActionResult> applyL2tp({
    required String connectionName,
    required String gateway,
    required String user,
    required String password,
    required String psk,
    bool ipsecEnabled = true,
  }) async {
    if (gateway.trim().isEmpty || user.trim().isEmpty) {
      return const VpnActionResult(ok: false, message: 'gateway_user_required');
    }
    final exists = await connectionExists(connectionName);
    if (exists) {
      await _run(['connection', 'delete', 'id', connectionName]);
    }
    final vpnData = [
      'gateway=$gateway',
      'user=$user',
      'ipsec-enabled=${ipsecEnabled ? 'yes' : 'no'}',
    ].join(',');
    final add = await _run([
      'connection',
      'add',
      'con-name',
      connectionName,
      'type',
      'vpn',
      'vpn-type',
      'l2tp',
      'ifname',
      '*',
      'vpn.data',
      vpnData,
    ]);
    if (add.exitCode != 0) {
      return VpnActionResult(
        ok: false,
        message: 'l2tp_add_failed',
        stderr: (add.stderr as String).trim(),
        stdout: (add.stdout as String).trim(),
      );
    }
    final secrets = <String>['password=$password'];
    if (ipsecEnabled && psk.isNotEmpty) {
      secrets.add('ipsec-psk=$psk');
    }
    await _run([
      'connection',
      'modify',
      'id',
      connectionName,
      'vpn.secrets',
      secrets.join(','),
    ]);
    await _run([
      'connection',
      'modify',
      'id',
      connectionName,
      'connection.autoconnect',
      'no',
    ]);
    logInfo('road_l2tp_applied', 'L2TP profile applied', data: {
      'connection': connectionName,
      'gateway': gateway,
    });
    return const VpnActionResult(ok: true, message: 'l2tp_applied');
  }

  /// Persist secrets JSON (never logged). Mode 0600.
  Future<void> writeSecretsFile(String path, Map<String, dynamic> secrets) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(secrets), flush: true);
    try {
      await Process.run('chmod', ['600', path]);
    } on Object {
      // best-effort on non-unix
    }
  }
}
