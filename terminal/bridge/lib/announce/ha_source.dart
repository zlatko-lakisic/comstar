import 'dart:io';

import 'package:comstar_bridge/announce/queue.dart';
import 'package:comstar_bridge/announce/types.dart';
import 'package:comstar_bridge/ha_agent_client.dart';
import 'package:comstar_bridge/log.dart';
import 'package:yaml/yaml.dart';

/// Declarative HA → announce rules (M10.2.2). Polls HA agent; never speaks.
///
/// ha_rules.yaml:
/// ```yaml
/// rules:
///   - id: trash_day
///     entity_id: binary_sensor.trash_day
///     from: "off"
///     to: "on"
///     recipient: zlatko.lakisic
///     intent: "Remind them it is trash day in one short sentence."
///     ttl_minutes: 180
///     priority: normal
///     dedupe_key: "ha:trash_day:{date}"
/// ```
class HaAnnounceSource {
  HaAnnounceSource({
    required this.queue,
    required this.rulesPath,
    HaAgentClient? ha,
    DateTime Function()? clock,
  })  : _ha = ha,
        _clock = clock ?? DateTime.now;

  final AnnouncementQueue queue;
  final String rulesPath;
  final HaAgentClient? _ha;
  final DateTime Function() _clock;

  List<_HaRule> _rules = const [];
  final Map<String, String> _lastState = {};

  void load() {
    final f = File(rulesPath);
    if (!f.existsSync()) {
      _rules = const [];
      logInfo('announce_ha_rules_missing', 'No HA rules file', data: {
        'path': rulesPath,
      });
      return;
    }
    final doc = loadYaml(f.readAsStringSync());
    if (doc is! YamlMap) {
      _rules = const [];
      return;
    }
    final raw = doc['rules'];
    if (raw is! YamlList) {
      _rules = const [];
      return;
    }
    final out = <_HaRule>[];
    for (final item in raw) {
      if (item is! YamlMap) continue;
      final r = _HaRule.tryParse(item);
      if (r != null) out.add(r);
    }
    _rules = out;
    logInfo('announce_ha_rules_loaded', 'HA announce rules loaded', data: {
      'path': rulesPath,
      'count': _rules.length,
    });
  }

  /// Poll HA for each rule entity. Returns enqueue count.
  Future<int> tick() async {
    final ha = _ha;
    if (ha == null || !HaAgentClient.isConfigured || _rules.isEmpty) return 0;
    var n = 0;
    final now = _clock().toLocal();
    final dateKey = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    for (final rule in _rules) {
      try {
        final st = await ha.entityState(rule.entityId);
        final state = '${st?['state'] ?? ''}'.trim().toLowerCase();
        if (state.isEmpty) continue;
        final prev = _lastState[rule.id];
        _lastState[rule.id] = state;
        if (prev == null) continue; // prime only
        final fromOk = rule.from == null || prev == rule.from!.toLowerCase();
        final toOk = state == rule.to.toLowerCase();
        if (!fromOk || !toOk) continue;
        final dedupe = (rule.dedupeKey ?? 'ha:${rule.id}:{date}')
            .replaceAll('{date}', dateKey);
        queue.enqueue(
          Announcement(
            id: '',
            recipient: rule.recipient,
            source: AnnouncementSource.event,
            intent: rule.intent,
            priority: rule.priority,
            notBefore: now.toUtc(),
            expiresAt: now.toUtc().add(Duration(minutes: rule.ttlMinutes)),
            dedupeKey: dedupe,
          ),
        );
        n++;
      } catch (e) {
        logWarn('announce_ha_rule_fail', e.toString(), data: {
          'rule': rule.id,
          'entity': rule.entityId,
        });
      }
    }
    return n;
  }
}

class _HaRule {
  _HaRule({
    required this.id,
    required this.entityId,
    required this.to,
    required this.recipient,
    required this.intent,
    required this.ttlMinutes,
    required this.priority,
    this.from,
    this.dedupeKey,
  });

  final String id;
  final String entityId;
  final String? from;
  final String to;
  final String recipient;
  final String intent;
  final int ttlMinutes;
  final AnnouncementPriority priority;
  final String? dedupeKey;

  static _HaRule? tryParse(YamlMap m) {
    final id = m['id']?.toString().trim() ?? '';
    final entity = m['entity_id']?.toString().trim() ?? '';
    final to = m['to']?.toString().trim() ?? '';
    final recipient = m['recipient']?.toString().trim() ?? '';
    final intent = m['intent']?.toString().trim() ?? '';
    if ([id, entity, to, recipient, intent].any((s) => s.isEmpty)) return null;
    return _HaRule(
      id: id,
      entityId: entity,
      from: m['from']?.toString(),
      to: to,
      recipient: recipient,
      intent: intent,
      ttlMinutes: ((m['ttl_minutes'] as num?)?.toInt() ?? 120).clamp(1, 24 * 60),
      priority: AnnouncementPriority.parse(m['priority']?.toString()),
      dedupeKey: m['dedupe_key']?.toString(),
    );
  }
}
