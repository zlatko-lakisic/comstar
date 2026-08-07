/// Host package / sudo readiness for Road VPN.
library;

import 'dart:io';

import 'package:comstar_bridge/road/nmcli_backend.dart';

class RoadPrereqReport {
  const RoadPrereqReport({
    required this.ok,
    required this.checks,
    this.hint,
  });

  final bool ok;
  final Map<String, Object?> checks;
  final String? hint;

  Map<String, Object?> toJson() => {
        'ok': ok,
        'checks': checks,
        if (hint != null) 'hint': hint,
      };
}

/// Probe packages, nmcli, and passwordless sudo used by the road reconciler.
Future<RoadPrereqReport> checkRoadPrereqs({
  ProcessRunner? runner,
}) async {
  final run = runner ?? Process.run;
  final checks = <String, Object?>{};

  Future<bool> cmdExists(String name) async {
    final r = await run('sh', ['-c', 'command -v $name >/dev/null']);
    return r.exitCode == 0;
  }

  Future<bool> pkgInstalled(String name) async {
    final r = await run('dpkg-query', ['-W', '-f=\${Status}', name]);
    final out = (r.stdout as String).trim();
    return r.exitCode == 0 && out.contains('install ok installed');
  }

  checks['nmcli'] = await cmdExists('nmcli');
  checks['network_manager'] = await pkgInstalled('network-manager');
  checks['openvpn_plugin'] = await pkgInstalled('network-manager-openvpn');
  checks['l2tp_plugin'] = await pkgInstalled('network-manager-l2tp');
  checks['strongswan'] = await pkgInstalled('strongswan');

  var sudoNmcli = false;
  final sudoProbe = await run('sudo', ['-n', 'nmcli', '-t', '-f', 'NAME', 'connection', 'show']);
  if (sudoProbe.exitCode == 0) {
    sudoNmcli = true;
  } else {
    // Plain nmcli may still work for user connections.
    final plain = await run('nmcli', ['-t', '-f', 'NAME', 'connection', 'show']);
    checks['nmcli_user'] = plain.exitCode == 0;
  }
  checks['sudo_nmcli'] = sudoNmcli;

  final missing = <String>[];
  for (final key in [
    'nmcli',
    'network_manager',
    'openvpn_plugin',
    'l2tp_plugin',
  ]) {
    if (checks[key] != true) missing.add(key);
  }
  if (sudoNmcli != true && checks['nmcli_user'] != true) {
    missing.add('nmcli_access');
  }

  final ok = missing.isEmpty;
  String? hint;
  if (!ok) {
    hint =
        'On the Pi run: sudo bash /opt/comstar/src/scripts/install-road-vpn.sh '
        '(or: make road-vpn). Missing: ${missing.join(', ')}';
  }

  return RoadPrereqReport(ok: ok, checks: checks, hint: hint);
}
