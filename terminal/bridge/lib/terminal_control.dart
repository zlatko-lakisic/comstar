import 'dart:convert';
import 'dart:io';

import 'package:comstar_bridge/log.dart';

typedef PactlRunner = ProcessResult Function(List<String> args);

/// Speaker volume + sleep flag owned by the bridge (CONTRACTS §5 / ADR 0004).
class TerminalControl {
  TerminalControl({
    String? volumeStatePath,
    this.preferredSink = 'comstar_hdmi',
    PactlRunner? runPactl,
  })  : volumeStatePath =
            volumeStatePath ?? '${Directory.systemTemp.path}/comstar-volume.json',
        _runPactlFn = runPactl ?? _defaultPactl;

  final String preferredSink;
  final String volumeStatePath;
  final PactlRunner _runPactlFn;

  bool sleeping = false;
  int _lastUnmutedPercent = 80;

  static ProcessResult _defaultPactl(List<String> args) =>
      Process.runSync('pactl', args);

  String? resolveSink() {
    try {
      final sinks = _runPactlFn(['list', 'short', 'sinks']);
      if (sinks.exitCode != 0) return null;
      final lines = sinks.stdout.toString().trim().split('\n');
      for (final line in lines) {
        final parts = line.split('\t');
        if (parts.length >= 2 && parts[1] == preferredSink) {
          return preferredSink;
        }
      }
      final def = _runPactlFn(['get-default-sink']);
      if (def.exitCode == 0) {
        final name = def.stdout.toString().trim();
        if (name.isNotEmpty) return name;
      }
    } catch (e) {
      logWarn('volume_sink_resolve_failed', e.toString());
    }
    return null;
  }

  Map<String, dynamic> volumeGet() {
    final sink = resolveSink();
    if (sink == null) {
      return {'ok': false, 'error': 'no_sink', 'percent': 0, 'muted': true};
    }
    final muted = _sinkMuted(sink);
    final percent = _sinkPercent(sink);
    if (!muted && percent > 0) {
      _lastUnmutedPercent = percent;
      _persist();
    }
    return {'ok': true, 'percent': percent, 'muted': muted, 'sink': sink};
  }

  Map<String, dynamic> volumeSet(int percent) {
    final sink = resolveSink();
    if (sink == null) {
      return {'ok': false, 'error': 'no_sink', 'percent': 0, 'muted': true};
    }
    final p = percent.clamp(0, 100);
    _run(['set-sink-mute', sink, '0']);
    _run(['set-sink-volume', sink, '$p%']);
    if (p > 0) _lastUnmutedPercent = p;
    _persist();
    return {'ok': true, 'percent': p, 'muted': false, 'sink': sink};
  }

  Map<String, dynamic> volumeAdjust(int delta) {
    final cur = volumeGet();
    if (cur['ok'] != true) return cur;
    final next = ((cur['percent'] as int) + delta).clamp(0, 100);
    return volumeSet(next);
  }

  Map<String, dynamic> volumeMute(bool muted) {
    final sink = resolveSink();
    if (sink == null) {
      return {'ok': false, 'error': 'no_sink', 'percent': 0, 'muted': true};
    }
    if (muted) {
      final percent = _sinkPercent(sink);
      if (percent > 0) _lastUnmutedPercent = percent;
      _run(['set-sink-mute', sink, '1']);
      _persist();
      return {
        'ok': true,
        'percent': percent,
        'muted': true,
        'sink': sink,
      };
    }
    _run(['set-sink-mute', sink, '0']);
    _run(['set-sink-volume', sink, '$_lastUnmutedPercent%']);
    _persist();
    return {
      'ok': true,
      'percent': _lastUnmutedPercent,
      'muted': false,
      'sink': sink,
    };
  }

  Map<String, dynamic> sleepEnter() {
    sleeping = true;
    logInfo('sleep_enter', 'COMSTAR entering sleep (dormant)');
    return {'ok': true, 'state': 'sleeping'};
  }

  Map<String, dynamic> sleepExit() {
    sleeping = false;
    logInfo('sleep_exit', 'COMSTAR leaving sleep');
    return {'ok': true, 'state': 'awake'};
  }

  Map<String, dynamic> sleepStatus() => {
        'ok': true,
        'sleeping': sleeping,
      };

  void loadPersistedVolume() {
    try {
      final f = File(volumeStatePath);
      if (!f.existsSync()) return;
      final map = jsonDecode(f.readAsStringSync());
      if (map is Map && map['percent'] is num) {
        _lastUnmutedPercent = (map['percent'] as num).toInt().clamp(1, 100);
      }
    } catch (_) {}
  }

  /// Exposed for tests — last level restored on unmute.
  int get lastUnmutedPercent => _lastUnmutedPercent;

  void _persist() {
    try {
      File(volumeStatePath).writeAsStringSync(
        jsonEncode({'percent': _lastUnmutedPercent}),
      );
    } catch (_) {}
  }

  bool _sinkMuted(String sink) {
    final r = _runPactlFn(['get-sink-mute', sink]);
    return r.stdout.toString().toLowerCase().contains('yes');
  }

  int _sinkPercent(String sink) {
    final r = _runPactlFn(['get-sink-volume', sink]);
    final m = RegExp(r'(\d+)%').firstMatch(r.stdout.toString());
    if (m == null) return 0;
    return int.parse(m.group(1)!).clamp(0, 100);
  }

  void _run(List<String> args) {
    final r = _runPactlFn(args);
    if (r.exitCode != 0) {
      logWarn(
        'pactl_failed',
        r.stderr.toString().trim().isEmpty
            ? 'exit ${r.exitCode}'
            : r.stderr.toString().trim(),
      );
    }
  }
}
