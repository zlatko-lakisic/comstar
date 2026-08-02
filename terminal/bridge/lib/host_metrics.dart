import 'dart:io';

/// Host CPU / memory samples for the kiosk health sparkline.
final class HostMetricsSample {
  const HostMetricsSample({
    required this.cpuPercent,
    required this.memPercent,
    required this.tsMs,
  });

  final double cpuPercent;
  final double memPercent;
  final int tsMs;

  Map<String, Object?> toJson() => {
        'cpu': double.parse(cpuPercent.toStringAsFixed(1)),
        'mem': double.parse(memPercent.toStringAsFixed(1)),
        'ts': tsMs,
      };
}

/// Reads `/proc/stat` + `/proc/meminfo` (Linux). Safe no-op elsewhere.
final class HostMetrics {
  int? _prevIdle;
  int? _prevTotal;

  Future<HostMetricsSample> sample() async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final cpu = await _cpuPercent();
    final mem = await _memPercent();
    return HostMetricsSample(
      cpuPercent: cpu.clamp(0, 100),
      memPercent: mem.clamp(0, 100),
      tsMs: ts,
    );
  }

  Future<double> _cpuPercent() async {
    if (!Platform.isLinux) return 0;
    try {
      final text = await File('/proc/stat').readAsString();
      final line = text.split('\n').firstWhere(
            (l) => l.startsWith('cpu '),
            orElse: () => '',
          );
      // cpu  user nice system idle iowait irq softirq steal ...
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.isEmpty || parts.first != 'cpu' || parts.length < 5) {
        return 0;
      }
      final values = parts.skip(1).map(int.parse).toList();
      final idle = values[3] + (values.length > 4 ? values[4] : 0);
      final total = values.fold<int>(0, (a, b) => a + b);
      final prevIdle = _prevIdle;
      final prevTotal = _prevTotal;
      _prevIdle = idle;
      _prevTotal = total;
      if (prevIdle == null || prevTotal == null) return 0;
      final dIdle = idle - prevIdle;
      final dTotal = total - prevTotal;
      if (dTotal <= 0) return 0;
      return (1.0 - dIdle / dTotal) * 100.0;
    } on Object {
      return 0;
    }
  }

  Future<double> _memPercent() async {
    if (!Platform.isLinux) return 0;
    try {
      final text = await File('/proc/meminfo').readAsString();
      int? total;
      int? available;
      for (final line in text.split('\n')) {
        if (line.startsWith('MemTotal:')) {
          total = _kib(line);
        } else if (line.startsWith('MemAvailable:')) {
          available = _kib(line);
        }
        if (total != null && available != null) break;
      }
      if (total == null || total <= 0 || available == null) return 0;
      return ((total - available) / total) * 100.0;
    } on Object {
      return 0;
    }
  }

  int? _kib(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return null;
    return int.tryParse(parts[1]);
  }
}
