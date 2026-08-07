import 'dart:async';
import 'dart:io';

import 'package:comstar_bridge/log.dart';

/// Best-effort systemd Type=notify + WatchdogSec heartbeats (M9.3).
///
/// Uses `systemd-notify` when `NOTIFY_SOCKET` is set; no-op otherwise
/// (Mac bring-up / Type=simple).
class SystemdWatchdog {
  SystemdWatchdog({
    this.interval = const Duration(seconds: 20),
  });

  final Duration interval;
  Timer? _timer;
  var _ready = false;

  bool get enabled =>
      (Platform.environment['NOTIFY_SOCKET'] ?? '').trim().isNotEmpty;

  Future<void> ready() async {
    if (!enabled) return;
    await _notify(['--ready']);
    _ready = true;
    logInfo('systemd_notify', 'READY=1', data: {'watchdog_interval_s': interval.inSeconds});
  }

  void startWatchdog() {
    if (!enabled || _timer != null) return;
    _timer = Timer.periodic(interval, (_) {
      unawaited(_notify(['WATCHDOG=1']));
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (_ready && enabled) {
      await _notify(['STOPPING=1']);
    }
  }

  Future<void> _notify(List<String> args) async {
    try {
      final r = await Process.run('systemd-notify', args).timeout(
        const Duration(seconds: 2),
      );
      if (r.exitCode != 0) {
        logWarn('systemd_notify', 'notify failed', data: {
          'args': args,
          'code': r.exitCode,
          'err': '${r.stderr}'.trim(),
        });
      }
    } catch (e) {
      logWarn('systemd_notify', e.toString(), data: {'args': args});
    }
  }
}
