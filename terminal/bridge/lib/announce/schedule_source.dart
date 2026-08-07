import 'dart:io';

import 'package:comstar_bridge/announce/queue.dart';
import 'package:comstar_bridge/announce/types.dart';
import 'package:comstar_bridge/log.dart';
import 'package:yaml/yaml.dart';

/// Cron-lite schedule source (M10.2.1). Only enqueues — never speaks.
///
/// schedule.yaml:
/// ```yaml
/// entries:
///   - id: morning_brief
///     recipient: zlatko.lakisic
///     # Daily local time HH:MM
///     at: "08:30"
///     # Or 5-field cron: minute hour day month weekday (* or number)
///     # cron: "30 8 * * *"
///     intent: "Brief morning reminder in one short sentence."
///     ttl_minutes: 120
///     priority: normal
///     dedupe_key: "schedule:morning_brief:{date}"
/// ```
class ScheduleAnnounceSource {
  ScheduleAnnounceSource({
    required this.queue,
    required this.schedulePath,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AnnouncementQueue queue;
  final String schedulePath;
  final DateTime Function() _clock;

  List<_ScheduleEntry> _entries = const [];
  final Set<String> _firedKeys = {};

  void load() {
    final f = File(schedulePath);
    if (!f.existsSync()) {
      _entries = const [];
      logInfo('announce_schedule_missing', 'No schedule file', data: {
        'path': schedulePath,
      });
      return;
    }
    final doc = loadYaml(f.readAsStringSync());
    if (doc is! YamlMap) {
      _entries = const [];
      return;
    }
    final raw = doc['entries'];
    if (raw is! YamlList) {
      _entries = const [];
      return;
    }
    final out = <_ScheduleEntry>[];
    for (final item in raw) {
      if (item is! YamlMap) continue;
      final e = _ScheduleEntry.tryParse(item);
      if (e != null) out.add(e);
    }
    _entries = out;
    logInfo('announce_schedule_loaded', 'Schedule entries loaded', data: {
      'path': schedulePath,
      'count': _entries.length,
    });
  }

  /// Call periodically (e.g. each minute / Tick throttle). Returns enqueue count.
  int tick({DateTime? now}) {
    if (_entries.isEmpty) return 0;
    final t = (now ?? _clock()).toLocal();
    var n = 0;
    for (final e in _entries) {
      if (!e.matches(t)) continue;
      final dateKey = '${t.year.toString().padLeft(4, '0')}-'
          '${t.month.toString().padLeft(2, '0')}-'
          '${t.day.toString().padLeft(2, '0')}';
      final fireKey = '${e.id}@$dateKey@${t.hour}:${t.minute}';
      if (_firedKeys.contains(fireKey)) continue;
      final dedupe = (e.dedupeKey ?? 'schedule:${e.id}:{date}')
          .replaceAll('{date}', dateKey);
      queue.enqueue(
        Announcement(
          id: '',
          recipient: e.recipient,
          source: AnnouncementSource.schedule,
          intent: e.intent,
          priority: e.priority,
          notBefore: t.toUtc(),
          expiresAt: t.toUtc().add(Duration(minutes: e.ttlMinutes)),
          dedupeKey: dedupe,
        ),
      );
      _firedKeys.add(fireKey);
      // Bound memory: keep last ~2 days of keys.
      if (_firedKeys.length > 500) {
        _firedKeys.remove(_firedKeys.first);
      }
      n++;
    }
    return n;
  }
}

class _ScheduleEntry {
  _ScheduleEntry({
    required this.id,
    required this.recipient,
    required this.intent,
    required this.ttlMinutes,
    required this.priority,
    required this.dedupeKey,
    this.atHour,
    this.atMinute,
    this.cronMinute,
    this.cronHour,
    this.cronDom,
    this.cronMonth,
    this.cronDow,
  });

  final String id;
  final String recipient;
  final String intent;
  final int ttlMinutes;
  final AnnouncementPriority priority;
  final String? dedupeKey;
  final int? atHour;
  final int? atMinute;
  final String? cronMinute;
  final String? cronHour;
  final String? cronDom;
  final String? cronMonth;
  final String? cronDow;

  static _ScheduleEntry? tryParse(YamlMap m) {
    final id = m['id']?.toString().trim() ?? '';
    final recipient = m['recipient']?.toString().trim() ?? '';
    final intent = m['intent']?.toString().trim() ?? '';
    if (id.isEmpty || recipient.isEmpty || intent.isEmpty) return null;
    final ttl = (m['ttl_minutes'] as num?)?.toInt() ?? 120;
    final priority = AnnouncementPriority.parse(m['priority']?.toString());
    final dedupe = m['dedupe_key']?.toString();
    final at = m['at']?.toString();
    final cron = m['cron']?.toString();
    int? atH;
    int? atM;
    String? cMin, cHour, cDom, cMon, cDow;
    if (at != null && at.isNotEmpty) {
      final hm = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(at.trim());
      if (hm == null) return null;
      atH = int.parse(hm.group(1)!);
      atM = int.parse(hm.group(2)!);
    } else if (cron != null && cron.isNotEmpty) {
      final parts = cron.trim().split(RegExp(r'\s+'));
      if (parts.length != 5) return null;
      cMin = parts[0];
      cHour = parts[1];
      cDom = parts[2];
      cMon = parts[3];
      cDow = parts[4];
    } else {
      return null;
    }
    return _ScheduleEntry(
      id: id,
      recipient: recipient,
      intent: intent,
      ttlMinutes: ttl.clamp(1, 24 * 60),
      priority: priority,
      dedupeKey: dedupe,
      atHour: atH,
      atMinute: atM,
      cronMinute: cMin,
      cronHour: cHour,
      cronDom: cDom,
      cronMonth: cMon,
      cronDow: cDow,
    );
  }

  bool matches(DateTime t) {
    if (atHour != null && atMinute != null) {
      return t.hour == atHour && t.minute == atMinute;
    }
    return _cronField(cronMinute, t.minute) &&
        _cronField(cronHour, t.hour) &&
        _cronField(cronDom, t.day) &&
        _cronField(cronMonth, t.month) &&
        _cronField(cronDow, t.weekday % 7); // cron 0=Sun; Dart 7=Sun → 0
  }

  static bool _cronField(String? field, int value) {
    if (field == null || field == '*') return true;
    final n = int.tryParse(field);
    if (n != null) return n == value;
    return false;
  }
}
