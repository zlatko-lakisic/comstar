import 'dart:async';
import 'dart:io';

import 'package:comstar_bridge/announce/gate.dart';
import 'package:comstar_bridge/announce/ha_source.dart';
import 'package:comstar_bridge/announce/queue.dart';
import 'package:comstar_bridge/announce/schedule_source.dart';
import 'package:comstar_bridge/announce/types.dart';
import 'package:comstar_bridge/attention/events.dart';
import 'package:comstar_bridge/attention/machine.dart';
import 'package:comstar_bridge/attention/states.dart';
import 'package:comstar_bridge/config.dart';
import 'package:comstar_bridge/ha_agent_client.dart';
import 'package:comstar_bridge/log.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

typedef AnnounceHandler = void Function(AttentionEvent event);

/// Wires queue + sources + gate (M10.2–M10.3). Delivery via [onEvent].
class AnnounceService {
  AnnounceService({
    required this.config,
    required this.machine,
    required this.onEvent,
    AnnouncementQueue? queue,
    AnnouncementGate? gate,
    HaAgentClient? ha,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        queue = queue ??
            AnnouncementQueue(
              dbPath: _resolveQueuePath(config),
              clock: clock ?? DateTime.now,
            ),
        gate = gate ??
            AnnouncementGate.fromQuietStrings(
              start: config.announce.quietStart,
              end: config.announce.quietEnd,
            ),
        _ha = ha ?? HaAgentClient();

  final ComstarConfig config;
  final AttentionMachine machine;
  final AnnounceHandler onEvent;
  final AnnouncementQueue queue;
  final AnnouncementGate gate;
  final HaAgentClient _ha;
  final DateTime Function() _clock;
  final _uuid = const Uuid();

  ScheduleAnnounceSource? _schedule;
  HaAnnounceSource? _haSource;
  Timer? _sourceTimer;
  var _evaluating = false;
  var _lastScheduleMinute = -1;

  static String _resolveQueuePath(ComstarConfig config) {
    final raw = config.announce.queuePath.trim();
    if (raw.isNotEmpty) {
      return raw.startsWith('/')
          ? raw
          : p.normalize(p.join(File(config.sourcePath).parent.path, raw));
    }
    final home = Platform.environment['HOME'] ?? '.';
    return p.join(home, '.local', 'share', 'comstar', 'announce', 'queue.db');
  }

  String _resolveRepoPath(String relativeOrAbs) {
    if (relativeOrAbs.startsWith('/')) return relativeOrAbs;
    final configDir = File(config.sourcePath).absolute.parent.path;
    final repoRoot = p.normalize(p.join(configDir, '..'));
    return p.normalize(p.join(repoRoot, relativeOrAbs));
  }

  void start() {
    if (!config.announce.enabled) {
      logInfo('announce_disabled', 'Announce subsystem off');
      return;
    }
    queue.open();
    _schedule = ScheduleAnnounceSource(
      queue: queue,
      schedulePath: _resolveRepoPath(config.announce.schedulePath),
      clock: _clock,
    )..load();
    _haSource = HaAnnounceSource(
      queue: queue,
      rulesPath: _resolveRepoPath(config.announce.haRulesPath),
      ha: _ha,
      clock: _clock,
    )..load();
    _sourceTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_tickSources());
    });
    unawaited(_tickSources());
    logInfo('announce_started', 'Announce service running', data: {
      'queue': queue.dbPath,
      'schedule': config.announce.schedulePath,
      'ha_rules': config.announce.haRulesPath,
    });
  }

  Future<void> stop() async {
    _sourceTimer?.cancel();
    _sourceTimer = null;
    queue.close();
  }

  Future<void> _tickSources() async {
    try {
      final now = _clock().toLocal();
      if (now.minute != _lastScheduleMinute) {
        _lastScheduleMinute = now.minute;
        _schedule?.tick(now: now);
      }
      await _haSource?.tick();
      queue.expireDue(now: now.toUtc());
    } catch (e) {
      logWarn('announce_source_tick', e.toString());
    }
  }

  /// Enqueue from admin / MCP (M10.2.3 / M10.6).
  Announcement enqueue({
    required String recipient,
    required String intent,
    AnnouncementPriority priority = AnnouncementPriority.normal,
    AnnouncementSource source = AnnouncementSource.injected,
    Duration ttl = const Duration(hours: 2),
    Duration notBefore = Duration.zero,
    String? dedupeKey,
    String? text,
  }) {
    final now = _clock().toUtc();
    return queue.enqueue(
      Announcement(
        id: '',
        recipient: recipient,
        source: source,
        intent: intent,
        priority: priority,
        notBefore: now.add(notBefore),
        expiresAt: now.add(ttl),
        dedupeKey: dedupeKey,
        text: text,
      ),
    );
  }

  /// Run gate; if deliverable, emit [AnnouncementReady] (async TTS text may be intent).
  Future<GateDecision> evaluateAndMaybeDeliver({bool force = false}) async {
    if (!config.announce.enabled && !force) {
      return const GateDecision.hold(GateHoldReason.noDue);
    }
    if (_evaluating) {
      return const GateDecision.hold(GateHoldReason.playing);
    }
    _evaluating = true;
    try {
      final ctx = machine.context;
      final userid = ctx.cachedUserid;
      final due = queue.duePending(recipient: userid);
      final decision = gate.evaluate(
        state: machine.state,
        userid: userid,
        guest: userid == null && ctx.sessionOpen,
        playing: ctx.playing,
        announcedThisEngage: ctx.announcedThisEngage,
        due: due,
        localNow: _clock().toLocal(),
      );
      if (!decision.deliver || decision.items.isEmpty) {
        return decision;
      }

      // Cap coalesce at 3 + summary.
      final items = decision.items.take(4).toList();
      final text = coalesceAnnouncementText(items);
      if (text.isEmpty) {
        return const GateDecision.hold(GateHoldReason.noDue);
      }
      final ids = items.map((a) => a.id).toList();
      final id = ids.isEmpty ? _uuid.v4() : ids.first;
      logInfo('announce_deliver', 'Gate cleared announcements', data: {
        'id': id,
        'count': ids.length,
        'userid': userid,
        'text': text,
      });
      for (final a in items) {
        queue.markDelivered(a.id, text: text);
      }
      onEvent(AnnouncementReady(
        id: id,
        text: text,
        announcementIds: ids,
      ));
      return GateDecision.deliver(items);
    } finally {
      _evaluating = false;
    }
  }

  /// Peek hold reasons for admin (does not deliver).
  Map<String, Object?> inspect() {
    final ctx = machine.context;
    final userid = ctx.cachedUserid;
    final due = queue.duePending(recipient: userid);
    final decision = gate.evaluate(
      state: machine.state,
      userid: userid,
      guest: false,
      playing: ctx.playing,
      announcedThisEngage: ctx.announcedThisEngage,
      due: due,
      localNow: _clock().toLocal(),
      logHolds: false,
    );
    return {
      'enabled': config.announce.enabled,
      'state': machine.state.name,
      'userid': userid,
      'quiet': gate.isQuietHours(_clock().toLocal()),
      'announced_this_engage': ctx.announcedThisEngage,
      'due': due.map((a) => a.toJson()).toList(),
      'decision': decision.deliver ? 'deliver' : decision.reasonWire,
      'pending': queue.list(status: AnnouncementStatus.pending, limit: 20)
          .map((a) => a.toJson())
          .toList(),
      'delivered': queue.list(status: AnnouncementStatus.delivered, limit: 10)
          .map((a) => a.toJson())
          .toList(),
      'expired': queue.list(status: AnnouncementStatus.expired, limit: 10)
          .map((a) => a.toJson())
          .toList(),
    };
  }

  /// Due announcements for greeter fold-in (M10.5). Does not mark delivered.
  List<Announcement> peekForGreeter(String userid) {
    if (!config.announce.enabled) return const [];
    if (machine.context.announcedThisEngage) return const [];
    final due = queue.duePending(recipient: userid);
    final decision = gate.evaluate(
      state: const Engaged(),
      userid: userid,
      guest: false,
      playing: false,
      announcedThisEngage: false,
      due: due,
      localNow: _clock().toLocal(),
      logHolds: false,
    );
    if (!decision.deliver) return const [];
    return decision.items.take(4).toList();
  }

  void markGreeterFoldDelivered(List<Announcement> items, String text) {
    machine.context.announcedThisEngage = true;
    for (final a in items) {
      queue.markDelivered(a.id, text: text);
    }
  }
}
