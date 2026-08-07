/// Shared sudo-aware nmcli runner for host network admin.
library;

import 'dart:io';

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

class NmcliResult {
  const NmcliResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  bool get ok => exitCode == 0;
}

class NmcliRunner {
  NmcliRunner({ProcessRunner? runner}) : runner = runner ?? Process.run;

  final ProcessRunner runner;
  List<String>? _prefix;

  Future<List<String>> _nmcliPrefix() async {
    if (_prefix != null) return _prefix!;
    final preferSudo = Platform.environment['COMSTAR_ROAD_NMCLI_SUDO'] != '0';
    if (!preferSudo) {
      _prefix = ['nmcli'];
      return _prefix!;
    }
    final probe = await runner(
      'sudo',
      ['-n', 'nmcli', '-t', '-f', 'NAME', 'connection', 'show'],
    );
    _prefix = probe.exitCode == 0 ? ['sudo', '-n', 'nmcli'] : ['nmcli'];
    return _prefix!;
  }

  Future<NmcliResult> run(List<String> args) async {
    final prefix = await _nmcliPrefix();
    final exe = prefix.first;
    final full = [...prefix.skip(1), ...args];
    final r = await runner(exe, full);
    return NmcliResult(
      exitCode: r.exitCode,
      stdout: (r.stdout as String? ?? '').toString(),
      stderr: (r.stderr as String? ?? '').toString(),
    );
  }

  Future<bool> available() async {
    final r = await run(['-t', '-f', 'NAME', 'connection', 'show']);
    return r.ok;
  }
}
